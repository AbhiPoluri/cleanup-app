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
            var uri = ActiveBackendUri(s);
            if (uri.IsLoopback) return;                                          // local: no handshake to save
            if (DateTime.UtcNow - _lastRequestUtc < TimeSpan.FromSeconds(60)) return; // pool still warm
            var root = new Uri(uri.GetLeftPart(UriPartial.Authority));
            var sw = Stopwatch.StartNew();
            using var req = new HttpRequestMessage(HttpMethod.Head, root);
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(8));
            using var resp = await Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token);
            NoteEnv(root, resp);   // count the prewarm as the cold handshake so the real request logs as warm
            Log.Write($"prewarm host={root.Host} {sw.ElapsedMilliseconds}ms status={(int)resp.StatusCode} httpver={resp.Version}");
        }
        catch (Exception ex) { Log.Write($"prewarm skipped err={ex.Message}"); }
    }

    public static async Task<string> Complete(string system, string user, CancellationToken ct, int variant = -1)
    {
        var s = Settings.Current;
        string raw = s.Backend switch
        {
            "openai" => await OpenAi(s, system, user, variant, ct),
            "chatgpt" => await ChatGpt(s, system, user, variant, ct),
            _ => await Ollama(s, system, user, variant, ct),
        };
        return Clean(raw);
    }

    private static async Task<string> Ollama(Settings s, string system, string user, int v, CancellationToken ct)
    {
        var url = s.OllamaUrl.TrimEnd('/') + "/api/chat";
        var body = JsonSerializer.Serialize(new
        {
            model = s.OllamaModel,
            stream = false,
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
            _lastRequestUtc = DateTime.UtcNow;
            // ResponseHeadersRead so TTFB is the real time-to-first-byte, timed
            // separately from the body read below.
            using var resp = await Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
            long ttfb = sw.ElapsedMilliseconds;
            NoteEnv(new Uri(url), resp);
            if (!resp.IsSuccessStatusCode) throw new Exception($"Ollama HTTP {(int)resp.StatusCode}");
            var json = await resp.Content.ReadAsStringAsync(ct);
            long bodyMs = sw.ElapsedMilliseconds - ttfb;
            using var doc = JsonDocument.Parse(json);
            var content = doc.RootElement.GetProperty("message").GetProperty("content").GetString()
                          ?? throw new Exception("Ollama: empty response");
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

    private static async Task<string> OpenAi(Settings s, string system, string user, int v, CancellationToken ct)
    {
        var body = JsonSerializer.Serialize(new
        {
            model = s.ApiModel,
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
            var json = await resp.Content.ReadAsStringAsync(ct);
            long bodyMs = sw.ElapsedMilliseconds - ttfb;
            using var doc = JsonDocument.Parse(json);
            var content = doc.RootElement.GetProperty("choices")[0].GetProperty("message").GetProperty("content").GetString()
                          ?? throw new Exception("API: empty response");
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

    // ChatGPT subscription via Codex CLI login (%USERPROFILE%\.codex\auth.json).
    // The endpoint only speaks SSE (stream:true mandatory) and only allows certain
    // models for ChatGPT accounts (gpt-5.5 as of 2026-07).
    private static async Task<string> ChatGpt(Settings s, string system, string user, int v, CancellationToken ct)
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
            });

            using var req = new HttpRequestMessage(HttpMethod.Post,
                "https://chatgpt.com/backend-api/codex/responses")
            { Content = new StringContent(body, Encoding.UTF8, "application/json") };
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
                                outText.Append(d.GetString());
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
}
