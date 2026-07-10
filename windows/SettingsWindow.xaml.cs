using System;
using System.Linq;
using System.Net.Http;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace Cleanup;

public partial class SettingsWindow : Window
{
    private uint _hkMods = Settings.Current.HotkeyModifiers;
    private uint _hkKey = Settings.Current.HotkeyKey;
    private string _hkDisplay = Settings.Current.HotkeyDisplay;

    public SettingsWindow()
    {
        InitializeComponent();
        var s = Settings.Current;

        SelectByTag(BackendBox, s.Backend);
        OllamaUrlBox.Text = s.OllamaUrl;
        OllamaModelBox.Text = s.OllamaModel;
        foreach (var m in Llm.ChatgptModels) ChatgptModelBox.Items.Add(new ComboBoxItem { Content = m });
        SelectByContent(ChatgptModelBox, s.ChatgptModel);
        if (ChatgptModelBox.SelectedIndex < 0) ChatgptModelBox.SelectedIndex = 0;
        foreach (var e in new[] { "low", "medium", "high" }) ChatgptEffortBox.Items.Add(new ComboBoxItem { Content = e });
        SelectByContent(ChatgptEffortBox, s.ChatgptEffort);
        if (ChatgptEffortBox.SelectedIndex < 0) ChatgptEffortBox.SelectedIndex = 0;
        ApiBaseBox.Text = s.ApiBase;
        ApiKeyBox.Password = s.ApiKey;
        ApiModelBox.Text = s.ApiModel;
        SelectByContent(ToneBox, s.DefaultTone);
        SelectByContent(CountBox, s.DefaultCount.ToString());
        FloatingButtonCheck.IsChecked = s.FloatingButton;
        AutoCloseCheck.IsChecked = s.AutoClose;
        ButtonSizeSlider.Value = Math.Clamp(s.FloatingButtonSize, 22, 48);
        FontSizeSlider.Value = Math.Clamp(s.FontSize, 11, 18);
        HotkeyBox.Text = _hkDisplay;
        CodexStatusLabel.Text = Llm.CodexStatus();
        VersionLabel.Text = Updater.IsDevBuild ? "dev build — update check only" : Updater.DisplayVersion;

        UpdatePanels();
        _ = LoadOllamaModels();
    }

    private UpdateInfo? _pendingUpdate;

    private async void Update_Click(object sender, RoutedEventArgs e)
    {
        // Second click when an update is staged → download + install.
        if (_pendingUpdate is { UpdateAvailable: true, DownloadUrl.Length: > 0 })
        {
            UpdateBtn.IsEnabled = false;
            SetUpdateStatus("downloading…");
            var ok = await Updater.DownloadAndRunAsync(_pendingUpdate);
            if (ok)
            {
                SetUpdateStatus("installing — Cleanup will restart");
                Application.Current.Shutdown();
            }
            else
            {
                UpdateBtn.IsEnabled = true;
                SetUpdateStatus("update failed — see the log (tray → Open Log)");
            }
            return;
        }

        // First click → check GitHub.
        UpdateBtn.IsEnabled = false;
        SetUpdateStatus("checking for updates…");
        var info = await Updater.CheckAsync();
        UpdateBtn.IsEnabled = true;

        if (info.Error != null)
        {
            SetUpdateStatus("couldn't check for updates — check your connection");
        }
        else if (info.UpdateAvailable && info.DownloadUrl.Length > 0)
        {
            _pendingUpdate = info;
            var label = info.LatestVersion.StartsWith("v", StringComparison.OrdinalIgnoreCase)
                ? info.LatestVersion : "v" + info.LatestVersion;
            SetUpdateStatus($"{label} available");
            UpdateBtn.Content = "Update now";
        }
        else if (info.UpdateAvailable)
        {
            SetUpdateStatus("a newer version exists but its installer is missing");
        }
        else
        {
            SetUpdateStatus("up to date");
        }
    }

    private void SetUpdateStatus(string text)
    {
        UpdateStatus.Text = text;
        UpdateStatus.Visibility = Visibility.Visible;
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

    private void ButtonSize_Changed(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (ButtonSizeValue != null) ButtonSizeValue.Text = ((int)Math.Round(e.NewValue)).ToString();
    }

    private void FontSize_Changed(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        if (FontSizeValue != null) FontSizeValue.Text = ((int)Math.Round(e.NewValue)).ToString();
    }

    private void Hotkey_GotFocus(object sender, RoutedEventArgs e)
    {
        HotkeyBox.Text = "press the new hotkey…";
    }

    private void Hotkey_KeyDown(object sender, KeyEventArgs e)
    {
        e.Handled = true;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        // wait for a real key, not a lone modifier
        if (key is Key.LeftCtrl or Key.RightCtrl or Key.LeftShift or Key.RightShift
            or Key.LeftAlt or Key.RightAlt or Key.LWin or Key.RWin or Key.None)
            return;
        var mods = Keyboard.Modifiers;
        if (mods == ModifierKeys.None)
        {
            HotkeyBox.Text = "needs a modifier (Ctrl / Alt / Shift) — try again";
            return;
        }
        _hkMods = (uint)mods; // WPF ModifierKeys values match Win32 MOD_* flags
        _hkKey = (uint)KeyInterop.VirtualKeyFromKey(key);
        _hkDisplay = string.Join("+", new[]
        {
            mods.HasFlag(ModifierKeys.Control) ? "Ctrl" : null,
            mods.HasFlag(ModifierKeys.Alt) ? "Alt" : null,
            mods.HasFlag(ModifierKeys.Shift) ? "Shift" : null,
            mods.HasFlag(ModifierKeys.Windows) ? "Win" : null,
            key.ToString(),
        }.Where(x => x != null));
        HotkeyBox.Text = _hkDisplay;
    }

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
        s.ChatgptEffort = ((ChatgptEffortBox.SelectedItem as ComboBoxItem)?.Content as string) ?? "low";
        s.ApiBase = ApiBaseBox.Text.Trim();
        s.ApiKey = ApiKeyBox.Password;
        s.ApiModel = ApiModelBox.Text.Trim();
        s.DefaultTone = ((ToneBox.SelectedItem as ComboBoxItem)?.Content as string) ?? "Clean";
        s.DefaultCount = int.TryParse((CountBox.SelectedItem as ComboBoxItem)?.Content as string, out var n) ? n : 3;
        s.FloatingButton = FloatingButtonCheck.IsChecked == true;
        s.AutoClose = AutoCloseCheck.IsChecked == true;
        s.FloatingButtonSize = Math.Round(ButtonSizeSlider.Value);
        s.FontSize = Math.Round(FontSizeSlider.Value);
        if (_hkKey != 0)
        {
            s.HotkeyModifiers = _hkMods;
            s.HotkeyKey = _hkKey;
            s.HotkeyDisplay = _hkDisplay;
        }
        s.Save();
        AppController.Current?.RefreshHotkey();
        Close();
    }
}
