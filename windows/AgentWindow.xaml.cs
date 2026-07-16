using System;
using System.Runtime.InteropServices;
using System.Speech.Recognition;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;

namespace Cleanup;

// Agent mode: a clean, borderless chat window that spins up an agentic CLI (Codex
// or Claude Code) and streams its work in. Mirrors PopupWindow's chrome (resizable
// borderless, drag-anywhere, entrance/exit animation, size persistence). Voice input
// via System.Speech. Engine / model / permission tier all come from Agent settings.
public partial class AgentWindow : Window
{
    private readonly Theme _t = Theme.Detect();
    private readonly AgentEngine _engine;
    private readonly ScreenUtil.NativePoint _anchor;
    private readonly double _fontSize = Math.Clamp(Settings.Current.FontSize, 11, 18);

    private string? _context;                 // selection context, appended to the FIRST task only
    private CancellationTokenSource? _runCts;  // in-flight turn (null = idle)
    private bool _busy;
    private bool _closeRequested;

    // live assistant bubble the streaming text writes into (null → next text opens a new one)
    private TextBlock? _curBubbleText;
    private bool _autoScroll = true;

    // ---- voice ----
    private SpeechRecognitionEngine? _speech;
    private bool _recording;
    private string _voiceBase = "";    // input text when recording started
    private string _voiceFinal = "";   // finalized phrases appended since

    public AgentWindow(string? context, ScreenUtil.NativePoint anchor)
    {
        _anchor = anchor;
        _engine = new AgentEngine(AgentEngine.SelectedKind());

        InitializeComponent();

        Width = Math.Max(MinWidth, Settings.Current.AgentWidth);
        Height = Math.Max(MinHeight, Settings.Current.AgentHeight);

        ApplyTheme();
        EngineLabel.Text = _engine.Label;

        // selection context → dim collapsed pill; kept for the first task
        var ctx = context?.Trim();
        if (!string.IsNullOrEmpty(ctx))
        {
            _context = ctx;
            var head = ctx.Replace("\n", " ");
            if (head.Length > 80) head = head[..80] + "…";
            ContextText.Text = "context: " + head;
            ContextPill.Visibility = Visibility.Visible;
        }

        InputBox.TextChanged += (_, _) =>
            InputPlaceholder.Visibility = InputBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;

        WireButton(CloseBtn, 0.85);
        WireButton(MicBtn, 0.9);
        WireButton(SendBtn, 1.0);

        InitSpeech();

        // if the selected engine's CLI is missing, say so and keep input disabled
        if (_engine.ResolveCli() == null)
        {
            AddDimLine(_engine.Kind == AgentEngineKind.Codex
                ? "Codex CLI not found. Install it (npm i -g @openai/codex) and run `codex login`, then reopen."
                : "Claude Code CLI not found. Install it and run `claude` once to log in, then reopen.");
            InputBox.IsEnabled = false;
            SendBtn.Opacity = 0.4;
        }
        else
        {
            AddDimLine("Ready — ask the agent to do anything. Follow-ups keep the same session.");
        }

        Closing += (_, _) => SaveSize();
        Closed += (_, _) => Cleanup();
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) { e.Handled = true; SafeClose(); } };

        Opacity = 0;
        Loaded += (_, _) => { PlayEntrance(); if (InputBox.IsEnabled) InputBox.Focus(); };
    }

    // ---------- theming ----------

    private void ApplyTheme()
    {
        Root.Background = _t.Surface;
        Root.BorderBrush = _t.LineStrong;
        TitleLabel.Foreground = _t.Text;
        EngineLabel.Foreground = _t.Faint;
        StatusDot.Fill = _t.Text;
        CloseBtn.Background = _t.Surface2; CloseBtn.BorderBrush = _t.Line; CloseLabel.Foreground = _t.Muted;
        ContextPill.Background = _t.Surface2; ContextPill.BorderBrush = _t.Line; ContextText.Foreground = _t.Muted;
        InputBar.Background = _t.Surface2; InputBar.BorderBrush = _t.LineStrong;
        InputBox.Foreground = _t.Text; InputBox.CaretBrush = _t.Text;
        InputPlaceholder.Foreground = _t.Faint;
        MicBtn.Background = _t.Surface2; MicBtn.BorderBrush = _t.Line; MicGlyph.Foreground = _t.Muted;
        SendBtn.Background = _t.Accent; SendGlyph.Foreground = _t.OnAccent; StopGlyph.Foreground = _t.OnAccent;
    }

    // ---------- transcript ----------

    private void Transcript_ScrollChanged(object sender, ScrollChangedEventArgs e)
    {
        // only react to user scrolls (content-growth events have ExtentHeightChange != 0)
        if (e.ExtentHeightChange == 0)
            _autoScroll = Transcript.VerticalOffset >= Transcript.ScrollableHeight - 2;
    }

    private void AutoScroll() { if (_autoScroll) Transcript.ScrollToEnd(); }

    private Border AddBubble(bool user)
    {
        var tb = new TextBlock { Foreground = _t.Text, TextWrapping = TextWrapping.Wrap, FontSize = _fontSize };
        var b = new Border
        {
            Child = tb,
            Background = user ? _t.Surface3 : _t.Surface2,
            BorderBrush = user ? _t.LineStrong : _t.Line,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(12, 9, 12, 9),
            Margin = user ? new Thickness(44, 0, 0, 10) : new Thickness(0, 0, 44, 10),
            HorizontalAlignment = user ? HorizontalAlignment.Right : HorizontalAlignment.Left,
        };
        Feed.Children.Add(b);
        Anim.FadeSlideIn(b, 6, 180);
        if (!user) _curBubbleText = tb;
        AutoScroll();
        return b;
    }

    private void AddUserBubble(string text)
    {
        _curBubbleText = null;
        ((TextBlock)AddBubble(user: true).Child).Text = text;
    }

    private void UpdateBubble(string text)
    {
        HideThinking();
        if (_curBubbleText == null) AddBubble(user: false);
        _curBubbleText!.Text = text;
        AutoScroll();
    }

    // Assistant-styled bubble with pulsing dots — visible whenever the agent is
    // working but has produced no output yet (first token on big models can take
    // 10s+; without this the window reads as dead and users assume it broke).
    private Border? _thinkingRow;
    private LoadingDots? _thinkingDots;

    private void ShowThinking()
    {
        if (_thinkingRow != null) return;
        _thinkingDots = new LoadingDots(_t.Text, 6, 5);
        _thinkingRow = new Border
        {
            Child = _thinkingDots,
            Background = _t.Surface2,
            BorderBrush = _t.Line,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(13, 11, 13, 11),
            Margin = new Thickness(0, 0, 44, 10),
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        Feed.Children.Add(_thinkingRow);
        _thinkingDots.Start();
        Anim.FadeSlideIn(_thinkingRow, 6, 180);
        AutoScroll();
    }

    private void HideThinking()
    {
        if (_thinkingRow == null) return;
        _thinkingDots?.Stop();
        Feed.Children.Remove(_thinkingRow);
        _thinkingRow = null;
        _thinkingDots = null;
    }

    // dim one-liner (tool use / raw output / stopped); slides in 4px and closes the bubble
    private void AddToolLine(string s)
    {
        HideThinking();
        _curBubbleText = null;
        var tb = new TextBlock
        {
            Text = s,
            Foreground = _t.Faint,
            FontSize = 11,
            FontFamily = new FontFamily("Consolas"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(2, 0, 0, 9),
        };
        Feed.Children.Add(tb);
        Anim.FadeSlideIn(tb, 4, 160);
        // still working after a tool line → dots return below it (keeps liveness
        // visible through the gaps between tool calls)
        if (_busy) ShowThinking();
        AutoScroll();
    }

    private void AddErrorLine(string msg)
    {
        _curBubbleText = null;
        var tb = new TextBlock
        {
            Text = "⚠ " + msg,
            Foreground = _t.Muted,
            FontSize = 12,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(2, 2, 0, 9),
        };
        Feed.Children.Add(tb);
        Anim.FadeSlideIn(tb, 4, 160);
        AutoScroll();
    }

    private void AddDimLine(string s)
    {
        _curBubbleText = null;
        var tb = new TextBlock
        {
            Text = s,
            Foreground = _t.Faint,
            FontSize = 11.5,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(2, 2, 0, 10),
        };
        Feed.Children.Add(tb);
        Anim.FadeSlideIn(tb, 4, 200);
        AutoScroll();
    }

    // ---------- send / run / stop ----------

    private void Send_Click(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        if (_busy) { _runCts?.Cancel(); return; }
        Submit();
    }

    private void Input_KeyDown(object sender, KeyEventArgs e)
    {
        // Enter sends; Shift+Enter inserts a newline (AcceptsReturn handles that)
        if (e.Key == Key.Enter && (Keyboard.Modifiers & ModifierKeys.Shift) == 0)
        {
            e.Handled = true;
            if (!_busy) Submit();
        }
    }

    private void Submit()
    {
        var text = InputBox.Text.Trim();
        if (text.Length == 0) { System.Media.SystemSounds.Beep.Play(); return; }
        if (_recording) StopRecording();

        InputBox.Clear();
        AddUserBubble(text);

        var task = text;
        if (_context != null)
        {
            task = text + "\n\nContext — the user had this text selected:\n" + _context;
            _context = null;
            Anim.OpacityTo(ContextPill, 0, 160);
            ContextPill.IsHitTestVisible = false;
        }
        _ = RunTurn(task);
    }

    private async Task RunTurn(string task)
    {
        SetBusy(true);
        _curBubbleText = null;
        var cts = new CancellationTokenSource();
        _runCts = cts;
        try
        {
            await _engine.Run(task,
                onText: s => Dispatcher.BeginInvoke(() => UpdateBubble(s)),
                onEvent: s => Dispatcher.BeginInvoke(() => AddToolLine(s)),
                cts.Token);
        }
        catch (OperationCanceledException) { AddToolLine("▸ stopped"); }
        catch (Exception ex) { AddErrorLine(ex.Message); }
        finally
        {
            if (ReferenceEquals(_runCts, cts)) _runCts = null;
            SetBusy(false);
            if (InputBox.IsEnabled) InputBox.Focus();
        }
    }

    private void SetBusy(bool busy)
    {
        _busy = busy;
        InputBox.IsEnabled = !busy;
        MicBtn.IsEnabled = !busy && _speech != null;
        MicBtn.Opacity = MicBtn.IsEnabled ? 0.9 : 0.4;
        // morph send ↔ stop (crossfade + a small scale pop)
        Anim.OpacityTo(SendGlyph, busy ? 0.0 : 1.0, 140);
        Anim.OpacityTo(StopGlyph, busy ? 1.0 : 0.0, 140);
        Anim.ScalePop(SendBtn, 1.12, 160);
        SendBtn.ToolTip = busy ? "Stop" : "Send  (Enter)";
        if (busy) { StartDot(); ShowThinking(); } else { StopDot(); HideThinking(); }
    }

    private void StartDot()
    {
        StatusDot.Visibility = Visibility.Visible;
        StatusDot.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0.9, 0.25, Anim.Ms(700))
        {
            AutoReverse = true,
            RepeatBehavior = RepeatBehavior.Forever,
            EasingFunction = Anim.EaseInOut,
        });
    }

    private void StopDot()
    {
        StatusDot.BeginAnimation(UIElement.OpacityProperty, null);
        StatusDot.Visibility = Visibility.Collapsed;
    }

    // ---------- voice ----------

    private void InitSpeech()
    {
        try
        {
            _speech = new SpeechRecognitionEngine();
            _speech.SetInputToDefaultAudioDevice();
            _speech.LoadGrammar(new DictationGrammar());
            _speech.SpeechHypothesized += (_, e) => Dispatcher.BeginInvoke(() => OnHypothesis(e.Result.Text));
            _speech.SpeechRecognized += (_, e) => Dispatcher.BeginInvoke(() => OnRecognized(e.Result.Text));
        }
        catch (Exception ex)
        {
            _speech = null;
            MicBtn.IsEnabled = false;
            MicBtn.Opacity = 0.4;
            MicBtn.ToolTip = "Voice input unavailable — no microphone or speech recognizer";
            Log.Write("agent: speech init failed — " + ex.Message);
        }
    }

    private void Mic_Click(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        if (_speech == null || _busy) return;
        if (_recording) StopRecording(); else StartRecording();
    }

    private void StartRecording()
    {
        _voiceBase = InputBox.Text.Length > 0 && !InputBox.Text.EndsWith(" ") ? InputBox.Text + " " : InputBox.Text;
        _voiceFinal = "";
        _recording = true;
        RestyleMic();
        try { _speech!.RecognizeAsync(RecognizeMode.Multiple); }
        catch (Exception ex) { Log.Write("agent: RecognizeAsync failed — " + ex.Message); StopRecording(); }
    }

    private void StopRecording()
    {
        if (!_recording) return;
        _recording = false;
        try { _speech?.RecognizeAsyncCancel(); } catch { }
        InputBox.Text = (_voiceBase + _voiceFinal).TrimEnd();   // drop any trailing hypothesis
        InputBox.Foreground = _t.Text;
        InputBox.CaretIndex = InputBox.Text.Length;
        RestyleMic();
        if (InputBox.IsEnabled) InputBox.Focus();
    }

    private void OnHypothesis(string h)
    {
        if (!_recording) return;
        InputBox.Text = _voiceBase + _voiceFinal + h;
        InputBox.Foreground = _t.Faint;   // dim = not yet final
        InputBox.CaretIndex = InputBox.Text.Length;
    }

    private void OnRecognized(string r)
    {
        if (!_recording) return;
        if (!string.IsNullOrWhiteSpace(r)) _voiceFinal += (_voiceFinal.Length > 0 ? " " : "") + r.Trim();
        InputBox.Text = _voiceBase + _voiceFinal;
        InputBox.Foreground = _t.Text;
        InputBox.CaretIndex = InputBox.Text.Length;
    }

    private void RestyleMic()
    {
        if (_recording)
        {
            MicBtn.Background = _t.Surface3;
            MicBtn.BorderBrush = _t.LineStrong;
            MicGlyph.Foreground = _t.Text;
            MicGlyph.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(1.0, 0.4, Anim.Ms(600))
            {
                AutoReverse = true,
                RepeatBehavior = RepeatBehavior.Forever,
                EasingFunction = Anim.EaseInOut,
            });
        }
        else
        {
            MicGlyph.BeginAnimation(UIElement.OpacityProperty, null);
            MicGlyph.Opacity = 1;
            MicBtn.Background = _t.Surface2;
            MicBtn.BorderBrush = _t.Line;
            MicGlyph.Foreground = _t.Muted;
        }
    }

    // ---------- window chrome (borderless, resizable) — mirrors PopupWindow ----------

    private const int GWL_STYLE = -16;
    private const int WS_THICKFRAME = 0x00040000;
    private const int WM_NCHITTEST = 0x0084;
    private const int HTCLIENT = 1, HTLEFT = 10, HTRIGHT = 11, HTTOP = 12, HTTOPLEFT = 13,
                      HTTOPRIGHT = 14, HTBOTTOM = 15, HTBOTTOMLEFT = 16, HTBOTTOMRIGHT = 17;

    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] private static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out ScreenUtil.NativeRect r);

    private static readonly IntPtr HWND_TOP = IntPtr.Zero;
    private const uint SWP_NOSIZE = 0x0001, SWP_NOZORDER = 0x0004, SWP_NOACTIVATE = 0x0010;

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var h = new WindowInteropHelper(this).Handle;
        SetWindowLong(h, GWL_STYLE, GetWindowLong(h, GWL_STYLE) | WS_THICKFRAME);
        HwndSource.FromHwnd(h)?.AddHook(WndProc);
        PositionNearAnchor(h);
    }

    private void PositionNearAnchor(IntPtr h)
    {
        uint dpi = ScreenUtil.DpiForPoint(_anchor.X, _anchor.Y);
        double s = dpi / 96.0;
        var wa = ScreenUtil.WorkAreaForPoint(_anchor.X, _anchor.Y);
        int cx = (int)Math.Round(Width * s);
        int cy = (int)Math.Round(Height * s);
        int pad = (int)Math.Round(8 * s);
        int x = _anchor.X - (int)Math.Round(40 * s);
        int y = _anchor.Y + (int)Math.Round(12 * s);
        x = Math.Max(wa.Left + pad, Math.Min(x, wa.Right - cx - pad));
        y = Math.Max(wa.Top + pad, Math.Min(y, wa.Bottom - cy - pad));
        SetWindowPos(h, HWND_TOP, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_NCHITTEST) { handled = true; return (IntPtr)HitTest(hwnd, lParam); }
        return IntPtr.Zero;
    }

    private int HitTest(IntPtr hwnd, IntPtr lParam)
    {
        if (!GetWindowRect(hwnd, out var r)) return HTCLIENT;
        int mx = (short)(lParam.ToInt32() & 0xFFFF);
        int my = (short)((lParam.ToInt32() >> 16) & 0xFFFF);
        uint dpi = ScreenUtil.DpiForPoint(mx, my);
        int b = (int)Math.Round(6 * dpi / 96.0);
        bool left = mx >= r.Left && mx < r.Left + b;
        bool right = mx <= r.Right - 1 && mx > r.Right - 1 - b;
        bool top = my >= r.Top && my < r.Top + b;
        bool bottom = my <= r.Bottom - 1 && my > r.Bottom - 1 - b;
        if (top && left) return HTTOPLEFT;
        if (top && right) return HTTOPRIGHT;
        if (bottom && left) return HTBOTTOMLEFT;
        if (bottom && right) return HTBOTTOMRIGHT;
        if (left) return HTLEFT;
        if (right) return HTRIGHT;
        if (top) return HTTOP;
        if (bottom) return HTBOTTOM;
        return HTCLIENT;
    }

    private void SaveSize()
    {
        if (ActualWidth < MinWidth || ActualHeight < MinHeight) return;
        Settings.Current.AgentWidth = ActualWidth;
        Settings.Current.AgentHeight = ActualHeight;
        Settings.Current.Save();
    }

    // ---------- drag anywhere ----------

    private void Root_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left) return;
        if (IsInteractive(e.OriginalSource as DependencyObject)) return;
        DragMove();
    }

    private bool IsInteractive(DependencyObject? src)
    {
        for (var d = src; d != null && d != Root; d = VisualTreeHelper.GetParent(d))
        {
            if (d is TextBoxBase or ScrollBar or Thumb) return true;
            if (ReferenceEquals(d, Transcript) || ReferenceEquals(d, InputBar) ||
                ReferenceEquals(d, CloseBtn) || ReferenceEquals(d, MicBtn) ||
                ReferenceEquals(d, SendBtn) || ReferenceEquals(d, ContextPill))
                return true;
        }
        return false;
    }

    // ---------- lifecycle animation ----------

    private void PlayEntrance()
    {
        var (s, t) = Anim.Transforms(Root);
        s.ScaleX = s.ScaleY = 0.97;
        t.Y = 6;
        BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, Anim.Ms(160)) { EasingFunction = Anim.EaseOut });
        s.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.97, 1, Anim.Ms(160)) { EasingFunction = Anim.EaseOut });
        s.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.97, 1, Anim.Ms(160)) { EasingFunction = Anim.EaseOut });
        t.BeginAnimation(TranslateTransform.YProperty, new DoubleAnimation(6, 0, Anim.Ms(160)) { EasingFunction = Anim.EaseOut });
    }

    private void Close_Click(object sender, MouseButtonEventArgs e) { e.Handled = true; SafeClose(); }

    // Idempotent animated close; also kills any in-flight run (Closed → Cleanup does
    // the same, so an already-torn-down window is safe).
    public void SafeClose()
    {
        if (_closeRequested) return;
        _closeRequested = true;
        _runCts?.Cancel();
        var (s, _) = Anim.Transforms(Root);
        var fade = new DoubleAnimation(0, Anim.Ms(120)) { EasingFunction = Anim.EaseOut };
        fade.Completed += (_, _) => { try { Close(); } catch { } };
        s.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.98, Anim.Ms(120)) { EasingFunction = Anim.EaseOut });
        s.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.98, Anim.Ms(120)) { EasingFunction = Anim.EaseOut });
        BeginAnimation(OpacityProperty, fade);
    }

    private void Cleanup()
    {
        try { _runCts?.Cancel(); } catch { }
        try { if (_recording) _speech?.RecognizeAsyncCancel(); } catch { }
        try { _speech?.Dispose(); } catch { }
        _speech = null;
    }

    // ---------- micro-interactions (shared with the popup's feel) ----------

    private static void WireButton(Border b, double baseOp)
    {
        b.Opacity = baseOp;
        b.MouseEnter += (_, _) => Anim.OpacityTo(b, 1.0, 100);
        b.MouseLeave += (_, _) => { Anim.OpacityTo(b, baseOp, 120); Anim.ScaleTo(b, 1.0, 90); };
        b.PreviewMouseLeftButtonDown += (_, _) => Anim.ScaleTo(b, 0.95, 80);
        b.PreviewMouseLeftButtonUp += (_, _) => Anim.ScaleTo(b, 1.0, 90);
    }
}
