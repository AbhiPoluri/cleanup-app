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
