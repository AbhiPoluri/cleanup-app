using System;
using System.IO;
using System.Text.Json;

namespace Cleanup;

public class Settings
{
    public string Backend { get; set; } = "ollama"; // ollama | chatgpt | openai
    public string OllamaUrl { get; set; } = "http://localhost:11434";
    public string OllamaModel { get; set; } = "llama3.2:3b";
    public string ApiBase { get; set; } = "https://api.openai.com";
    public string ApiKey { get; set; } = "";
    public string ApiModel { get; set; } = "gpt-4o-mini";
    public string ChatgptModel { get; set; } = "gpt-5.5";
    public string DefaultTone { get; set; } = "Clean";
    public int DefaultCount { get; set; } = 3;
    public bool FloatingButton { get; set; } = true;
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
    // Win32 MOD_* flags happen to match WPF ModifierKeys values (Alt=1, Ctrl=2, Shift=4, Win=8)
    public uint HotkeyModifiers { get; set; } = 0x2 | 0x4; // Ctrl+Shift
    public uint HotkeyKey { get; set; } = 0x45;            // E
    public string HotkeyDisplay { get; set; } = "Ctrl+Shift+E";

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
        "openai" => ApiModel,
        _ => $"{OllamaModel} · Ollama",
    };
}
