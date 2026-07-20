using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace Cleanup;

// Traffic-light status for one health check. Rendered as a coloured ● glyph so it
// stays mono-friendly (colour is the single sanctioned exception, like the diff
// palette) — the glyph itself is a plain filled dot.
public enum HealthLevel { Green, Amber, Red, Unknown }

// One dependency's live status: a dot, a plain-English one-liner, and an optional
// fix affordance (label + action, e.g. "copy `codex login`" → clipboard).
public sealed class HealthRow
{
    public required HealthLevel Level;
    public required string Title;
    public required string Detail;
    public string? FixLabel;
    public Action? Fix;
}

// Records the last RegisterHotKey outcome per hotkey so the Health panel can show
// "Ctrl+Shift+E active" / "failed — another app owns it". Written from
// HotkeyWindow.Register (the only place the OS actually tells us), read by Health.
public static class HotkeyHealth
{
    private static readonly Dictionary<string, (bool Ok, string Display)> Map = new();
    private static readonly object Gate = new();

    public static void Record(string what, string display, bool ok)
    {
        lock (Gate) Map[what] = (ok, display);
    }

    public static (bool Ok, string Display)? Get(string what)
    {
        lock (Gate) return Map.TryGetValue(what, out var v) ? v : ((bool Ok, string Display)?)null;
    }
}

// Builds the live health checklist. Every probe is best-effort and non-blocking;
// the whole set is cached ~10s so repeated opens / refreshes stay cheap and never
// hammer the CLIs or the network. Nothing here touches the UI thread.
public static class Health
{
    private static readonly object CacheGate = new();
    private static List<HealthRow>? _cache;
    private static DateTime _cachedAtUtc = DateTime.MinValue;

    // cached speech probe — constructing SpeechRecognitionEngine is comparatively
    // heavy and its result never changes within a session, so probe once.
    private static bool? _speechOk;

    public static async Task<List<HealthRow>> GetRowsAsync(bool force = false)
    {
        lock (CacheGate)
        {
            if (!force && _cache != null && DateTime.UtcNow - _cachedAtUtc < TimeSpan.FromSeconds(10))
                return _cache;
        }
        var rows = await BuildRows();
        lock (CacheGate) { _cache = rows; _cachedAtUtc = DateTime.UtcNow; }
        return rows;
    }

    // Cheap, synchronous refresh of just the volatile rows (hotkey registration + ChatGPT
    // token freshness) — no CLI/network probes. Lets the Settings/Welcome panels poll every
    // ~2s while visible so those rows stay live, without hammering the CLIs (whose rows keep
    // the 10s cache). Mutates the cached list in place; returns a copy, or null if nothing's
    // been built yet. UI-thread safe (pure data).
    public static List<HealthRow>? RefreshCheapRows()
    {
        lock (CacheGate)
        {
            if (_cache == null) return null;
            var s = Settings.Current;
            for (int i = 0; i < _cache.Count; i++)
            {
                switch (_cache[i].Title)
                {
                    case "Popup hotkey":   _cache[i] = HotkeyRow("popup", "Popup hotkey", s.HotkeyDisplay); break;
                    case "Instant hotkey": _cache[i] = HotkeyRow("instant", "Instant hotkey", s.HotkeyDisplay2); break;
                    case "ChatGPT login":  _cache[i] = ChatGptTokenRow(); break;
                }
            }
            return new List<HealthRow>(_cache);
        }
    }

    private static async Task<List<HealthRow>> BuildRows()
    {
        var s = Settings.Current;
        var rows = new List<HealthRow>();

        rows.Add(HotkeyRow("popup", "Popup hotkey", s.HotkeyDisplay));
        rows.Add(HotkeyRow("instant", "Instant hotkey", s.HotkeyDisplay2));
        rows.Add(await SpeechRow());
        rows.Add(await LocalVoiceRow(s));
        rows.Add(await CliRow("Claude CLI", Llm.ResolveClaudeCli(),
            "Claude Code CLI not found — install it and run `claude` once to log in",
            "npm i -g @anthropic-ai/claude-code"));
        rows.Add(await CliRow("Codex CLI", Llm.ResolveCodexCli(),
            "Codex CLI not found — install it and run `codex login`",
            "npm i -g @openai/codex"));
        rows.Add(ChatGptTokenRow());
        rows.Add(await BackendRow(s));
        rows.Add(UpdaterRow());
        return rows;
    }

    // ---- individual probes ----

    private static HealthRow HotkeyRow(string what, string title, string fallbackDisplay)
    {
        var rec = HotkeyHealth.Get(what);
        if (rec == null)
            return new HealthRow { Level = HealthLevel.Unknown, Title = title,
                Detail = $"{fallbackDisplay} — not registered yet" };
        if (rec.Value.Ok)
            return new HealthRow { Level = HealthLevel.Green, Title = title,
                Detail = $"{rec.Value.Display} active" };
        return new HealthRow { Level = HealthLevel.Red, Title = title,
            Detail = $"{rec.Value.Display} failed — another app owns it; change it below" };
    }

    private static async Task<HealthRow> SpeechRow()
    {
        bool ok = await ProbeSpeech();
        return ok
            ? new HealthRow { Level = HealthLevel.Green, Title = "Microphone",
                Detail = "voice input ready (Agent and Whiteboard)" }
            : new HealthRow { Level = HealthLevel.Red, Title = "Microphone",
                Detail = "no microphone or speech engine — voice input disabled" };
    }

    // Construct + tear down a System.Speech engine on a background thread. Windows-only
    // at runtime; the try/catch means a missing recognizer just reports "not ready".
    private static Task<bool> ProbeSpeech()
    {
        if (_speechOk.HasValue) return Task.FromResult(_speechOk.Value);
        return Task.Run(() =>
        {
            try
            {
                using var eng = new System.Speech.Recognition.SpeechRecognitionEngine();
                eng.SetInputToDefaultAudioDevice();
                _speechOk = true;
            }
            catch { _speechOk = false; }
            return _speechOk!.Value;
        });
    }

    // Local voice engines (Parakeet ASR + Kokoro TTS) — optional. Reports the four states
    // the spec calls for: python found / venv / helper ping / model download state. Grey
    // (Unknown) when neither engine is selected and nothing's installed; amber when an engine
    // is selected but not ready; green once the helper pings.
    private static async Task<HealthRow> LocalVoiceRow(Settings s)
    {
        bool selected = s.VoiceASR == "parakeet" || s.VoiceTTS == "kokoro";
        if (!VoiceEngine.IsInstalled)
        {
            if (!VoiceEngine.SystemPythonAvailable())
                return new HealthRow { Level = selected ? HealthLevel.Amber : HealthLevel.Unknown,
                    Title = "Local voice",
                    Detail = "not installed — needs Python 3.10+ (python.org), then Settings › Agent › Voice" };
            return new HealthRow { Level = selected ? HealthLevel.Amber : HealthLevel.Unknown,
                Title = "Local voice",
                Detail = selected
                    ? "selected but not installed — install it in Settings › Agent › Voice"
                    : "not installed (optional) — Settings › Agent › Voice" };
        }
        var ping = await VoiceEngine.Ping();
        if (ping == null)
            return new HealthRow { Level = HealthLevel.Red, Title = "Local voice",
                Detail = "installed but the helper isn't responding — reinstall in Settings" };
        string models = VoiceEngine.ParakeetModelPresent()
            ? "INT8 Parakeet ready · unloads after 2 min idle" : "INT8 Parakeet downloads on first use";
        return new HealthRow { Level = HealthLevel.Green, Title = "Local voice",
            Detail = $"venv ready · helper ok (asr {(ping.Value.Asr ? "✓" : "✗")}, " +
                     $"tts {(ping.Value.Tts ? "✓" : "✗")}) · {models}" };
    }

    private static async Task<HealthRow> CliRow(string title, string? cli, string missingDetail, string installCmd)
    {
        if (cli == null)
            return new HealthRow { Level = HealthLevel.Red, Title = title, Detail = missingDetail,
                FixLabel = "copy install", Fix = CopyToClipboard(installCmd) };
        var ver = await CliVersion(cli);
        return new HealthRow { Level = HealthLevel.Green, Title = title,
            Detail = ver != null ? $"found ({ver})" : "found" };
    }

    // Shell `<cli> --version` (via cmd.exe for .cmd shims — Llm.SetCliTarget handles that).
    private static async Task<string?> CliVersion(string cli)
    {
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
            Llm.SetCliTarget(psi, cli);
            psi.ArgumentList.Add("--version");
            using var proc = Process.Start(psi);
            if (proc == null) return null;
            var outp = (await proc.StandardOutput.ReadToEndAsync()).Trim();
            await proc.WaitForExitAsync();
            if (outp.Length == 0) return null;
            var firstLine = outp.Split('\n')[0].Trim();
            return firstLine.Length > 0 ? firstLine : null;
        }
        catch { return null; }
    }

    private static HealthRow ChatGptTokenRow()
    {
        var (level, detail, needsLogin) = Llm.CodexTokenHealth();
        var row = new HealthRow { Level = level, Title = "ChatGPT login", Detail = detail };
        if (needsLogin)
        {
            row.FixLabel = "copy `codex`";
            row.Fix = CopyToClipboard(detail.Contains("codex login") ? "codex login" : "codex");
        }
        return row;
    }

    // Lightweight per-backend readiness probe for whichever rewrite backend is active.
    // Never issues a paid completion — ollama does a GET /api/tags, chatgpt mirrors the
    // token row, claude mirrors the CLI, openai just checks the key is present.
    private static async Task<HealthRow> BackendRow(Settings s)
    {
        switch (s.Backend)
        {
            case "ollama":
                return await OllamaRow(s);
            case "chatgpt":
            {
                var (level, detail, _) = Llm.CodexTokenHealth();
                return new HealthRow { Level = level, Title = "Active backend",
                    Detail = "ChatGPT rewrites — " + detail };
            }
            case "claude":
            {
                var cli = Llm.ResolveClaudeCli();
                return cli == null
                    ? new HealthRow { Level = HealthLevel.Red, Title = "Active backend",
                        Detail = "Claude rewrites — CLI not found (see Claude CLI above)" }
                    : new HealthRow { Level = HealthLevel.Green, Title = "Active backend",
                        Detail = $"Claude rewrites — CLI ready ({s.ClaudeModel})" };
            }
            case "openai":
                return string.IsNullOrWhiteSpace(s.ApiKey)
                    ? new HealthRow { Level = HealthLevel.Red, Title = "Active backend",
                        Detail = "OpenAI-compatible API — no API key set (add it below)" }
                    : new HealthRow { Level = HealthLevel.Green, Title = "Active backend",
                        Detail = $"OpenAI-compatible API — key set ({s.ApiModel})" };
            default:
                return new HealthRow { Level = HealthLevel.Unknown, Title = "Active backend",
                    Detail = s.Backend };
        }
    }

    private static async Task<HealthRow> OllamaRow(Settings s)
    {
        var url = s.OllamaUrl.TrimEnd('/') + "/api/tags";
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(2) };
            var json = await http.GetStringAsync(url);
            using var doc = JsonDocument.Parse(json);
            int n = doc.RootElement.TryGetProperty("models", out var m) && m.ValueKind == JsonValueKind.Array
                ? m.GetArrayLength() : 0;
            return new HealthRow { Level = HealthLevel.Green, Title = "Active backend",
                Detail = $"Ollama reachable — {n} model{(n == 1 ? "" : "s")} ({s.OllamaModel})" };
        }
        catch
        {
            return new HealthRow { Level = HealthLevel.Red, Title = "Active backend",
                Detail = $"Ollama not reachable at {s.OllamaUrl} — is `ollama serve` running?" };
        }
    }

    private static HealthRow UpdaterRow()
    {
        var detail = Updater.IsDevBuild ? "dev build — update check only" : Updater.DisplayVersion;
        if (Updater.LastCheckSummary != null) detail += " · " + Updater.LastCheckSummary;
        return new HealthRow { Level = HealthLevel.Green, Title = "Version", Detail = detail };
    }

    // Clipboard copy fix, marshalled to the UI thread (STA) so it's safe from a click handler.
    private static Action CopyToClipboard(string text) => () =>
    {
        try { Clipboard.SetText(text); } catch { }
    };
}

// Shared renderer for the health checklist — used by the Settings panel (system-
// chrome brushes) and the Welcome window (Mono theme brushes). Colours passed in so
// each host stays legible against its own background.
internal static class HealthView
{
    private static Brush Frozen(byte r, byte g, byte b)
    {
        var br = new SolidColorBrush(Color.FromRgb(r, g, b));
        br.Freeze();
        return br;
    }

    // Accessible traffic-light dots that read on both light and dark surfaces.
    private static readonly Brush GreenDot = Frozen(0x3F, 0xB9, 0x50);
    private static readonly Brush AmberDot = Frozen(0xD2, 0x99, 0x22);
    private static readonly Brush RedDot = Frozen(0xF8, 0x51, 0x49);
    private static readonly Brush GrayDot = Frozen(0x8A, 0x8A, 0x8A);

    private static Brush DotFor(HealthLevel l) => l switch
    {
        HealthLevel.Green => GreenDot,
        HealthLevel.Amber => AmberDot,
        HealthLevel.Red => RedDot,
        _ => GrayDot,
    };

    public static void Render(Panel host, IReadOnlyList<HealthRow> rows,
        Brush titleBrush, Brush mutedBrush, Brush fixBrush, Brush? fixBorderBrush = null, bool compact = false)
    {
        host.Children.Clear();
        foreach (var r in rows)
            host.Children.Add(RowView(r, titleBrush, mutedBrush, fixBrush, fixBorderBrush, compact));
    }

    private static FrameworkElement RowView(HealthRow r, Brush titleBrush, Brush mutedBrush,
        Brush fixBrush, Brush? fixBorderBrush, bool compact)
    {
        var grid = new Grid { Margin = new Thickness(0, 0, 0, compact ? 6 : 8) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var dot = new TextBlock
        {
            Text = "●",
            FontSize = compact ? 10 : 11,
            Foreground = DotFor(r.Level),
            VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, compact ? 2 : 3, 8, 0),
        };
        Grid.SetColumn(dot, 0);
        grid.Children.Add(dot);

        var texts = new StackPanel();
        texts.Children.Add(new TextBlock
        {
            Text = r.Title,
            FontSize = compact ? 11.5 : 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = titleBrush,
            TextWrapping = TextWrapping.Wrap,
        });
        texts.Children.Add(new TextBlock
        {
            Text = r.Detail,
            FontSize = 11,
            Foreground = mutedBrush,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 1, 0, 0),
        });
        Grid.SetColumn(texts, 1);
        grid.Children.Add(texts);

        if (r.Fix != null && !string.IsNullOrEmpty(r.FixLabel))
        {
            var label = new TextBlock { Text = r.FixLabel, FontSize = 11, Foreground = fixBrush };
            var btn = new Border
            {
                Child = label,
                BorderBrush = fixBorderBrush ?? fixBrush,
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(5),
                Padding = new Thickness(7, 2, 7, 2),
                Margin = new Thickness(8, 1, 0, 0),
                Cursor = Cursors.Hand,
                VerticalAlignment = VerticalAlignment.Top,
            };
            btn.MouseLeftButtonUp += (_, e) =>
            {
                e.Handled = true;
                r.Fix!();
                label.Text = "copied ✓";
                var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(1200) };
                timer.Tick += (_, _) => { timer.Stop(); label.Text = r.FixLabel; };
                timer.Start();
            };
            Grid.SetColumn(btn, 2);
            grid.Children.Add(btn);
        }

        return grid;
    }
}
