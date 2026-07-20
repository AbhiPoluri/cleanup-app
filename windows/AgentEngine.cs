using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Cleanup;

internal enum AgentEngineKind { Codex, Claude }

// Runs an agentic CLI session (Codex or Claude Code) as a child process and streams
// its JSONL events into two callbacks:
//   * onText(string) — the accumulated text of the CURRENT assistant segment; the
//     window sets/creates the live bubble from it (throttled ~80ms here).
//   * onEvent(string) — a dim one-liner (tool use / raw output). Emitting one also
//     ends the current text segment so the next assistant text starts a fresh bubble.
// Follow-up turns resume the SAME CLI session (claude --continue / codex exec resume
// <project-session-id>), so context persists for the life of one window. Engine, model and the
// permission tier all come from the dedicated Agent-mode Settings (NOT the rewrite
// Backend). Parsing is defensive throughout — one malformed line can never crash a run.
internal sealed class AgentEngine
{
    private readonly AgentEngineKind _kind;
    private readonly bool _isolatedSession;
    private readonly string? _isolatedWorkingDirectory;
    private string? _isolatedCodexSessionId;
    private bool _isolatedClaudeHasSession;
    private string? _capturedCodexSessionId;
    // The project supplying the cwd + per-project resume state for the CURRENT turn.
    // Set at the top of Run; switching projects in the window just passes a different one.
    private Project? _project;

    // current assistant text segment + streaming state (touched only on the read loop)
    private readonly StringBuilder _seg = new();
    private bool _segStreamed;   // saw a delta this segment → ignore a later full message
    private long _lastEmit = -1;
    private bool _dirty;
    private bool _sawAssistantText;
    private string? _reportedError;

    private Action<string> _onText = _ => { };
    private Action<string> _onEvent = _ => { };

    public AgentEngineKind Kind => _kind;

    public AgentEngine(AgentEngineKind kind, bool isolatedSession = false)
    {
        _kind = kind;
        _isolatedSession = isolatedSession;
        if (isolatedSession)
            _isolatedWorkingDirectory = Path.Combine(Path.GetTempPath(), "Cleanup", "agent-sessions", Guid.NewGuid().ToString("N"));
    }

    // The engine the user has selected in Agent settings (independent of Backend).
    public static AgentEngineKind SelectedKind() =>
        Settings.Current.ResolvedAgentEngine == "codex" ? AgentEngineKind.Codex : AgentEngineKind.Claude;

    // Whether the selected engine's CLI is on this machine — gates the 🤖 chip and
    // the tray "Agent task…" item.
    public static bool SelectedCliAvailable() =>
        (SelectedKind() == AgentEngineKind.Codex ? Llm.ResolveCodexCli() : Llm.ResolveClaudeCli()) != null;

    // "codex · gpt-5.5 · safe" / "claude · sonnet · standard"
    public string Label
    {
        get
        {
            var s = Settings.Current;
            var name = _kind == AgentEngineKind.Codex ? "codex" : "claude";
            var model = _kind == AgentEngineKind.Codex ? s.AgentCodexModel : s.AgentClaudeModel;
            if (string.IsNullOrWhiteSpace(model)) model = _kind == AgentEngineKind.Codex ? "gpt-5.5" : "sonnet";
            return $"{name} · {model} · {s.AgentPermission}";
        }
    }

    public string? ResolveCli() =>
        _kind == AgentEngineKind.Codex ? Llm.ResolveCodexCli() : Llm.ResolveClaudeCli();

    // Run one turn in `project` (its dir = cwd, its per-project state drives resume). Throws
    // on a hard failure (CLI missing, non-zero exit); returns normally on success.
    // OperationCanceledException propagates for a user Stop.
    public async Task Run(Project project, string task, IReadOnlyList<string> images, IReadOnlyList<string> attachDirs, Action<string> onText, Action<string> onEvent, CancellationToken ct, string? permissionOverride = null)
    {
        _project = project;
        _onText = onText;
        _onEvent = onEvent;
        _seg.Clear(); _segStreamed = false; _lastEmit = -1; _dirty = false;
        _sawAssistantText = false; _reportedError = null; _capturedCodexSessionId = null;

        var cli = ResolveCli() ?? throw new Exception(_kind == AgentEngineKind.Codex
            ? "Codex CLI not found — npm i -g @openai/codex, then run `codex login`"
            : "Claude Code CLI not found — install it and run `claude` once to log in");

        // Resume is per project AND per provider. Claude's --continue is cwd-scoped while
        // Codex needs the exact captured id; neither may infer state from the other engine.
        var codexSessionId = _isolatedSession ? _isolatedCodexSessionId : project.CodexSessionId;
        bool resume = _kind == AgentEngineKind.Codex
            ? !string.IsNullOrEmpty(codexSessionId)
            : (_isolatedSession ? _isolatedClaudeHasSession : project.ClaudeHasSession);
        var workingDirectory = _isolatedSession ? _isolatedWorkingDirectory! : ProjectStore.EnsureDir(project);
        Directory.CreateDirectory(workingDirectory);
        if (_isolatedSession)
        {
            // Preserve the selected project's brief and personal context without sharing
            // its persisted CLI conversation. Both providers discover these files in cwd.
            var projectDirectory = ProjectStore.EnsureDir(project);
            foreach (var name in new[] { "AGENTS.md", "CLAUDE.md" })
            {
                var source = Path.Combine(projectDirectory, name);
                try { if (File.Exists(source)) File.Copy(source, Path.Combine(workingDirectory, name), overwrite: true); }
                catch (Exception ex) { Log.Write($"agent: could not copy {name} into isolated session — {ex.Message}"); }
            }
        }
        var psi = new ProcessStartInfo
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            StandardInputEncoding = new UTF8Encoding(false),
            // Per-project app-owned workdir (Documents\Cleanup\projects\<slug>), NOT the user
            // profile: $HOME made Claude auto-load the user's personal ~/CLAUDE.md + global
            // memory into every run. This dir carries the project's own CLAUDE.md / AGENTS.md
            // and its own Claude per-cwd auto-memory.
            WorkingDirectory = workingDirectory,
        };
        Llm.SetCliTarget(psi, cli);
        var permission = permissionOverride ?? Settings.Current.AgentPermission;
        BuildArgs(psi, images, attachDirs, resume, permission, codexSessionId);
        var taskHash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(task)))[..12].ToLowerInvariant();
        Log.Write($"agent: project={project.Slug} resume={(resume ? (_kind == AgentEngineKind.Codex ? "resume-id" : "continue") : "fresh")} engine={_kind} perm={permission} prompt=stdin len={task.Length} sha={taskHash}");

        var proc = new Process { StartInfo = psi };
        try { proc.Start(); }
        catch (Exception ex)
        {
            proc.Dispose();
            throw new Exception((_kind == AgentEngineKind.Codex ? "Codex" : "Claude") + " CLI failed to start — " + ex.Message);
        }
        // cancellation kills the whole process tree (the CLI spawns children)
        using var reg = ct.Register(() => { try { if (!proc.HasExited) proc.Kill(true); } catch { } });
        var stderrTask = proc.StandardError.ReadToEndAsync();
        try
        {
            // Both CLIs support text prompts on stdin. This avoids Windows' ~32K process
            // command-line limit and guarantees newlines/quotes arrive byte-for-byte.
            Exception? promptWriteError = null;
            try
            {
                await proc.StandardInput.WriteAsync(task.AsMemory(), ct);
                await proc.StandardInput.FlushAsync(ct);
            }
            catch (Exception ex) when (ex is IOException or InvalidOperationException or ObjectDisposedException)
            {
                // The CLI can exit before consuming stdin (bad option, stale session, auth
                // failure). Keep draining stdout/stderr so the useful CLI error is surfaced
                // instead of masking it with Windows' generic "pipe has been ended" message.
                promptWriteError = ex;
                Log.Write($"agent: stdin delivery interrupted engine={_kind} err={ex.Message}");
            }
            finally { try { proc.StandardInput.Close(); } catch { } }
            string? line;
            while ((line = await proc.StandardOutput.ReadLineAsync(ct)) != null)
            {
                if (line.Length == 0) continue;
                JsonDocument doc;
                try { doc = JsonDocument.Parse(line); }
                catch { Event(line); continue; }   // not JSON → raw dim line (never lose output)
                using (doc)
                {
                    try
                    {
                        if (_kind == AgentEngineKind.Codex) HandleCodex(doc.RootElement);
                        else HandleClaude(doc.RootElement);
                    }
                    catch { /* a single malformed event must never crash the run */ }
                }
            }
            FlushText();
            await proc.WaitForExitAsync(ct);
            string stderr = "";
            try { stderr = (await stderrTask ?? "").Trim(); } catch { }
            if (proc.ExitCode != 0)
            {
                if (_kind == AgentEngineKind.Claude && resume && MissingClaudeSession(stderr))
                {
                    ClearClaudeSession(project);
                    Event("▸ previous Claude session unavailable — retrying fresh");
                    await Run(project, task, images, attachDirs, onText, onEvent, ct, permissionOverride);
                    return;
                }
                if (_kind == AgentEngineKind.Codex && resume && MissingCodexSession(stderr))
                {
                    ClearCodexSession(project);
                    Event("▸ previous Codex session unavailable — retrying fresh");
                    await Run(project, task, images, attachDirs, onText, onEvent, ct, permissionOverride);
                    return;
                }
                if (stderr.Length > 500) stderr = "…" + stderr[^500..];
                throw new Exception(stderr.Length > 0 ? stderr : $"exit {proc.ExitCode}");
            }
            if (!string.IsNullOrWhiteSpace(_reportedError))
            {
                if (_kind == AgentEngineKind.Claude && resume && MissingClaudeSession(_reportedError))
                {
                    ClearClaudeSession(project);
                    Event("▸ previous Claude session unavailable — retrying fresh");
                    await Run(project, task, images, attachDirs, onText, onEvent, ct, permissionOverride);
                    return;
                }
                if (_kind == AgentEngineKind.Codex && resume && MissingCodexSession(_reportedError))
                {
                    ClearCodexSession(project);
                    Event("▸ previous Codex session unavailable — retrying fresh");
                    await Run(project, task, images, attachDirs, onText, onEvent, ct, permissionOverride);
                    return;
                }
                throw new Exception(_reportedError);
            }
            if (promptWriteError != null)
                throw new Exception($"{_kind} could not receive the prompt through stdin — {promptWriteError.Message}");
            if (!_sawAssistantText)
                throw new Exception("The agent completed without returning a response. Check Health and the Cleanup log for the CLI output.");
            CommitSession(project);
            Log.Write($"agent turn done engine={_kind}");
        }
        finally
        {
            try { if (!proc.HasExited) proc.Kill(true); } catch { }
            proc.Dispose();
        }
    }

    // ---------- argument construction (per engine, per permission tier) ----------

    private void BuildArgs(ProcessStartInfo psi, IReadOnlyList<string> images, IReadOnlyList<string> attachDirs,
        bool resume, string permission, string? codexSessionId)
    {
        var s = Settings.Current;
        void A(string a) => psi.ArgumentList.Add(a);

        if (_kind == AgentEngineKind.Codex)
        {
            // codex exec [resume <id>] --json -s <sandbox> [-m model] [-i img]… "<task>"
            // Codex resume is NOT cwd-scoped, so we resume this project's own thread by the
            // session id captured on its first turn; never resume a global "last" session.
            A("exec");
            if (resume)
            {
                A("resume");
                A(codexSessionId!);
            }
            A("--json");
            // `codex exec resume` REJECTS -s (its options differ from plain exec) — the
            // sandbox must go through the config override there. Plain exec keeps -s.
            if (resume) { A("-c"); A($"sandbox_mode=\"{CodexSandbox(permission)}\""); }
            else { A("-s"); A(CodexSandbox(permission)); }
            // Project workdirs aren't git repos — codex refuses to run outside a trusted
            // repo without this flag.
            A("--skip-git-repo-check");
            var model = s.AgentCodexModel?.Trim();
            if (!string.IsNullOrEmpty(model)) { A("-m"); A(model); }
            // Codex reads images natively via --image; they're also listed in the task
            // block so it can Read any non-image attachments itself.
            if (images != null)
                foreach (var img in images) { A("-i"); A(img); }
            A("-"); // prompt is delivered through stdin
        }
        else
        {
            // claude -p [--continue] "<task>" [--model m] --output-format stream-json
            //   --verbose --include-partial-messages <permission flags>
            //   --strict-mcp-config --mcp-config {} --settings {disableAllHooks}
            A("-p");
            if (resume) A("--continue");
            var model = s.AgentClaudeModel?.Trim();
            if (!string.IsNullOrEmpty(model)) { A("--model"); A(model); }
            A("--output-format"); A("stream-json");
            A("--input-format"); A("text");
            A("--verbose");
            A("--include-partial-messages");
            foreach (var flag in ClaudePermissionFlags(permission)) A(flag);
            // attachment parent dirs — Claude's directory boundary denies reads outside
            // cwd/added dirs regardless of --allowedTools
            if (attachDirs != null)
                foreach (var d in attachDirs) { A("--add-dir"); A(d); }
            A("--strict-mcp-config");
            A("--mcp-config"); A("{\"mcpServers\":{}}");
            A("--settings"); A("{\"disableAllHooks\":true}");
        }
    }

    // Codex -s sandbox value for each tier.
    private static string CodexSandbox(string perm) => perm switch
    {
        "full" => "danger-full-access",
        "standard" => "workspace-write",
        _ => "read-only",              // safe (default)
    };

    // Claude permission flags for each tier. --allowedTools Read matters: attachments
    // live OUTSIDE the home cwd (temp dir, Downloads, …) and reads outside the working
    // directory would otherwise prompt — which dontAsk/headless auto-DENIES ("no access
    // to Read").
    private static string[] ClaudePermissionFlags(string perm) => perm switch
    {
        // read & analyze only: never prompt, but block every write/exec tool
        "safe" => new[] { "--permission-mode", "dontAsk", "--disallowedTools", "Bash Edit Write NotebookEdit", "--allowedTools", "Read" },
        // can edit files without prompts (no unchecked arbitrary commands)
        "standard" => new[] { "--permission-mode", "acceptEdits", "--allowedTools", "Read" },
        // no sandbox — unrestricted
        "full" => new[] { "--dangerously-skip-permissions" },
        _ => new[] { "--permission-mode", "dontAsk", "--disallowedTools", "Bash Edit Write NotebookEdit", "--allowedTools", "Read" },
    };

    // ---------- text-segment streaming (throttled, segment-aware) ----------

    private void AppendDelta(string d)
    {
        if (string.IsNullOrEmpty(d)) return;
        _seg.Append(d);
        _segStreamed = true;
        _dirty = true;
        Offer();
    }

    // A full (non-delta) assistant message: authoritative only if nothing streamed
    // this segment (otherwise the deltas already built the bubble).
    private void SetFull(string full)
    {
        if (string.IsNullOrEmpty(full) || _segStreamed) return;
        _seg.Clear();
        _seg.Append(full);
        _dirty = false;
        _lastEmit = Environment.TickCount64;
        _sawAssistantText = true;
        _onText(_seg.ToString());
    }

    private void Offer()
    {
        long now = Environment.TickCount64;
        if (_lastEmit >= 0 && now - _lastEmit < 80) return;   // throttle UI churn
        _lastEmit = now;
        if (_dirty) { _dirty = false; _sawAssistantText = true; _onText(_seg.ToString()); }
    }

    private void FlushText()
    {
        if (_dirty && _seg.Length > 0) { _dirty = false; _lastEmit = Environment.TickCount64; _sawAssistantText = true; _onText(_seg.ToString()); }
    }

    // Emit a dim event line and close the current text segment.
    private void Event(string line)
    {
        FlushText();
        _seg.Clear();
        _segStreamed = false;
        _lastEmit = -1;
        _dirty = false;
        var t = line?.Trim();
        if (!string.IsNullOrEmpty(t)) _onEvent(t);
    }

    // ---------- Claude stream-json parsing ----------

    private void HandleClaude(JsonElement root)
    {
        switch (Str(root, "type"))
        {
            case "stream_event":
                // wraps an Anthropic SSE event; content_block_delta → text_delta is
                // the live token stream (thinking_delta etc. are ignored).
                if (root.TryGetProperty("event", out var evt) && Str(evt, "type") == "content_block_delta" &&
                    evt.TryGetProperty("delta", out var dl) && Str(dl, "type") == "text_delta")
                    AppendDelta(Str(dl, "text") ?? "");
                break;
            case "assistant":
                // full assistant message: text (fallback if nothing streamed) + any
                // tool_use blocks → dim one-liners.
                if (root.TryGetProperty("message", out var msg) &&
                    msg.TryGetProperty("content", out var content) && content.ValueKind == JsonValueKind.Array)
                {
                    foreach (var block in content.EnumerateArray())
                    {
                        switch (Str(block, "type"))
                        {
                            case "text": SetFull(Str(block, "text") ?? ""); break;
                            case "tool_use": Event("▸ " + ClaudeVerb(Str(block, "name") ?? "tool", block)); break;
                        }
                    }
                }
                break;
            case "result":
                // Newer versions stream assistant deltas; older/headless variants may only
                // return the final `result` string. Supporting both avoids an empty bubble on
                // machines with a different Claude CLI release.
                var result = Str(root, "result") ?? Str(root, "text") ?? "";
                if (root.TryGetProperty("is_error", out var isError) && isError.ValueKind == JsonValueKind.True)
                    _reportedError = string.IsNullOrWhiteSpace(result) ? "Claude reported an unknown error." : result;
                else if (!_sawAssistantText) SetFull(result);
                break;
        }
    }

    private static string ClaudeVerb(string name, JsonElement block)
    {
        bool hasInput = block.TryGetProperty("input", out var input);
        string? File() =>
            hasInput && input.TryGetProperty("file_path", out var f) && f.ValueKind == JsonValueKind.String
                ? Path.GetFileName(f.GetString()) : null;
        string? Cmd() =>
            hasInput && input.TryGetProperty("command", out var c) && c.ValueKind == JsonValueKind.String
                ? Short(c.GetString()!) : null;

        return name switch
        {
            "Edit" or "Write" or "MultiEdit" or "NotebookEdit" => "editing " + (File() ?? "a file"),
            "Read" => "reading " + (File() ?? "a file"),
            "Bash" => "running " + (Cmd() ?? "a command"),
            "Grep" or "Glob" => "searching",
            "WebFetch" or "WebSearch" => "browsing the web",
            "Task" => "delegating a subtask",
            "TodoWrite" => "updating the plan",
            _ => "using " + name,
        };
    }

    // ---------- Codex --json parsing (defensive; shapes vary across versions) ----------

    private void HandleCodex(JsonElement root)
    {
        // event payload may be at root, under "msg", or under "item"
        var ev = root;
        if (root.TryGetProperty("msg", out var m) && m.ValueKind == JsonValueKind.Object) ev = m;
        else if (root.TryGetProperty("item", out var it) && it.ValueKind == JsonValueKind.Object) ev = it;

        CaptureCodexSession(root, ev);

        var type = (Str(ev, "type") ?? Str(root, "type") ?? "").ToLowerInvariant();
        if (type.Length == 0) return;

        if (type.Contains("reasoning")) return;                                  // ignore chain-of-thought
        if (type.Contains("delta")) { AppendDelta(Str(ev, "delta") ?? Str(ev, "text") ?? ""); return; }
        if (type.Contains("agent_message") || type == "assistant" || type == "message" ||
            (type.Contains("message") && !type.Contains("user") && !type.Contains("system")))
        {
            var txt = CodexText(ev);
            if (txt != null) SetFull(txt);
            return;
        }
        if (type.Contains("exec") || type.Contains("command") || type.Contains("shell"))
        {
            if (!type.Contains("end") && !type.Contains("output") && !type.Contains("delta"))
            {
                var cmd = CodexCommand(ev);
                Event(cmd != null ? "▸ running: " + cmd : "▸ running a command");
            }
            return;
        }
        if (type.Contains("patch") || type.Contains("apply") ||
            (type.Contains("edit") && !type.Contains("end")) || (type.Contains("write") && !type.Contains("end")))
        {
            if (!type.Contains("end")) Event("▸ editing files");
            return;
        }
        // task_started / task_complete / token_count / thread.* / turn.* → ignored
    }

    // Capture the codex session/thread id from the --json stream (emitted near the start of a
    // fresh run, e.g. thread.started / session.created). Stored on the project so the NEXT turn
    // can `codex exec resume <id>`. Shapes vary across versions, so we probe defensively.
    private void CaptureCodexSession(JsonElement root, JsonElement ev)
    {
        if (_project == null || !string.IsNullOrEmpty(_capturedCodexSessionId) ||
            !string.IsNullOrEmpty(_isolatedSession ? _isolatedCodexSessionId : _project.CodexSessionId)) return;
        string? id = FindSessionId(ev) ?? FindSessionId(root);
        if (id == null)
        {
            // sometimes nested: { "thread": { "id": … } } / { "session": { "id": … } }
            foreach (var e in new[] { ev, root })
                foreach (var key in new[] { "thread", "session" })
                    if (e.TryGetProperty(key, out var o) && o.ValueKind == JsonValueKind.Object)
                    {
                        id = Str(o, "id") ?? Str(o, "thread_id") ?? Str(o, "session_id");
                        if (id != null) break;
                    }
        }
        if (string.IsNullOrEmpty(id)) return;
        // Do not persist a fresh id until the first turn succeeds. A CLI that dies after
        // thread.started otherwise leaves a poisoned resume id for the next launch.
        _capturedCodexSessionId = id;
        Log.Write($"codex resume id={id}");
    }

    private void CommitSession(Project project)
    {
        if (_isolatedSession)
        {
            if (_kind == AgentEngineKind.Codex && !string.IsNullOrEmpty(_capturedCodexSessionId))
                _isolatedCodexSessionId = _capturedCodexSessionId;
            if (_kind == AgentEngineKind.Claude) _isolatedClaudeHasSession = true;
            return;
        }

        project.HasSession = true;
        if (_kind == AgentEngineKind.Codex && !string.IsNullOrEmpty(_capturedCodexSessionId))
            project.CodexSessionId = _capturedCodexSessionId;
        if (_kind == AgentEngineKind.Claude) project.ClaudeHasSession = true;
        ProjectStore.Save(project);
    }

    private void ClearClaudeSession(Project project)
    {
        if (_isolatedSession) { _isolatedClaudeHasSession = false; return; }
        project.ClaudeHasSession = false;
        project.HasSession = !string.IsNullOrEmpty(project.CodexSessionId);
        ProjectStore.Save(project);
    }

    private void ClearCodexSession(Project project)
    {
        _capturedCodexSessionId = null;
        if (_isolatedSession) { _isolatedCodexSessionId = null; return; }
        project.CodexSessionId = null;
        project.HasSession = project.ClaudeHasSession;
        ProjectStore.Save(project);
    }

    private static string? FindSessionId(JsonElement e) =>
        e.ValueKind != JsonValueKind.Object ? null
        : Str(e, "session_id") ?? Str(e, "thread_id") ?? Str(e, "sessionId") ?? Str(e, "threadId");

    private static string? CodexText(JsonElement ev)
    {
        if (ev.TryGetProperty("message", out var mm) && mm.ValueKind == JsonValueKind.String) return mm.GetString();
        if (ev.TryGetProperty("text", out var tt) && tt.ValueKind == JsonValueKind.String) return tt.GetString();
        if (ev.TryGetProperty("content", out var c))
        {
            if (c.ValueKind == JsonValueKind.String) return c.GetString();
            if (c.ValueKind == JsonValueKind.Array)
            {
                var sb = new StringBuilder();
                foreach (var b in c.EnumerateArray())
                {
                    if (b.ValueKind == JsonValueKind.String) sb.Append(b.GetString());
                    else if (b.TryGetProperty("text", out var bt) && bt.ValueKind == JsonValueKind.String) sb.Append(bt.GetString());
                }
                if (sb.Length > 0) return sb.ToString();
            }
        }
        return null;
    }

    private static string? CodexCommand(JsonElement ev)
    {
        if (ev.TryGetProperty("command", out var c))
        {
            if (c.ValueKind == JsonValueKind.String) return Short(c.GetString()!);
            if (c.ValueKind == JsonValueKind.Array)
            {
                var parts = new List<string>();
                foreach (var p in c.EnumerateArray())
                    if (p.ValueKind == JsonValueKind.String) parts.Add(p.GetString()!);
                if (parts.Count > 0) return Short(string.Join(" ", parts));
            }
        }
        return null;
    }

    // ---------- small helpers ----------

    private static string? Str(JsonElement e, string prop) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(prop, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() : null;

    private static string Short(string s)
    {
        s = s.Replace("\r", " ").Replace("\n", " ").Trim();
        return s.Length > 60 ? s[..60] + "…" : s;
    }

    private static bool MissingClaudeSession(string stderr)
    {
        var s = stderr.ToLowerInvariant();
        return s.Contains("no conversation") || s.Contains("no session") ||
               s.Contains("session not found") || s.Contains("conversation not found");
    }

    private static bool MissingCodexSession(string stderr)
    {
        var s = stderr.ToLowerInvariant();
        return s.Contains("session not found") || s.Contains("thread not found") ||
               s.Contains("rollout not found") || s.Contains("unknown session") ||
               s.Contains("invalid session") || s.Contains("failed to resume");
    }
}
