using System;
using System.IO;
using System.Text.Json;

namespace Cleanup;

public class Settings
{
    public string Backend { get; set; } = "ollama"; // ollama | chatgpt | openai | claude
    public string OllamaUrl { get; set; } = "http://localhost:11434";
    public string OllamaModel { get; set; } = "llama3.2:3b";
    public string ApiBase { get; set; } = "https://api.openai.com";
    public string ApiKey { get; set; } = "";
    public string ApiModel { get; set; } = "gpt-4o-mini";
    public string ChatgptModel { get; set; } = "gpt-5.5";
    // Reasoning effort for the Codex endpoint ("low"/"medium"/"high"). Low is a big
    // speed win: gpt-5.4-mini@low ≈1s vs gpt-5.5@medium ≈3s (probed 2026-07-09).
    public string ChatgptEffort { get; set; } = "low";
    // Claude Code subscription via the `claude` CLI (headless print mode). Reuses the
    // user's Claude Code login — no API key. Model is a CLI alias (haiku/sonnet/opus)
    // or a full model id typed in the editable box.
    public string ClaudeModel { get; set; } = "haiku";
    public string DefaultTone { get; set; } = "Clean";
    public int DefaultCount { get; set; } = 3;
    // First-run welcome shown yet? Drives the one-time onboarding window on launch;
    // reopenable any time via the tray "Welcome & health…" item.
    public bool DidOnboard { get; set; } = false;

    // ---- Agent mode (independent of the rewrite Backend above) ----
    // Which agent CLI to spin up. "" = not yet chosen → ResolvedAgentEngine falls
    // back to the rewrite backend as a sensible first default (chatgpt→codex, else
    // claude), after which the user's explicit choice is stored here.
    public string AgentEngine { get; set; } = "";
    // Per-engine model so switching engines never carries a wrong id across.
    // Agent work deserves a stronger default than the rewrite backend's haiku.
    public string AgentClaudeModel { get; set; } = "sonnet";
    public string AgentCodexModel { get; set; } = "gpt-5.5";
    // Permission tier: "safe" (read/analyze only), "standard" (can edit files),
    // "full" (no sandbox — dangerous). Sandboxed by default.
    public string AgentPermission { get; set; } = "safe";
    // Personal context the agent should know about the user (pasted ChatGPT memories work
    // well). GLOBAL — written into EVERY project's CLAUDE.md / AGENTS.md on save + app start.
    public string AgentContext { get; set; } = "";
    // ---- Local voice engines (optional; venv at Documents\Cleanup\voice) ----
    // Transcription engine for the agent-window mic: "system" (Windows built-in
    // System.Speech dictation) or "parakeet" (local onnx-asr, record-then-transcribe).
    // Falls back to system when Parakeet is selected but the venv/helper isn't ready.
    public string VoiceASR { get; set; } = "system";
    // Speech-output engine used by Whiteboard: "system" or "kokoro" (local).
    public string VoiceTTS { get; set; } = "system";
    public string KokoroVoice { get; set; } = "af_heart";
    // Slug of the project agent windows + the whiteboard use as their working directory.
    // Persists across sessions; "default" is always present.
    public string CurrentProject { get; set; } = "default";
    // Last agent-window size (DIPs), restored on next open, clamped to the mins.
    public double AgentWidth { get; set; } = 560;
    public double AgentHeight { get; set; } = 640;
    // ---- Whiteboard mode ----
    public double WhiteboardWidth { get; set; } = 1040;
    public double WhiteboardHeight { get; set; } = 700;
    public int WhiteboardCamera { get; set; } = 0;
    // Normalized TL,TR,BR,BL points (x,y pairs) for perspective correction.
    public double[] WhiteboardCorners { get; set; } = { .08, .10, .92, .10, .92, .90, .08, .90 };
    public bool WhiteboardMuted { get; set; } = false;
    public bool WhiteboardMic { get; set; } = true;
    public bool WhiteboardSounds { get; set; } = true;
    public bool FloatingButton { get; set; } = true;
    // Per-chip enable toggles for the floating selection bar (master = FloatingButton
    // above). All default on; each hides its chip when off. ChipAgent additionally
    // requires the agent engine's CLI to resolve before the 🤖 chip renders.
    public bool ChipStar { get; set; } = true;
    public bool ChipBolt { get; set; } = true;
    public bool ChipAgent { get; set; } = true;
    // ✂ snip chip — screenshot a region → agent. Doesn't need the agent CLI to appear.
    public bool ChipSnip { get; set; } = true;
    // inline diff panel toggle — persists across popup opens
    public bool DiffView { get; set; } = false;
    // click-away dismissal — OFF by default (popup stays open until Esc / ✕ / Copy / Replace)
    public bool AutoClose { get; set; } = false;
    // floating ✦ button logical size (DIPs), 22–48; 30 = original hardcoded size
    public double FloatingButtonSize { get; set; } = 30;
    // popup content text size (DIPs), 11–18; 13 = original card/diff/refine size
    public double FontSize { get; set; } = 13;
    // last popup size (DIPs) — restored on next open; clamped to the mins below
    public double PopupWidth { get; set; } = 640;
    public double PopupHeight { get; set; } = 540;
    // last Settings window size (DIPs) — restored on next open, clamped to the mins.
    public double SettingsWidth { get; set; } = 760;
    public double SettingsHeight { get; set; } = 560;
    // Win32 MOD_* flags happen to match WPF ModifierKeys values (Alt=1, Ctrl=2, Shift=4, Win=8)
    public uint HotkeyModifiers { get; set; } = 0x2 | 0x4; // Ctrl+Shift
    public uint HotkeyKey { get; set; } = 0x45;            // E
    public string HotkeyDisplay { get; set; } = "Ctrl+Shift+E";
    // Second global hotkey — the instant (hands-free auto-replace) trigger.
    public uint HotkeyModifiers2 { get; set; } = 0x2 | 0x4; // Ctrl+Shift
    public uint HotkeyKey2 { get; set; } = 0x52;            // R
    public string HotkeyDisplay2 { get; set; } = "Ctrl+Shift+R";

    private static string Dir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Cleanup");
    private static string FilePath => Path.Combine(Dir, "settings.json");

    public static Settings Current { get; private set; } = Load();

    public static Settings Load()
    {
        try
        {
            if (File.Exists(FilePath))
                return JsonSerializer.Deserialize<Settings>(File.ReadAllText(FilePath)) ?? new Settings();
        }
        catch { }
        return new Settings();
    }

    public void Save()
    {
        Directory.CreateDirectory(Dir);
        File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        Current = this;
    }

    public string ModelLabel => Backend switch
    {
        "chatgpt" => $"{ChatgptModel} · ChatGPT",
        "claude" => $"{ClaudeModel} · Claude",
        "openai" => ApiModel,
        _ => $"{OllamaModel} · Ollama",
    };

    // Resolve the agent engine: honour an explicit choice, otherwise mirror the
    // rewrite backend (chatgpt→codex, everything else→claude).
    public string ResolvedAgentEngine =>
        AgentEngine is "codex" or "claude" ? AgentEngine : (Backend == "chatgpt" ? "codex" : "claude");

    // The model for the resolved engine.
    public string AgentModel =>
        ResolvedAgentEngine == "claude" ? AgentClaudeModel : AgentCodexModel;
}
