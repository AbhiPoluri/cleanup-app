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
    private uint _hk2Mods = Settings.Current.HotkeyModifiers2;
    private uint _hk2Key = Settings.Current.HotkeyKey2;
    private string _hk2Display = Settings.Current.HotkeyDisplay2;

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
        HotkeyBox2.Text = _hk2Display;
        TriggerHint.Text = $"Trigger: select text, then {_hkDisplay} for the popup or {_hk2Display} " +
                           "to instantly rewrite in place — or click the ✦ / ⚡ buttons.";
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

    private void Hotkey_GotFocus(object sender, RoutedEventArgs e) =>
        HotkeyBox.Text = "press the new hotkey…";

    private void Hotkey2_GotFocus(object sender, RoutedEventArgs e) =>
        HotkeyBox2.Text = "press the new hotkey…";

    private void Hotkey_KeyDown(object sender, KeyEventArgs e) =>
        RecordInto(e, HotkeyBox, (m, k, d) => { _hkMods = m; _hkKey = k; _hkDisplay = d; });

    private void Hotkey2_KeyDown(object sender, KeyEventArgs e) =>
        RecordInto(e, HotkeyBox2, (m, k, d) => { _hk2Mods = m; _hk2Key = k; _hk2Display = d; });

    // Shared recorder: turns a keypress into a (modifiers, vk, display) hotkey and
    // stores it via the callback. Ignores lone modifiers; requires a modifier.
    private static void RecordInto(KeyEventArgs e, TextBox box, Action<uint, uint, string> store)
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
            box.Text = "needs a modifier (Ctrl / Alt / Shift) — try again";
            return;
        }
        var display = string.Join("+", new[]
        {
            mods.HasFlag(ModifierKeys.Control) ? "Ctrl" : null,
            mods.HasFlag(ModifierKeys.Alt) ? "Alt" : null,
            mods.HasFlag(ModifierKeys.Shift) ? "Shift" : null,
            mods.HasFlag(ModifierKeys.Windows) ? "Win" : null,
            key.ToString(),
        }.Where(x => x != null));
        box.Text = display;
        // WPF ModifierKeys values match Win32 MOD_* flags
        store((uint)mods, (uint)KeyInterop.VirtualKeyFromKey(key), display);
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
        if (_hk2Key != 0)
        {
            s.HotkeyModifiers2 = _hk2Mods;
            s.HotkeyKey2 = _hk2Key;
            s.HotkeyDisplay2 = _hk2Display;
        }
        s.Save();
        AppController.Current?.RefreshHotkey();
        Close();
    }
}
