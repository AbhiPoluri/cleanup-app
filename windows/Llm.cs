using System;
using System.Collections.Generic;
using System.IO;
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
        "no quotes around it, no preamble, no labels, no bullet points, no multiple options, no explanations.";

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
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(120) };

    public static async Task<string> Complete(string system, string user, CancellationToken ct)
    {
        var s = Settings.Current;
        string raw = s.Backend switch
        {
            "openai" => await OpenAi(s, system, user, ct),
            "chatgpt" => await ChatGpt(s, system, user, ct),
            _ => await Ollama(s, system, user, ct),
        };
        return Clean(raw);
    }

    private static async Task<string> Ollama(Settings s, string system, string user, CancellationToken ct)
    {
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
        using var resp = await Http.PostAsync(s.OllamaUrl.TrimEnd('/') + "/api/chat",
            new StringContent(body, Encoding.UTF8, "application/json"), ct);
        if (!resp.IsSuccessStatusCode) throw new Exception($"Ollama HTTP {(int)resp.StatusCode}");
        using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync(ct));
        return doc.RootElement.GetProperty("message").GetProperty("content").GetString()
               ?? throw new Exception("Ollama: empty response");
    }

    private static async Task<string> OpenAi(Settings s, string system, string user, CancellationToken ct)
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
        using var req = new HttpRequestMessage(HttpMethod.Post,
            s.ApiBase.TrimEnd('/') + "/v1/chat/completions")
        { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", s.ApiKey);
        using var resp = await Http.SendAsync(req, ct);
        if (!resp.IsSuccessStatusCode) throw new Exception($"API HTTP {(int)resp.StatusCode}");
        using var doc = JsonDocument.Parse(await resp.Content.ReadAsStringAsync(ct));
        return doc.RootElement.GetProperty("choices")[0].GetProperty("message").GetProperty("content").GetString()
               ?? throw new Exception("API: empty response");
    }

    // ChatGPT subscription via Codex CLI login (%USERPROFILE%\.codex\auth.json).
    // The endpoint only speaks SSE (stream:true mandatory) and only allows certain
    // models for ChatGPT accounts (gpt-5.5 as of 2026-07).
    private static async Task<string> ChatGpt(Settings s, string system, string user, CancellationToken ct)
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
            stream = true,
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

        using var resp = await Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
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
                        return outText.ToString();
                    case "response.failed":
                    case "error":
                        throw new Exception("ChatGPT: generation failed");
                }
            }
        }
        if (outText.Length == 0) throw new Exception("ChatGPT: empty response");
        return outText.ToString();
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
