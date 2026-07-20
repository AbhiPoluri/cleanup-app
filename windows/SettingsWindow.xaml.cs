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
    // Mono theme (light/dark by OS pref) — the whole Settings window is themed to match
    // the rest of the app, migrated off the old SystemColors light chrome.
    private readonly Theme _t = Theme.Detect();

    private uint _hkMods = Settings.Current.HotkeyModifiers;
    private uint _hkKey = Settings.Current.HotkeyKey;
    private string _hkDisplay = Settings.Current.HotkeyDisplay;
    private uint _hk2Mods = Settings.Current.HotkeyModifiers2;
    private uint _hk2Key = Settings.Current.HotkeyKey2;
    private string _hk2Display = Settings.Current.HotkeyDisplay2;

    // Polls the cheap health rows (hotkey / token) every ~2s while the window is open, so
    // they stay live without re-running the CLI probes (those keep the 10s cache).
    private System.Windows.Threading.DispatcherTimer? _healthPoll;

    public SettingsWindow()
    {
        InitializeComponent();
        var s = Settings.Current;

        ApplyTheme();
        // restore the last size, clamped to the mins
        Width = Math.Max(640, s.SettingsWidth);
        Height = Math.Max(480, s.SettingsHeight);
        ShowSection("health");                 // Health lands first
        SourceInitialized += (_, _) => TryDarkTitleBar();
        Closing += (_, _) =>
        {
            _voiceInstallCts?.Cancel();
            Settings.Current.SettingsWidth = ActualWidth;
            Settings.Current.SettingsHeight = ActualHeight;
            Settings.Current.Save();
        };

        SelectByTag(BackendBox, s.Backend);
        OllamaUrlBox.Text = s.OllamaUrl;
        OllamaModelBox.Text = s.OllamaModel;
        foreach (var m in Llm.ChatgptModels) ChatgptModelBox.Items.Add(new ComboBoxItem { Content = m });
        SelectByContent(ChatgptModelBox, s.ChatgptModel);
        if (ChatgptModelBox.SelectedIndex < 0) ChatgptModelBox.SelectedIndex = 0;
        foreach (var e in new[] { "low", "medium", "high" }) ChatgptEffortBox.Items.Add(new ComboBoxItem { Content = e });
        SelectByContent(ChatgptEffortBox, s.ChatgptEffort);
        if (ChatgptEffortBox.SelectedIndex < 0) ChatgptEffortBox.SelectedIndex = 0;
        foreach (var m in new[] { "haiku", "sonnet", "opus" }) ClaudeModelBox.Items.Add(m);
        ClaudeModelBox.Text = s.ClaudeModel;
        ClaudeStatusLabel.Text = "Checking for the Claude Code CLI…";
        ApiBaseBox.Text = s.ApiBase;
        ApiKeyBox.Password = s.ApiKey;
        ApiModelBox.Text = s.ApiModel;
        SelectByContent(ToneBox, s.DefaultTone);
        SelectByContent(CountBox, s.DefaultCount.ToString());
        FloatingButtonCheck.IsChecked = s.FloatingButton;
        ChipStarCheck.IsChecked = s.ChipStar;
        ChipBoltCheck.IsChecked = s.ChipBolt;
        ChipAgentCheck.IsChecked = s.ChipAgent;
        ChipSnipCheck.IsChecked = s.ChipSnip;
        ChipTogglesPanel.IsEnabled = s.FloatingButton;   // grey the per-chip toggles when the master is off
        AutoCloseCheck.IsChecked = s.AutoClose;
        ButtonSizeSlider.Value = Math.Clamp(s.FloatingButtonSize, 22, 48);
        FontSizeSlider.Value = Math.Clamp(s.FontSize, 11, 18);
        HotkeyBox.Text = _hkDisplay;
        HotkeyBox2.Text = _hk2Display;
        TriggerHint.Text = $"Trigger: select text, then {_hkDisplay} for the popup or {_hk2Display} " +
                           "to instantly rewrite in place — or click the floating ✦ / instant buttons.";
        CodexStatusLabel.Text = Llm.CodexStatus();
        VersionLabel.Text = Updater.IsDevBuild ? "dev build — update check only" : Updater.DisplayVersion;

        // ---- Agent mode section ----
        _agentLoading = true;          // suppress the change handler while wiring initial state
        _agentClaudeModel = s.AgentClaudeModel;
        _agentCodexModel = s.AgentCodexModel;
        _agentEngineSel = s.ResolvedAgentEngine;
        SelectByTag(AgentEngineBox, _agentEngineSel);
        SelectByTag(AgentPermBox, s.AgentPermission);
        if (AgentPermBox.SelectedIndex < 0) AgentPermBox.SelectedIndex = 0;
        AgentContextBox.Text = s.AgentContext;
        SelectByTag(VoiceASRBox, s.VoiceASR);
        SelectByTag(VoiceTTSBox, s.VoiceTTS);
        RepopulateAgentModels();       // fill the model box for the selected engine
        UpdateAgentWarn();
        _agentLoading = false;

        UpdatePanels();
        _ = LoadOllamaModels();
        _ = LoadClaudeStatus();
        _ = RefreshAgentStatus();
        _ = RefreshVoiceStatus();
        _ = LoadHealth();

        _healthPoll = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        _healthPoll.Tick += (_, _) =>
        {
            if (HealthPanel == null) return;
            var rows = Health.RefreshCheapRows();
            if (rows != null)
                HealthView.Render(HealthPanel, rows,
                    titleBrush: _t.Text, mutedBrush: _t.Muted,
                    fixBrush: _t.Text, fixBorderBrush: _t.LineStrong);
        };
        _healthPoll.Start();
        Closed += (_, _) => _healthPoll?.Stop();
    }

    // ---- Health checklist ----
    // Rendered with the Mono theme brushes so it reads on the dark Settings surface
    // (migrated off the old SystemColors light-chrome brushes).
    private async System.Threading.Tasks.Task LoadHealth(bool force = false)
    {
        if (HealthPanel == null) return;
        HealthRefreshBtn.IsEnabled = false;
        try
        {
            var rows = await Health.GetRowsAsync(force);
            HealthView.Render(HealthPanel, rows,
                titleBrush: _t.Text, mutedBrush: _t.Muted,
                fixBrush: _t.Text, fixBorderBrush: _t.LineStrong);
        }
        catch { /* health is best-effort — never block the settings window */ }
        finally { if (HealthRefreshBtn != null) HealthRefreshBtn.IsEnabled = true; }
    }

    private async void HealthRefresh_Click(object sender, RoutedEventArgs e) => await LoadHealth(true);

    // ---- theme + navigation ----

    // Inject the Mono palette into window Resources (the XAML styles bind to these keys via
    // DynamicResource), then paint the structural chrome that isn't style-driven.
    private void ApplyTheme()
    {
        void Put(string k, System.Windows.Media.Brush b) => Resources[k] = b;
        Put("Surface", _t.Surface); Put("Surface2", _t.Surface2); Put("Surface3", _t.Surface3);
        Put("Line", _t.Line); Put("LineStrong", _t.LineStrong);
        Put("Text", _t.Text); Put("Muted", _t.Muted); Put("Faint", _t.Faint);
        Put("Accent", _t.Accent); Put("OnAccent", _t.OnAccent);

        Background = _t.Surface;
        Root.Background = _t.Surface;
        Sidebar.Background = _t.Surface2;
        Sidebar.BorderBrush = _t.Line;
        Footer.Background = _t.Surface;
        Footer.BorderBrush = _t.Line;
        SaveBtn.Background = _t.Accent;
        SaveBtn.Foreground = _t.OnAccent;
        SaveBtn.BorderBrush = _t.Accent;
    }

    private readonly string[] _sections = { "health", "rewrite", "triggers", "agent", "about" };

    private void Nav_Click(object sender, RoutedEventArgs e)
    {
        if (sender is System.Windows.Controls.Button b && b.Tag is string tag) ShowSection(tag);
    }

    // Swap the visible section ScrollViewer + reflect the selection in the sidebar.
    private void ShowSection(string tag)
    {
        HealthScroll.Visibility   = tag == "health"   ? Visibility.Visible : Visibility.Collapsed;
        RewriteScroll.Visibility  = tag == "rewrite"  ? Visibility.Visible : Visibility.Collapsed;
        TriggersScroll.Visibility = tag == "triggers" ? Visibility.Visible : Visibility.Collapsed;
        AgentScroll.Visibility    = tag == "agent"    ? Visibility.Visible : Visibility.Collapsed;
        AboutScroll.Visibility    = tag == "about"    ? Visibility.Visible : Visibility.Collapsed;

        foreach (var nav in new[] { NavHealth, NavRewrite, NavTriggers, NavAgent, NavAbout })
        {
            var selected = (nav.Tag as string) == tag;
            nav.Background = selected ? _t.Surface3 : System.Windows.Media.Brushes.Transparent;
            nav.Foreground = selected ? _t.Text : _t.Muted;
        }
    }

    // Best-effort dark title bar (DWM immersive dark mode) when the OS theme is dark.
    private void TryDarkTitleBar()
    {
        if (_t != Theme.Dark) return;
        try
        {
            var hwnd = new System.Windows.Interop.WindowInteropHelper(this).Handle;
            int on = 1;
            // DWMWA_USE_IMMERSIVE_DARK_MODE = 20 (19 on older Win10 builds)
            if (DwmSetWindowAttribute(hwnd, 20, ref on, sizeof(int)) != 0)
                DwmSetWindowAttribute(hwnd, 19, ref on, sizeof(int));
        }
        catch { /* purely cosmetic — never fail the window over the title bar */ }
    }

    [System.Runtime.InteropServices.DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    // ---- Agent mode ----
    // Per-engine model kept locally so switching engines in the UI never carries a
    // wrong model id across; persisted to the matching field on Save.
    private string _agentClaudeModel = Settings.Current.AgentClaudeModel;
    private string _agentCodexModel = Settings.Current.AgentCodexModel;
    private string _agentEngineSel = Settings.Current.ResolvedAgentEngine;
    private bool _agentLoading;

    private string SelectedAgentEngine =>
        (string)((ComboBoxItem?)AgentEngineBox.SelectedItem)?.Tag! ?? "codex";
    private string SelectedAgentPerm =>
        (string)((ComboBoxItem?)AgentPermBox.SelectedItem)?.Tag! ?? "safe";

    private void AgentEngine_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (AgentModelBox == null || _agentLoading) return;   // fires during InitializeComponent / initial load
        // remember the model typed for the previously-selected engine before swapping
        StashAgentModel(_agentEngineSel);
        _agentEngineSel = SelectedAgentEngine;
        RepopulateAgentModels();
        _ = RefreshAgentStatus();
    }

    private void AgentPerm_Changed(object sender, SelectionChangedEventArgs e) => UpdateAgentWarn();

    private void StashAgentModel(string engine)
    {
        var v = AgentModelBox.Text.Trim();
        if (engine == "claude") _agentClaudeModel = v.Length > 0 ? v : "sonnet";
        else _agentCodexModel = v.Length > 0 ? v : "gpt-5.5";
    }

    private void RepopulateAgentModels()
    {
        AgentModelBox.Items.Clear();
        if (SelectedAgentEngine == "claude")
        {
            foreach (var m in new[] { "haiku", "sonnet", "opus" }) AgentModelBox.Items.Add(m);
            AgentModelBox.Text = _agentClaudeModel;
        }
        else
        {
            foreach (var m in Llm.ChatgptModels) AgentModelBox.Items.Add(m);
            AgentModelBox.Text = _agentCodexModel;
        }
    }

    private void UpdateAgentWarn()
    {
        if (AgentWarnLabel != null)
            AgentWarnLabel.Visibility = SelectedAgentPerm == "full" ? Visibility.Visible : Visibility.Collapsed;
    }

    // CLI availability + login status for the selected agent engine.
    private async System.Threading.Tasks.Task RefreshAgentStatus()
    {
        if (AgentStatusLabel == null) return;
        try
        {
            if (SelectedAgentEngine == "codex")
                AgentStatusLabel.Text = Llm.ResolveCodexCli() == null
                    ? "Codex CLI not found — npm i -g @openai/codex, then run `codex login`"
                    : Llm.CodexStatus();
            else
            {
                AgentStatusLabel.Text = "Checking for the Claude Code CLI…";
                AgentStatusLabel.Text = await Llm.ClaudeStatus();
            }
        }
        catch { AgentStatusLabel.Text = "Could not check the agent CLI"; }
    }

    private async System.Threading.Tasks.Task LoadClaudeStatus()
    {
        try { ClaudeStatusLabel.Text = await Llm.ClaudeStatus(); }
        catch { ClaudeStatusLabel.Text = "Could not check the Claude Code CLI"; }
    }

    // ---- local voice engines (Parakeet ASR + Kokoro TTS) ----

    private string SelectedVoiceASR =>
        (string)((ComboBoxItem?)VoiceASRBox.SelectedItem)?.Tag! ?? "system";
    private string SelectedVoiceTTS =>
        (string)((ComboBoxItem?)VoiceTTSBox.SelectedItem)?.Tag! ?? "system";

    private System.Threading.CancellationTokenSource? _voiceInstallCts;

    private void SetVoiceInstallUi(string title, string detail, System.Windows.Media.Brush dot,
        string action, bool installing = false, bool canCancel = false,
        double? progress = null, string? step = null)
    {
        VoiceStateTitle.Text = title;
        VoiceStatusLabel.Text = detail;
        VoiceStateDot.Fill = dot;
        VoiceInstallBtn.Content = action;
        VoiceInstallBtn.IsEnabled = !installing;
        VoiceCancelBtn.Visibility = canCancel ? Visibility.Visible : Visibility.Collapsed;
        VoiceCancelBtn.IsEnabled = canCancel;
        VoiceInstallProgress.Visibility = progress.HasValue ? Visibility.Visible : Visibility.Collapsed;
        VoiceInstallProgress.Value = progress ?? 0;
        VoiceInstallStepLabel.Text = step ?? "";
        VoiceInstallStepLabel.Visibility = step == null ? Visibility.Collapsed : Visibility.Visible;
        VoiceInstallHint.Text = canCancel
            ? "Keep Settings open. You can cancel safely; running the installer again resumes setup."
            : "Parakeet uses memory-optimized INT8 weights and releases model RAM after 2 minutes idle. Models download once when first used.";
        VoiceTestBtn.IsEnabled = !installing && !_voiceTesting;
    }

    // Reflect install/helper state into the status box + the button label. Pings the helper
    // when installed (spawns it once — reused by the mic afterwards).
    private async System.Threading.Tasks.Task RefreshVoiceStatus()
    {
        if (VoiceStatusLabel == null) return;
        if (_voiceInstallCts != null) return;   // an install is driving the label right now
        try
        {
            if (!VoiceEngine.IsInstalled)
            {
                if (VoiceEngine.SystemPythonAvailable())
                    SetVoiceInstallUi("Ready to install",
                        "Python is available. Setup usually takes a few minutes.", _t.Muted,
                        "Install local voice engines");
                else
                    SetVoiceInstallUi("Python is required",
                        "Install Python 3.10 or newer from python.org, then return here.", _t.DiffDelText,
                        "Check again");
                return;
            }
            SetVoiceInstallUi("Checking local voice", "Confirming that the helper can start.",
                _t.Muted, "Checking…", installing: true, progress: 96, step: "Verifying");
            var ping = await VoiceEngine.Ping();
            if (ping == null)
            {
                SetVoiceInstallUi("Repair needed",
                    "The files are installed, but the helper did not respond.", _t.DiffDelText,
                    "Repair installation");
                return;
            }
            var model = VoiceEngine.ParakeetModelPresent()
                ? "INT8 Parakeet model ready" : "INT8 Parakeet model downloads on first mic use";
            SetVoiceInstallUi("Local voice is ready",
                $"Parakeet {(ping.Value.Asr ? "available" : "unavailable")} · Kokoro {(ping.Value.Tts ? "available" : "unavailable")} · {model}.",
                _t.DiffAddText, "Reinstall");
        }
        catch
        {
            SetVoiceInstallUi("Status check failed", "Cleanup could not inspect the local voice installation.",
                _t.DiffDelText, "Try again");
        }
    }

    // "Test voice" — audition the selected speech-output engine right from Settings.
    private bool _voiceTesting;
    private async void VoiceTest_Click(object sender, RoutedEventArgs e)
    {
        if (_voiceTesting) return;
        const string sample = "Hi — this is how I'll sound at the whiteboard.";
        var tts = (VoiceTTSBox.SelectedItem as ComboBoxItem)?.Tag as string ?? "system";
        void Say(string m) { if (VoiceTestStatus != null) VoiceTestStatus.Text = m; }

        if (tts != "kokoro")
        {
            try { using var synth = new System.Speech.Synthesis.SpeechSynthesizer(); synth.SpeakAsync(sample); Say("That's the system voice."); }
            catch { Say("System voice is unavailable."); }
            return;
        }
        if (!VoiceEngine.IsInstalled) { Say("Not installed — use \"Install local voice engines\" first."); return; }

        _voiceTesting = true;
        VoiceTestBtn.IsEnabled = false;
        Say("Synthesizing… (first use downloads the model)");
        try
        {
            var outPath = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"cleanup-tts-{Guid.NewGuid():N}.wav");
            var ok = await VoiceEngine.Synthesize(sample, outPath);
            if (ok != null && System.IO.File.Exists(outPath))
            {
                Say("Playing…");
                using var player = new System.Media.SoundPlayer(outPath);
                await System.Threading.Tasks.Task.Run(() => player.PlaySync());
                try { System.IO.File.Delete(outPath); } catch { }
                Say("That's the Kokoro voice.");
            }
            else Say("Couldn't synthesize — see the log (tray → Open Log).");
        }
        catch (Exception ex) { Say("Test failed — " + ex.Message); }
        finally { _voiceTesting = false; VoiceTestBtn.IsEnabled = true; }
    }

    private async void VoiceInstall_Click(object sender, RoutedEventArgs e)
    {
        if (_voiceInstallCts != null) return;   // already installing
        var cts = new System.Threading.CancellationTokenSource();
        _voiceInstallCts = cts;
        var lastProgress = 0d;
        var currentStep = "Starting";
        var installClock = System.Diagnostics.Stopwatch.StartNew();
        var activityTimer = new System.Windows.Threading.DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(1),
        };
        activityTimer.Tick += (_, _) =>
        {
            if (_voiceInstallCts == null) return;
            var elapsed = installClock.Elapsed;
            VoiceInstallStepLabel.Text = $"{currentStep} · {(int)elapsed.TotalMinutes}:{elapsed.Seconds:00} elapsed";
        };
        activityTimer.Start();
        void Report(VoiceInstallProgress p) => Dispatcher.Invoke(() =>
        {
            lastProgress = p.Percent;
            currentStep = $"Step {p.Step} of {p.TotalSteps}";
            SetVoiceInstallUi(p.Title, p.Detail, _t.Accent, "Installing…", installing: true,
                canCancel: true, progress: p.Percent, step: currentStep);
        });
        try
        {
            var result = await VoiceEngine.Install(Report, cts.Token);
            if (ReferenceEquals(_voiceInstallCts, cts)) _voiceInstallCts = null;
            switch (result)
            {
                case VoiceInstallResult.Success:
                    SetVoiceInstallUi("Local voice is ready",
                        "Installation completed. Parakeet and Kokoro are available locally.",
                        _t.DiffAddText, "Reinstall", progress: 100, step: "Complete");
                    break;
                case VoiceInstallResult.Cancelled:
                    SetVoiceInstallUi("Installation cancelled",
                        "No active download. Run setup again to continue from the existing files.",
                        _t.Muted, "Resume installation", progress: lastProgress);
                    break;
                case VoiceInstallResult.MissingPython:
                    SetVoiceInstallUi("Python is required",
                        "Install Python 3.10 or newer from python.org, then return here.",
                        _t.DiffDelText, "Check again");
                    break;
                default:
                    SetVoiceInstallUi("Installation failed",
                        "Setup stopped before completion. Try again, or open the log from the tray for details.",
                        _t.DiffDelText, "Try again", progress: lastProgress);
                    break;
            }
        }
        catch
        {
            if (ReferenceEquals(_voiceInstallCts, cts)) _voiceInstallCts = null;
            SetVoiceInstallUi("Installation failed",
                "Setup stopped before completion. Try again, or open the log from the tray for details.",
                _t.DiffDelText, "Try again", progress: lastProgress);
        }
        finally
        {
            activityTimer.Stop();
            installClock.Stop();
            if (ReferenceEquals(_voiceInstallCts, cts)) _voiceInstallCts = null;
            _ = LoadHealth(true);   // refresh the Local voice health row too
        }
    }

    private void VoiceCancel_Click(object sender, RoutedEventArgs e)
    {
        if (_voiceInstallCts == null) return;
        VoiceCancelBtn.IsEnabled = false;
        VoiceStateTitle.Text = "Cancelling installation";
        VoiceStatusLabel.Text = "Stopping the current setup process safely…";
        _voiceInstallCts.Cancel();
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

    // Master toggle drives the per-chip toggles' enabled state (greyed when off).
    private void FloatingButton_Changed(object sender, RoutedEventArgs e)
    {
        if (ChipTogglesPanel != null)
            ChipTogglesPanel.IsEnabled = FloatingButtonCheck.IsChecked == true;
    }

    private void UpdatePanels()
    {
        if (OllamaPanel == null) return; // fires during InitializeComponent
        var b = SelectedBackend;
        OllamaPanel.Visibility = b == "ollama" ? Visibility.Visible : Visibility.Collapsed;
        ChatgptPanel.Visibility = b == "chatgpt" ? Visibility.Visible : Visibility.Collapsed;
        ClaudePanel.Visibility = b == "claude" ? Visibility.Visible : Visibility.Collapsed;
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
        var claudeModel = ClaudeModelBox.Text.Trim();
        s.ClaudeModel = claudeModel.Length > 0 ? claudeModel : "haiku";
        s.ApiBase = ApiBaseBox.Text.Trim();
        s.ApiKey = ApiKeyBox.Password;
        s.ApiModel = ApiModelBox.Text.Trim();
        s.DefaultTone = ((ToneBox.SelectedItem as ComboBoxItem)?.Content as string) ?? "Clean";
        s.DefaultCount = int.TryParse((CountBox.SelectedItem as ComboBoxItem)?.Content as string, out var n) ? n : 3;
        // agent mode (independent of the rewrite backend)
        StashAgentModel(SelectedAgentEngine);   // capture the current box into its engine slot
        s.AgentEngine = SelectedAgentEngine;
        s.AgentClaudeModel = _agentClaudeModel;
        s.AgentCodexModel = _agentCodexModel;
        s.AgentPermission = SelectedAgentPerm;
        s.AgentContext = AgentContextBox.Text;
        s.VoiceASR = SelectedVoiceASR;
        s.VoiceTTS = SelectedVoiceTTS;
        s.FloatingButton = FloatingButtonCheck.IsChecked == true;
        s.ChipStar = ChipStarCheck.IsChecked == true;
        s.ChipBolt = ChipBoltCheck.IsChecked == true;
        s.ChipAgent = ChipAgentCheck.IsChecked == true;
        s.ChipSnip = ChipSnipCheck.IsChecked == true;
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
        // personal context is global — regenerate EVERY project's CLAUDE.md / AGENTS.md
        ProjectStore.RegenerateAll();
        AppController.Current?.RefreshHotkey();
        Close();
    }
}
