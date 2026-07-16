using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
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
// --last), so context persists for the life of one window. Engine, model and the
// permission tier all come from the dedicated Agent-mode Settings (NOT the rewrite
// Backend). Parsing is defensive throughout — one malformed line can never crash a run.
internal sealed class AgentEngine
{
    private readonly AgentEngineKind _kind;
    private bool _started;   // false = first turn, true = follow-ups resume the session

    // current assistant text segment + streaming state (touched only on the read loop)
    private readonly StringBuilder _seg = new();
    private bool _segStreamed;   // saw a delta this segment → ignore a later full message
    private long _lastEmit = -1;
    private bool _dirty;

    private Action<string> _onText = _ => { };
    private Action<string> _onEvent = _ => { };

    public AgentEngineKind Kind => _kind;

    public AgentEngine(AgentEngineKind kind) { _kind = kind; }

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

    // Run one turn. Throws on a hard failure (CLI missing, non-zero exit); returns
    // normally on success. OperationCanceledException propagates for a user Stop.
    public async Task Run(string task, Action<string> onText, Action<string> onEvent, CancellationToken ct)
    {
        _onText = onText;
        _onEvent = onEvent;
        _seg.Clear(); _segStreamed = false; _lastEmit = -1; _dirty = false;

        var cli = ResolveCli() ?? throw new Exception(_kind == AgentEngineKind.Codex
            ? "Codex CLI not found — npm i -g @openai/codex, then run `codex login`"
            : "Claude Code CLI not found — install it and run `claude` once to log in");

        var psi = new ProcessStartInfo
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            WorkingDirectory = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        };
        Llm.SetCliTarget(psi, cli);
        BuildArgs(psi, task, resume: _started);
        Log.Write($"agent run engine={_kind} resume={_started} perm={Settings.Current.AgentPermission} tasklen={task.Length}");

        var proc = new Process { StartInfo = psi };
        try { proc.Start(); }
        catch (Exception ex)
        {
            proc.Dispose();
            throw new Exception((_kind == AgentEngineKind.Codex ? "Codex" : "Claude") + " CLI failed to start — " + ex.Message);
        }
        _started = true;   // subsequent turns resume, even if this one errors mid-way

        // cancellation kills the whole process tree (the CLI spawns children)
        using var reg = ct.Register(() => { try { if (!proc.HasExited) proc.Kill(true); } catch { } });
        var stderrTask = proc.StandardError.ReadToEndAsync();
        try
        {
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
            if (proc.ExitCode != 0)
            {
                string tail = "";
                try { tail = (await stderrTask ?? "").Trim(); } catch { }
                if (tail.Length > 300) tail = "…" + tail[^300..];
                throw new Exception(tail.Length > 0 ? tail : $"exit {proc.ExitCode}");
            }
            Log.Write($"agent turn done engine={_kind}");
        }
        finally
        {
            try { if (!proc.HasExited) proc.Kill(true); } catch { }
            proc.Dispose();
        }
    }

    // ---------- argument construction (per engine, per permission tier) ----------

    private void BuildArgs(ProcessStartInfo psi, string task, bool resume)
    {
        var s = Settings.Current;
        void A(string a) => psi.ArgumentList.Add(a);

        if (_kind == AgentEngineKind.Codex)
        {
            // codex exec [resume --last] --json -s <sandbox> [-m model] "<task>"
            A("exec");
            if (resume) { A("resume"); A("--last"); }
            A("--json");
            A("-s"); A(CodexSandbox(s.AgentPermission));
            var model = s.AgentCodexModel?.Trim();
            if (!string.IsNullOrEmpty(model)) { A("-m"); A(model); }
            A(task);
        }
        else
        {
            // claude -p [--continue] "<task>" [--model m] --output-format stream-json
            //   --verbose --include-partial-messages <permission flags>
            //   --strict-mcp-config --mcp-config {} --settings {disableAllHooks}
            A("-p");
            if (resume) A("--continue");
            A(task);
            var model = s.AgentClaudeModel?.Trim();
            if (!string.IsNullOrEmpty(model)) { A("--model"); A(model); }
            A("--output-format"); A("stream-json");
            A("--verbose");
            A("--include-partial-messages");
            foreach (var flag in ClaudePermissionFlags(s.AgentPermission)) A(flag);
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

    // Claude permission flags for each tier.
    private static string[] ClaudePermissionFlags(string perm) => perm switch
    {
        // read & analyze only: never prompt, but block every write/exec tool
        "safe" => new[] { "--permission-mode", "dontAsk", "--disallowedTools", "Bash Edit Write NotebookEdit" },
        // can edit files without prompts (no unchecked arbitrary commands)
        "standard" => new[] { "--permission-mode", "acceptEdits" },
        // no sandbox — unrestricted
        "full" => new[] { "--dangerously-skip-permissions" },
        _ => new[] { "--permission-mode", "dontAsk", "--disallowedTools", "Bash Edit Write NotebookEdit" },
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
        _onText(_seg.ToString());
    }

    private void Offer()
    {
        long now = Environment.TickCount64;
        if (_lastEmit >= 0 && now - _lastEmit < 80) return;   // throttle UI churn
        _lastEmit = now;
        if (_dirty) { _dirty = false; _onText(_seg.ToString()); }
    }

    private void FlushText()
    {
        if (_dirty && _seg.Length > 0) { _dirty = false; _lastEmit = Environment.TickCount64; _onText(_seg.ToString()); }
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
                // authoritative end — the text already streamed; nothing to add.
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
}
