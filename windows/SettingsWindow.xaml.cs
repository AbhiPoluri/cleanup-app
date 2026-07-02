using System;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;

namespace Cleanup;

public partial class SettingsWindow : Window
{
    public SettingsWindow()
    {
        InitializeComponent();
        var s = Settings.Current;

        SelectByTag(BackendBox, s.Backend);
        OllamaUrlBox.Text = s.OllamaUrl;
        OllamaModelBox.Text = s.OllamaModel;
        foreach (var m in new[] { "gpt-5.5" }) ChatgptModelBox.Items.Add(new ComboBoxItem { Content = m });
        ChatgptModelBox.SelectedIndex = 0;
        ApiBaseBox.Text = s.ApiBase;
        ApiKeyBox.Password = s.ApiKey;
        ApiModelBox.Text = s.ApiModel;
        SelectByContent(ToneBox, s.DefaultTone);
        SelectByContent(CountBox, s.DefaultCount.ToString());
        FloatingButtonCheck.IsChecked = s.FloatingButton;
        CodexStatusLabel.Text = Llm.CodexStatus();

        UpdatePanels();
        _ = LoadOllamaModels();
    }

    private async System.Threading.Tasks.Task LoadOllamaModels()
    {
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(4) };
            var json = await http.GetStringAsync(Settings.Current.OllamaUrl.TrimEnd('/') + "/api/tags");
            using var doc = JsonDocument.Parse(json);
            var names = doc.RootElement.GetProperty("models").EnumerateArray()
                .Select(m => m.GetProperty("name").GetString()!)
                .Where(n => !n.Contains("embed"))
                .OrderBy(n => n);
            foreach (var n in names) OllamaModelBox.Items.Add(n);
        }
        catch { /* server not running — the box stays editable */ }
    }

    private static void SelectByTag(ComboBox box, string tag)
    {
        foreach (ComboBoxItem item in box.Items)
            if ((string)item.Tag == tag) { box.SelectedItem = item; return; }
        box.SelectedIndex = 0;
    }

    private static void SelectByContent(ComboBox box, string content)
    {
        foreach (ComboBoxItem item in box.Items)
            if ((string)item.Content == content) { box.SelectedItem = item; return; }
        box.SelectedIndex = 0;
    }

    private string SelectedBackend =>
        (string)((ComboBoxItem?)BackendBox.SelectedItem)?.Tag! ?? "ollama";

    private void Backend_Changed(object sender, SelectionChangedEventArgs e) => UpdatePanels();

    private void UpdatePanels()
    {
        if (OllamaPanel == null) return; // fires during InitializeComponent
        var b = SelectedBackend;
        OllamaPanel.Visibility = b == "ollama" ? Visibility.Visible : Visibility.Collapsed;
        ChatgptPanel.Visibility = b == "chatgpt" ? Visibility.Visible : Visibility.Collapsed;
        OpenaiPanel.Visibility = b == "openai" ? Visibility.Visible : Visibility.Collapsed;
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        var s = Settings.Current;
        s.Backend = SelectedBackend;
        s.OllamaUrl = OllamaUrlBox.Text.Trim();
        s.OllamaModel = OllamaModelBox.Text.Trim();
        s.ChatgptModel = ((ChatgptModelBox.SelectedItem as ComboBoxItem)?.Content as string) ?? "gpt-5.5";
        s.ApiBase = ApiBaseBox.Text.Trim();
        s.ApiKey = ApiKeyBox.Password;
        s.ApiModel = ApiModelBox.Text.Trim();
        s.DefaultTone = ((ToneBox.SelectedItem as ComboBoxItem)?.Content as string) ?? "Clean";
        s.DefaultCount = int.TryParse((CountBox.SelectedItem as ComboBoxItem)?.Content as string, out var n) ? n : 3;
        s.FloatingButton = FloatingButtonCheck.IsChecked == true;
        s.Save();
        Close();
    }
}
