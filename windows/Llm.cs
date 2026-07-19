using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Cleanup;

public static class Prompts
{
    public const string System =
        "You are a text rewriting engine. Output exactly one rewritten message and nothing else — " +
        "no quotes around it, no preamble, no labels, no multiple options, no explanations. " +
        "Preserve the original formatting exactly: keep every line break, blank line, paragraph split, " +
        "bullet or numbered list, indentation, and any markdown or special characters the writer used. " +
        "Rewrite only the wording, never the layout.";

    public static string ToneInstruction(string tone) => tone switch
    {
        "Clean" => "neutral — just fix grammar, spelling, punctuation, and clarity; keep the writer's voice",
        "Professional" => "professional and polished, suitable for work or academic contexts",
        "Casual" => "relaxed and friendly, like texting a friend, but still clean and readable",
        "Blunt" => "direct and concise; cut hedging and filler",
        _ => tone,
    };

    // Hard, mutually exclusive briefs — soft hints like "warmer" converge on short messages.
    public static readonly (string Label, string Brief)[] Styles =
    {
        ("balanced", "Keep the length and structure natural — a clean, faithful version of the original."),
        ("polished", "Compose it properly: complete sentences, courteous phrasing, no slang or filler words at all."),
        ("compressed", "Cut it down hard: at most half the original length. Drop greetings, pleasantries, and filler — keep only the substance."),
        ("fuller", "Expand it a little: open with a natural greeting and add a touch more courtesy or context. Aim for roughly 1.5x the original length."),
        ("minimal edit", "Change as little as possible: fix only spelling, grammar, and punctuation. Keep the original wording, casual bits, and phrasing wherever they work."),
    };

    public static string Variant(string text, string tone, int index) =>
        $"Rewrite the message below so it is clean, grammatical, and well-punctuated while keeping its meaning. " +
        $"Tone: {ToneInstruction(tone)}.\n" +
        $"This version's brief, which overrides everything except meaning: {Styles[index % Styles.Length].Brief} " +
        $"Reply with the rewritten message only.\n\nMessage:\n{text}";

    public static string Refine(string current, string instruction) =>
        $"Here is a message:\n{current}\n\nRevise it according to this instruction: {instruction}\n" +
        "Return only the revised message.";
}

public static class Llm
{
    // Shared client over an explicit SocketsHttpHandler. Every setting here targets
    // a specific failure mode that made Windows slower than the Mac (URLSession) app:
    //   * HTTP/2 default + multiple-connections: the big one. .NET's default
    //     DefaultRequestVersion is HTTP/1.1, so N concurrent variants each open a
    //     separate TCP+TLS connection to chatgpt.com. URLSession negotiates HTTP/2
    //     and multiplexes all variants over ONE connection. Version20 +
    //     RequestVersionOrLower makes us do the same (and falls back to 1.1 for
    //     servers — e.g. local Ollama — that don't offer h2).
    private static readonly HttpClient Http = BuildClient();

    // last outbound request time — the prewarm guard uses it to skip warming when
    // the pool is already hot (keep-alive covers requests within ~60s).
    private static DateTime _lastRequestUtc = DateTime.MinValue;

    // hosts this process has already opened a connection to; first hit = cold
    // handshake (logged once via NoteEnv). Absence of a repeat env line for a host
    // on later requests is the connection-reuse evidence.
    private static readonly HashSet<string> HostsSeen = new(StringComparer.OrdinalIgnoreCase);

    private static HttpClient BuildClient()
    {
        var handler = new SocketsHttpHandler
        {
            // recycle pooled connections so DNS changes (failover / load-balancer
            // rotation) are picked up instead of pinning a dead/stale endpoint.
            PooledConnectionLifetime = TimeSpan.FromMinutes(5),
            // fail fast on a dead route rather than hanging on the 120s overall timeout.
            ConnectTimeout = TimeSpan.FromSeconds(10),
            // keep pooled TLS connections warm between generations so the next batch
            // skips the TCP+TLS handshake (prevents cold-handshake latency spikes).
            KeepAlivePingDelay = TimeSpan.FromSeconds(30),
            KeepAlivePingTimeout = TimeSpan.FromSeconds(10),
            // let concurrent variants open a 2nd h2 connection instead of serializing
            // behind one connection's stream-concurrency limit.
            EnableMultipleHttp2Connections = true,
            // request gzip/br so large JSON / SSE bodies arrive smaller → less body time.
            AutomaticDecompression = DecompressionMethods.All,
        };

        // Proxy: don't hard-disable (some users need one), but if the system proxy
        // resolves DIRECT for the configured remote backend, turn UseProxy off so
        // WinHTTP doesn't do a proxy lookup on every request. Only for a remote
        // backend — loopback (Ollama) is auto-bypassed, nothing to save.
        try
        {
            var target = ActiveBackendUri(Settings.Current);
            if (!target.IsLoopback)
            {
                bool direct = ProxyIsDirect(target);
                if (direct) handler.UseProxy = false;
                Log.Write($"http proxy backend={Settings.Current.Backend} host={target.Host} " +
                          $"decision={(direct ? "direct" : "proxy")} useProxy={handler.UseProxy}");
            }
            else
            {
                Log.Write($"http proxy backend={Settings.Current.Backend} host={target.Host} decision=loopback-skip");
            }
        }
        catch { }

        return new HttpClient(handler)
        {
            Timeout = TimeSpan.FromSeconds(120),
            // HTTP/2 with graceful downgrade — see class-level comment.
            DefaultRequestVersion = HttpVersion.Version20,
            DefaultVersionPolicy = HttpVersionPolicy.RequestVersionOrLower,
        };
    }

    // Base URI of the currently-configured backend (used for proxy resolution and
    // connection pre-warming).
    private static Uri ActiveBackendUri(Settings s) => s.Backend switch
    {
        "openai" => new Uri(s.ApiBase),
        "chatgpt" => new Uri("https://chatgpt.com"),
        _ => new Uri(s.OllamaUrl),
    };

    private static bool ProxyIsDirect(Uri uri)
    {
        try
        {
            var p = HttpClient.DefaultProxy;
            if (p == null) return true;
            if (p.IsBypassed(uri)) return true;
            var via = p.GetProxy(uri);
            return via == null || via.Equals(uri);
        }
        catch { return true; }
    }

    // Log a one-time HTTP-environment line the first time this process talks to a
    // host: negotiated HTTP version (proves h2 vs 1.1), proxy decision, cold flag.
    // Silent on subsequent requests to the same host — that silence IS the
    // connection-reuse evidence.
    private static void NoteEnv(Uri uri, HttpResponseMessage resp)
    {
        bool firstSeen;
        lock (HostsSeen) firstSeen = HostsSeen.Add(uri.Host);
        if (firstSeen)
            Log.Write($"http env host={uri.Host} httpver={resp.Version} " +
                      $"proxy={(ProxyIsDirect(uri) ? "direct" : "proxy")} cold=true");
    }

    // Fire a throwaway request to the active backend's host so DNS+TCP+TLS complete
    // before the user's variants go out — saves 300-800ms of cold handshake on the
    // first generation. Cheap and best-effort; guarded so it never fires for local
    // Ollama and never when the pool is already warm.
    public static async Task Prewarm()
    {
        try
        {
            var s = Settings.Current;
            if (s.Backend == "claude") return;                                   // CLI backend: no URL to warm
            var uri = ActiveBackendUri(s);
            if (uri.IsLoopback) return;                                          // local: no handshake to save
            if (DateTime.UtcNow - _lastRequestUtc < TimeSpan.FromSeconds(60)) return; // pool still warm
            var root = new Uri(uri.GetLeftPart(UriPartial.Authority));
            var sw = Stopwatch.StartNew();
            using var req = new HttpRequestMessage(HttpMethod.Head, root);
            ForceHttp2(req);
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(8));
            using var resp = await Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token);
            NoteEnv(root, resp);   // count the prewarm as the cold handshake so the real request logs as warm
            Log.Write($"prewarm host={root.Host} {sw.ElapsedMilliseconds}ms status={(int)resp.StatusCode} httpver={resp.Version}");
        }
        catch (Exception ex) { Log.Write($"prewarm skipped err={ex.Message}"); }
    }

    // HTTP/2 TRAP: HttpClient.DefaultRequestVersion only applies to the convenience
    // methods (GetAsync/PostAsync). A manually constructed HttpRequestMessage defaults
    // to Version 1.1, and SendAsync honours the MESSAGE's own Version — so every
    // hand-built request here MUST set these two or it silently drops back to 1.1
    // (that regression is exactly what the telemetry caught: httpver=1.1). Applied to
    // Ollama too — h2 negotiation harmlessly downgrades to 1.1 on localhost.
    private static void ForceHttp2(HttpRequestMessage req)
    {
        req.Version = HttpVersion.Version20;
        req.VersionPolicy = HttpVersionPolicy.RequestVersionOrLower;
    }

    public static async Task<string> Complete(
        string system, string user, CancellationToken ct, int variant = -1, Action<string>? onPartial = null)
    {
        var s = Settings.Current;
        string raw = s.Backend switch
        {
            "openai" => await OpenAi(s, system, user, variant, ct, onPartial),
            "chatgpt" => await ChatGpt(s, system, user, variant, ct, onPartial),
            "claude" => await Claude(s, system, user, variant, ct, onPartial),
            _ => await Ollama(s, system, user, variant, ct, onPartial),
        };
        return Clean(raw);
    }

    // Rate-limits the display-only partial callback so token-per-event Dispatcher
    // traffic can't jank WPF. First partial fires immediately (words on screen ~1s
    // in); subsequent ones at most every MinIntervalMs. Materialises the accumulated
    // string only when it actually emits (never on a throttled tick). Also logs the
    // one-time first-partial-shown latency per variant. The FINAL text always comes
    // from the method return value — this path is purely for perceived speed.
    private sealed class PartialThrottle
    {
        private const int MinIntervalMs = 80;
        private readonly Action<string>? _cb;
        private readonly Stopwatch _sw;
        private readonly int _v;
        private long _lastEmitMs = -1;
        private bool _firstLogged;

        public PartialThrottle(Action<string>? cb, Stopwatch sw, int v) { _cb = cb; _sw = sw; _v = v; }

        public void Offer(StringBuilder acc)
        {
            if (_cb == null) return;
            long now = _sw.ElapsedMilliseconds;
            if (_lastEmitMs >= 0 && now - _lastEmitMs < MinIntervalMs) return;
            _lastEmitMs = now;
            if (!_firstLogged)
            {
                _firstLogged = true;
                Log.Write($"sse first-partial-shown={now}ms v={_v}");
            }
            _cb(acc.ToString());
        }
    }

    private static async Task<string> Ollama(
        Settings s, string system, string user, int v, CancellationToken ct, Action<string>? onPartial = null)
    {
        var url = s.OllamaUrl.TrimEnd('/') + "/api/chat";
        var body = JsonSerializer.Serialize(new
        {
            model = s.OllamaModel,
            stream = true,   // JSONL stream — same accumulated-callback contract as the remote backends
            messages = new[]
            {
                new { role = "system", content = system },
                new { role = "user", content = user },
            },
        });
        var sw = Stopwatch.StartNew();
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Post, url)
            { Content = new StringContent(body, Encoding.UTF8, "application/json") };
            ForceHttp2(req);
            _lastRequestUtc = DateTime.UtcNow;
            // ResponseHeadersRead so TTFB is the real time-to-first-byte, timed
            // separately from the body read below.
            using var resp = await Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
            long ttfb = sw.ElapsedMilliseconds;
            NoteEnv(new Uri(url), resp);
            if (!resp.IsSuccessStatusCode) throw new Exception($"Ollama HTTP {(int)resp.StatusCode}");

            // Ollama streams newline-delimited JSON objects: each carries a
            // message.content fragment, and the final one has done:true. Accumulate
            // the fragments; throttle the partial callback so local models feel instant.
            var throttle = new PartialThrottle(onPartial, sw, v);
            var outText = new StringBuilder();
            using var stream = await resp.Content.ReadAsStreamAsync(ct);
            using var reader = new StreamReader(stream);
            string? line;
            while ((line = await reader.ReadLineAsync(ct)) != null)
            {
                if (line.Length == 0) continue;
                JsonDocument ev;
                try { ev = JsonDocument.Parse(line); }
                catch { continue; }
                using (ev)
                {
                    if (ev.RootElement.TryGetProperty("message", out var m) &&
                        m.TryGetProperty("content", out var c) && c.ValueKind == JsonValueKind.String)
                    {
                        var frag = c.GetString();
                        if (!string.IsNullOrEmpty(frag)) { outText.Append(frag); throttle.Offer(outText); }
                    }
                    if (ev.RootElement.TryGetProperty("done", out var done) &&
                        done.ValueKind == JsonValueKind.True)
                        break;
                }
            }
            long bodyMs = sw.ElapsedMilliseconds - ttfb;
            var content = outText.ToString();
            if (content.Length == 0) throw new Exception("Ollama: empty response");
            Log.Write($"llm ok backend=ollama model={s.OllamaModel} v={v} ttfb={ttfb}ms body={bodyMs}ms total={sw.ElapsedMilliseconds}ms");
            return content;
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex)
        {
            Log.Write($"llm fail backend=ollama model={s.OllamaModel} v={v} err={ex.Message} total={sw.ElapsedMilliseconds}ms");
            throw;
        }
    }

    private static async Task<string> OpenAi(
        Settings s, string system, string user, int v, CancellationToken ct, Action<string>? onPartial = null)
    {
        var body = JsonSerializer.Serialize(new
        {
            model = s.ApiModel,
            stream = true,   // SSE — choices[0].delta.content per event, terminated by "data: [DONE]"
            messages = new[]
            {
                new { role = "system", content = system },
                new { role = "user", content = user },
            },
        });
        // Accept bases with or without a trailing /v1 (OpenAI docs say
        // https://api.openai.com, OpenRouter docs say https://openrouter.ai/api/v1)
        var baseUrl = s.ApiBase.TrimEnd('/');
        var url = baseUrl.EndsWith("/v1", StringComparison.OrdinalIgnoreCase)
            ? baseUrl + "/chat/completions"
            : baseUrl + "/v1/chat/completions";
        var sw = Stopwatch.StartNew();
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Post, url)
            { Content = new StringContent(body, Encoding.UTF8, "application/json") };
            ForceHttp2(req);
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", s.ApiKey);
            _lastRequestUtc = DateTime.UtcNow;
            using var resp = await Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
            long ttfb = sw.ElapsedMilliseconds;
            NoteEnv(new Uri(url), resp);
            if (!resp.IsSuccessStatusCode)
            {
                var errBody = await resp.Content.ReadAsStringAsync(ct);
                throw new Exception($"API HTTP {(int)resp.StatusCode}: {ExtractApiError(errBody)}");
            }

            // OpenAI/OpenRouter SSE: each "data: {…}" line carries choices[0].delta.content;
            // "data: [DONE]" terminates. (OpenRouter also sends ": …" keep-alive comment
            // lines — they don't start with "data: " so they're skipped.)
            var throttle = new PartialThrottle(onPartial, sw, v);
            var outText = new StringBuilder();
            using var stream = await resp.Content.ReadAsStreamAsync(ct);
            using var reader = new StreamReader(stream);
            string? line;
            while ((line = await reader.ReadLineAsync(ct)) != null)
            {
                if (!line.StartsWith("data: ")) continue;
                var data = line.Substring(6);
                if (data == "[DONE]") break;
                JsonDocument ev;
                try { ev = JsonDocument.Parse(data); }
                catch { continue; }
                using (ev)
                {
                    if (ev.RootElement.TryGetProperty("choices", out var choices) &&
                        choices.ValueKind == JsonValueKind.Array && choices.GetArrayLength() > 0 &&
                        choices[0].TryGetProperty("delta", out var delta) &&
                        delta.TryGetProperty("content", out var cEl) && cEl.ValueKind == JsonValueKind.String)
                    {
                        var frag = cEl.GetString();
                        if (!string.IsNullOrEmpty(frag)) { outText.Append(frag); throttle.Offer(outText); }
                    }
                }
            }
            long bodyMs = sw.ElapsedMilliseconds - ttfb;
            var content = outText.ToString();
            if (content.Length == 0) throw new Exception("API: empty response");
            Log.Write($"llm ok backend=openai model={s.ApiModel} v={v} ttfb={ttfb}ms body={bodyMs}ms total={sw.ElapsedMilliseconds}ms");
            return content;
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex)
        {
            Log.Write($"llm fail backend=openai model={s.ApiModel} v={v} err={ex.Message} total={sw.ElapsedMilliseconds}ms");
            throw;
        }
    }

    // Pull the human-readable message out of an OpenAI-style error payload
    // ({"error":{"message":...}}); fall back to the raw (truncated) body.
    private static string ExtractApiError(string body)
    {
        try
        {
            using var doc = JsonDocument.Parse(body);
            if (doc.RootElement.TryGetProperty("error", out var err))
            {
                if (err.ValueKind == JsonValueKind.Object &&
                    err.TryGetProperty("message", out var msg) && msg.ValueKind == JsonValueKind.String)
                    return msg.GetString()!;
                if (err.ValueKind == JsonValueKind.String)
                    return err.GetString()!;
            }
        }
        catch { }
        var trimmed = body.Trim();
        return trimmed.Length > 200 ? trimmed[..200] + "…" : (trimmed.Length > 0 ? trimmed : "no response body");
    }

    // Codex models allowed for ChatGPT-subscription accounts (probed 2026-07-09;
    // gpt-5.5-mini and the -codex-mini variants are rejected with 400).
    public static readonly string[] ChatgptModels = { "gpt-5.5", "gpt-5.4", "gpt-5.4-mini" };

    private static string ValidEffort(string e) =>
        e is "low" or "medium" or "high" ? e : "low";

    // ChatGPT subscription via Codex CLI login (%USERPROFILE%\.codex\auth.json).
    // The endpoint only speaks SSE (stream:true mandatory) and only allows certain
    // models for ChatGPT accounts (see ChatgptModels).
    private static async Task<string> ChatGpt(
        Settings s, string system, string user, int v, CancellationToken ct, Action<string>? onPartial = null)
    {
        var sw = Stopwatch.StartNew();
        long ttfb = -1, sseFirst = -1;
        int events = 0;

        // local so both the completed-case return and the fall-through end log the
        // same summary line with the latest sse_first / events counters.
        void LogOk() => Log.Write(
            $"llm ok backend=chatgpt model={s.ChatgptModel} v={v} ttfb={ttfb}ms " +
            $"body={sw.ElapsedMilliseconds - ttfb}ms total={sw.ElapsedMilliseconds}ms " +
            $"sse_first={sseFirst}ms events={events}");

        try
        {
            var authPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "auth.json");
            if (!File.Exists(authPath))
                throw new Exception("No Codex login — run `codex login` in a terminal");
            using var authDoc = JsonDocument.Parse(File.ReadAllText(authPath));
            var tokens = authDoc.RootElement.GetProperty("tokens");
            var accessToken = tokens.GetProperty("access_token").GetString()!;
            var accountId = tokens.GetProperty("account_id").GetString()!;

            var body = JsonSerializer.Serialize(new
            {
                model = s.ChatgptModel,
                instructions = system,
                input = new object[]
                {
                    new
                    {
                        type = "message",
                        role = "user",
                        content = new object[] { new { type = "input_text", text = user } },
                    },
                },
                stream = true,   // MANDATORY: this endpoint only speaks SSE
                store = false,
                // low effort ≈3x faster for short rewrites; also required for
                // gpt-5.4-mini, which stalls at its default effort (probed 2026-07-09)
                reasoning = new { effort = ValidEffort(s.ChatgptEffort) },
            });

            using var req = new HttpRequestMessage(HttpMethod.Post,
                "https://chatgpt.com/backend-api/codex/responses")
            { Content = new StringContent(body, Encoding.UTF8, "application/json") };
            ForceHttp2(req);
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
            req.Headers.TryAddWithoutValidation("chatgpt-account-id", accountId);
            req.Headers.TryAddWithoutValidation("OpenAI-Beta", "responses=experimental");
            req.Headers.TryAddWithoutValidation("originator", "codex_cli_rs");
            req.Headers.TryAddWithoutValidation("session_id", Guid.NewGuid().ToString());
            req.Headers.TryAddWithoutValidation("Accept", "text/event-stream");

            _lastRequestUtc = DateTime.UtcNow;
            // ResponseHeadersRead → we read the SSE stream incrementally (line by
            // line) below rather than buffering the whole body, so ttfb is the real
            // header time and the first delta is visible the moment it arrives.
            using var resp = await Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
            ttfb = sw.ElapsedMilliseconds;
            NoteEnv(new Uri("https://chatgpt.com/backend-api/codex/responses"), resp);
            if ((int)resp.StatusCode == 401 || (int)resp.StatusCode == 403)
                throw new Exception("ChatGPT token expired — run `codex` once to refresh");
            if (!resp.IsSuccessStatusCode)
                throw new Exception($"ChatGPT HTTP {(int)resp.StatusCode}");

            var throttle = new PartialThrottle(onPartial, sw, v);
            var outText = new StringBuilder();
            using var stream = await resp.Content.ReadAsStreamAsync(ct);
            using var reader = new StreamReader(stream);
            string? line;
            while ((line = await reader.ReadLineAsync(ct)) != null)
            {
                if (!line.StartsWith("data: ")) continue;
                if (sseFirst < 0) sseFirst = sw.ElapsedMilliseconds;   // time-to-first-SSE-event
                events++;
                JsonDocument ev;
                try { ev = JsonDocument.Parse(line.Substring(6)); }
                catch { continue; }
                using (ev)
                {
                    if (!ev.RootElement.TryGetProperty("type", out var typeEl)) continue;
                    switch (typeEl.GetString())
                    {
                        case "response.output_text.delta":
                            if (ev.RootElement.TryGetProperty("delta", out var d))
                            {
                                outText.Append(d.GetString());
                                throttle.Offer(outText);   // live tokens into the card (throttled)
                            }
                            break;
                        case "response.completed":
                            LogOk();
                            return outText.ToString();
                        case "response.failed":
                        case "error":
                            throw new Exception("ChatGPT: generation failed");
                    }
                }
            }
            if (outText.Length == 0) throw new Exception("ChatGPT: empty response");
            LogOk();
            return outText.ToString();
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex)
        {
            Log.Write($"llm fail backend=chatgpt model={s.ChatgptModel} v={v} err={ex.Message} " +
                      $"ttfb={ttfb}ms sse_first={sseFirst}ms events={events} total={sw.ElapsedMilliseconds}ms");
            throw;
        }
    }

    // Resolved path to the `claude` CLI, cached on first success. Only successful
    // resolutions are cached — a not-found stays null so installing the CLI mid-session
    // and reopening Settings re-probes without a restart.
    private static string? _claudeCli;

    // Resolution order: (1) PATH via `where` (claude / claude.cmd / claude.exe),
    // (2) native install %USERPROFILE%\.local\bin\claude.exe, (3) npm global shim
    // %APPDATA%\npm\claude.cmd. Returns null if none exist. Internal so the agent
    // engine can reuse the same discipline for the `claude` tool-enabled agent.
    internal static string? ResolveClaudeCli()
    {
        if (_claudeCli != null && File.Exists(_claudeCli)) return _claudeCli;
        foreach (var name in new[] { "claude", "claude.cmd", "claude.exe" })
        {
            var p = WhereOnPath(name);
            if (p != null) { _claudeCli = p; return p; }
        }
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var native = Path.Combine(home, ".local", "bin", "claude.exe");
        if (File.Exists(native)) { _claudeCli = native; return native; }
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var npmShim = Path.Combine(appData, "npm", "claude.cmd");
        if (File.Exists(npmShim)) { _claudeCli = npmShim; return npmShim; }
        return null;
    }

    // Resolved path to the `codex` CLI, cached on first success — the codex agent
    // engine's equivalent of _claudeCli. Same not-found-stays-null behaviour.
    private static string? _codexCli;

    // Same resolution order as ResolveClaudeCli but for the `codex` CLI: PATH via
    // `where`, then %USERPROFILE%\.local\bin\codex.exe, then %APPDATA%\npm\codex.cmd.
    internal static string? ResolveCodexCli()
    {
        if (_codexCli != null && File.Exists(_codexCli)) return _codexCli;
        foreach (var name in new[] { "codex", "codex.cmd", "codex.exe" })
        {
            var p = WhereOnPath(name);
            if (p != null) { _codexCli = p; return p; }
        }
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var native = Path.Combine(home, ".local", "bin", "codex.exe");
        if (File.Exists(native)) { _codexCli = native; return native; }
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var npmShim = Path.Combine(appData, "npm", "codex.cmd");
        if (File.Exists(npmShim)) { _codexCli = npmShim; return npmShim; }
        return null;
    }

    // Resolve a command name against PATH via Windows `where`; returns the first
    // existing hit, or null.
    private static string? WhereOnPath(string name)
    {
        try
        {
            using var proc = Process.Start(new ProcessStartInfo("where", name)
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
            });
            if (proc == null) return null;
            var outp = proc.StandardOutput.ReadToEnd();
            proc.WaitForExit(3000);
            foreach (var raw in outp.Split('\n'))
            {
                var path = raw.Trim();
                if (path.Length > 0 && File.Exists(path)) return path;
            }
            return null;
        }
        catch { return null; }
    }

    // Point a ProcessStartInfo at the CLI. A .cmd/.bat shim (npm install) can't be
    // launched directly with UseShellExecute=false, so route it through cmd.exe; a
    // native claude.exe runs directly and is preferred. cmd.exe re-parses its command
    // line, so multiline args through the shim are best-effort — native install avoids it.
    internal static void SetCliTarget(ProcessStartInfo psi, string cli)
    {
        if (cli.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase) ||
            cli.EndsWith(".bat", StringComparison.OrdinalIgnoreCase))
        {
            psi.FileName = "cmd.exe";
            psi.ArgumentList.Add("/c");
            psi.ArgumentList.Add(cli);
        }
        else psi.FileName = cli;
    }

    // Claude Code subscription via the `claude` CLI in headless print mode. Reuses the
    // user's Claude Code login — no API key. Streams stream-json JSONL from the child's
    // stdout: `stream_event` lines wrap Anthropic SSE (content_block_delta → text_delta)
    // for the live partial; the final `result` line carries the authoritative full text.
    // Slow option (~8-10s: CLI boot + session setup + API) — streaming softens the wait.
    private static async Task<string> Claude(
        Settings s, string system, string user, int v, CancellationToken ct, Action<string>? onPartial = null)
    {
        var sw = Stopwatch.StartNew();
        long ttfb = -1, sseFirst = -1;
        int events = 0;

        void LogOk() => Log.Write(
            $"llm ok backend=claude model={s.ClaudeModel} v={v} ttfb={ttfb}ms " +
            $"body={(ttfb < 0 ? sw.ElapsedMilliseconds : sw.ElapsedMilliseconds - ttfb)}ms " +
            $"total={sw.ElapsedMilliseconds}ms sse_first={sseFirst}ms events={events}");

        var cli = ResolveClaudeCli()
            ?? throw new Exception("Claude Code CLI not found — install it and run `claude` once to log in");

        var psi = new ProcessStartInfo
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        SetCliTarget(psi, cli);
        // ArgumentList avoids Windows quoting hell — each arg is escaped independently.
        // --append-system-prompt injects Prompts.System (cleaner than concatenating into
        // the user prompt); --strict-mcp-config + empty --mcp-config and
        // disableAllHooks stop the user's MCP servers / hooks from loading (safety + boot time).
        void Arg(string a) => psi.ArgumentList.Add(a);
        Arg("-p"); Arg(user);
        Arg("--model"); Arg(s.ClaudeModel);
        Arg("--output-format"); Arg("stream-json");
        Arg("--verbose");
        Arg("--include-partial-messages");
        Arg("--append-system-prompt"); Arg(system);
        Arg("--strict-mcp-config");
        Arg("--mcp-config"); Arg("{\"mcpServers\":{}}");
        Arg("--settings"); Arg("{\"disableAllHooks\":true}");

        var proc = new Process { StartInfo = psi };
        try { proc.Start(); }
        catch (Exception ex)
        {
            proc.Dispose();
            Log.Write($"llm fail backend=claude model={s.ClaudeModel} v={v} err={ex.Message} total={sw.ElapsedMilliseconds}ms");
            throw new Exception("Claude Code CLI failed to start — " + ex.Message);
        }

        // Cancellation kills the entire process tree (the CLI spawns children).
        using var reg = ct.Register(() => { try { if (!proc.HasExited) proc.Kill(true); } catch { } });

        try
        {
            var throttle = new PartialThrottle(onPartial, sw, v);
            var acc = new StringBuilder();
            string? finalText = null;
            // drain stderr concurrently so a full pipe can't deadlock the stdout read
            var stderrTask = proc.StandardError.ReadToEndAsync(ct);

            string? line;
            while ((line = await proc.StandardOutput.ReadLineAsync(ct)) != null)
            {
                if (ttfb < 0) ttfb = sw.ElapsedMilliseconds;   // first stdout line
                if (line.Length == 0) continue;
                JsonDocument ev;
                try { ev = JsonDocument.Parse(line); }
                catch { continue; }   // parse defensively — skip non-JSON / partial lines
                using (ev)
                {
                    if (!ev.RootElement.TryGetProperty("type", out var typeEl) ||
                        typeEl.ValueKind != JsonValueKind.String) continue;
                    switch (typeEl.GetString())
                    {
                        case "stream_event":
                            // wraps an Anthropic SSE event: content_block_delta → text_delta.text
                            if (ev.RootElement.TryGetProperty("event", out var evt) &&
                                evt.TryGetProperty("type", out var et) &&
                                et.ValueKind == JsonValueKind.String &&
                                et.GetString() == "content_block_delta" &&
                                evt.TryGetProperty("delta", out var dl) &&
                                dl.TryGetProperty("type", out var dt) &&
                                dt.ValueKind == JsonValueKind.String &&
                                dt.GetString() == "text_delta" &&
                                dl.TryGetProperty("text", out var txt) &&
                                txt.ValueKind == JsonValueKind.String)
                            {
                                if (sseFirst < 0) sseFirst = sw.ElapsedMilliseconds;
                                events++;
                                var frag = txt.GetString();
                                if (!string.IsNullOrEmpty(frag)) { acc.Append(frag); throttle.Offer(acc); }
                            }
                            break;
                        case "result":
                            // final line — authoritative full text unless flagged as an error
                            if (ev.RootElement.TryGetProperty("result", out var rEl) &&
                                rEl.ValueKind == JsonValueKind.String)
                                finalText = rEl.GetString();
                            if (ev.RootElement.TryGetProperty("is_error", out var isErr) &&
                                isErr.ValueKind == JsonValueKind.True)
                                finalText = null;   // error result → fall through to stderr handling
                            break;
                    }
                }
            }

            await proc.WaitForExitAsync(ct);
            var result = !string.IsNullOrEmpty(finalText) ? finalText! : acc.ToString();

            if (proc.ExitCode != 0 || result.Length == 0)
            {
                string stderr = "";
                try { stderr = await stderrTask; } catch { }
                var tail = (stderr ?? "").Trim();
                if (tail.Length > 300) tail = "…" + tail[^300..];
                var reason = tail.Length > 0 ? tail
                    : (proc.ExitCode != 0 ? $"exit {proc.ExitCode}" : "empty response");
                throw new Exception("Claude CLI: " + reason);
            }

            LogOk();
            return result;
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex)
        {
            Log.Write($"llm fail backend=claude model={s.ClaudeModel} v={v} err={ex.Message} " +
                      $"ttfb={ttfb}ms sse_first={sseFirst}ms events={events} total={sw.ElapsedMilliseconds}ms");
            throw;
        }
        finally
        {
            try { if (!proc.HasExited) proc.Kill(true); } catch { }
            proc.Dispose();
        }
    }

    private static string Clean(string s)
    {
        var t = s.Trim();
        if (t.Length > 1 &&
            ((t.StartsWith('"') && t.EndsWith('"')) || (t.StartsWith('“') && t.EndsWith('”'))))
            t = t.Substring(1, t.Length - 2).Trim();
        return t;
    }

    // Codex login status for the settings window
    public static string CodexStatus()
    {
        try
        {
            var authPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "auth.json");
            if (!File.Exists(authPath))
                return "Not connected — run: npm i -g @openai/codex, then: codex login";
            using var doc = JsonDocument.Parse(File.ReadAllText(authPath));
            var token = doc.RootElement.GetProperty("tokens").GetProperty("access_token").GetString()!;
            var parts = token.Split('.');
            if (parts.Length < 2) return "Auth file unreadable — run `codex login` again";
            var b64 = parts[1].Replace('-', '+').Replace('_', '/');
            b64 += new string('=', (4 - b64.Length % 4) % 4);
            using var payload = JsonDocument.Parse(Convert.FromBase64String(b64));
            var exp = payload.RootElement.GetProperty("exp").GetDouble();
            if (exp < DateTimeOffset.UtcNow.ToUnixTimeSeconds())
                return "Login expired — run `codex` once in a terminal, then reopen this window";
            string plan = "";
            if (payload.RootElement.TryGetProperty("https://api.openai.com/auth", out var auth) &&
                auth.TryGetProperty("chatgpt_plan_type", out var p))
                plan = " (" + p.GetString() + " plan)";
            return "Connected — using your ChatGPT login" + plan;
        }
        catch
        {
            return "Could not read Codex login — run `codex login` in a terminal";
        }
    }

    // Structured Codex/ChatGPT token health for the Health panel and the chatgpt
    // backend row. Same JWT-exp read as CodexStatus, but graded green/amber/red with
    // a days-to-expiry one-liner. NeedsLogin flags the rows that should offer a
    // `codex login` / `codex` fix affordance.
    internal static (HealthLevel Level, string Detail, bool NeedsLogin) CodexTokenHealth()
    {
        try
        {
            var authPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "auth.json");
            if (!File.Exists(authPath))
                return (HealthLevel.Red, "not connected — run `codex login` in a terminal", true);
            using var doc = JsonDocument.Parse(File.ReadAllText(authPath));
            var token = doc.RootElement.GetProperty("tokens").GetProperty("access_token").GetString()!;
            var parts = token.Split('.');
            if (parts.Length < 2) return (HealthLevel.Amber, "login file unreadable — run `codex login` again", true);
            var b64 = parts[1].Replace('-', '+').Replace('_', '/');
            b64 += new string('=', (4 - b64.Length % 4) % 4);
            using var payload = JsonDocument.Parse(Convert.FromBase64String(b64));
            var exp = payload.RootElement.GetProperty("exp").GetDouble();
            var secs = exp - DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            if (secs <= 0) return (HealthLevel.Red, "expired — run `codex` in a terminal to refresh", true);
            string plan = "";
            if (payload.RootElement.TryGetProperty("https://api.openai.com/auth", out var auth) &&
                auth.TryGetProperty("chatgpt_plan_type", out var p))
                plan = $" ({p.GetString()} plan)";
            double days = secs / 86400.0;
            if (days < 2)
            {
                string left = secs < 3600 ? $"{Math.Max(1, (int)(secs / 60))}m" : $"{(int)(secs / 3600)}h";
                return (HealthLevel.Amber, $"valid, expires in {left} — run `codex` soon{plan}", false);
            }
            return (HealthLevel.Green, $"valid, expires in {(int)days}d{plan}", false);
        }
        catch { return (HealthLevel.Amber, "could not read Codex login — run `codex login`", true); }
    }

    // `claude --version` output, cached after the first successful read.
    private static string? _claudeVersion;

    // Claude Code CLI status for the settings window. Async: locating the CLI and
    // reading its version shell out, so this must not block the UI thread.
    public static async Task<string> ClaudeStatus()
    {
        var cli = ResolveClaudeCli();
        if (cli == null)
            return "Not connected — install Claude Code (npm i -g @anthropic-ai/claude-code, " +
                   "or the native installer), then run `claude` once to log in";
        if (_claudeVersion != null)
            return $"Found ({_claudeVersion}) — using your Claude Code login, no API key";
        try
        {
            var psi = new ProcessStartInfo
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8,
            };
            SetCliTarget(psi, cli);
            psi.ArgumentList.Add("--version");
            using var proc = Process.Start(psi);
            if (proc == null) return $"Found at {cli} — couldn't read version";
            var outp = (await proc.StandardOutput.ReadToEndAsync()).Trim();
            await proc.WaitForExitAsync();
            if (outp.Length > 0) _claudeVersion = outp;
            return _claudeVersion != null
                ? $"Found ({_claudeVersion}) — using your Claude Code login, no API key"
                : $"Found at {cli} — using your Claude Code login, no API key";
        }
        catch
        {
            return $"Found at {cli} — using your Claude Code login (couldn't read version)";
        }
    }
}
