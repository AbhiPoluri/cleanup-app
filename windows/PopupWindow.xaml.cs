using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace Cleanup;

public partial class PopupWindow : Window
{
    private string _original;
    private IntPtr _targetHwnd;
    private readonly ScreenUtil.NativePoint _anchor;   // cursor at trigger time (device px)
    private readonly Theme _t = Theme.Detect();
    private static readonly string[] Tones = { "Clean", "Professional", "Casual", "Blunt" };

    private string _tone;
    private int _count;
    private int _selected;
    private string?[] _results = Array.Empty<string?>();   // null = loading
    private string?[] _errors = Array.Empty<string?>();
    private readonly List<CancellationTokenSource> _cts = new();
    private readonly List<Border> _chipBorders = new();
    private readonly List<VariantCard> _cards = new();
    private SolidColorBrush _refineBorderBrush = new();
    private TextBox? _customToneBox;
    private bool _refining;
    private bool _closeRequested;
    private bool _pinned;

    // pinned = don't dismiss on focus loss and follow new selections elsewhere.
    // Never persisted — always starts unpinned.
    public bool IsPinned => _pinned;

    public PopupWindow(string original, IntPtr targetHwnd, ScreenUtil.NativePoint anchor)
    {
        _original = original;
        _targetHwnd = targetHwnd;
        _anchor = anchor;
        _tone = Settings.Current.DefaultTone;
        _count = Math.Clamp(Settings.Current.DefaultCount, 1, 5);

        InitializeComponent();

        // restore last size (DIPs), clamped to the mins declared in XAML
        // (MinWidth/MinHeight only exist after InitializeComponent applies the XAML)
        Width = Math.Max(MinWidth, Settings.Current.PopupWidth);
        Height = Math.Max(MinHeight, Settings.Current.PopupHeight);

        ApplyTheme();
        BuildChips();
        VariantSlider.Value = _count;
        ModelLabel.Text = Settings.Current.ModelLabel + " ▾";
        ModelChip.MouseLeftButtonUp += (_, _) => AppController.OpenSettings();
        RefineBox.TextChanged += (_, _) =>
            RefinePlaceholder.Visibility = RefineBox.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        RefineBox.GotFocus += (_, _) =>
            _refineBorderBrush.BeginAnimation(Brush.OpacityProperty, new DoubleAnimation(1.0, Anim.Ms(150)) { EasingFunction = Anim.EaseOut });
        RefineBox.LostFocus += (_, _) =>
            _refineBorderBrush.BeginAnimation(Brush.OpacityProperty, new DoubleAnimation(0.6, Anim.Ms(150)) { EasingFunction = Anim.EaseOut });

        WireMicroInteractions();

        Deactivated += (_, _) => { if (!Program.TestMode && !_pinned) SafeClose(); };
        Closing += (_, _) => SaveSize();
        Closed += (_, _) => CancelAll();
        PreviewKeyDown += OnPreviewKeyDown;

        // entrance: fade + scale-from-0.97 + rise, started once the tree is realised.
        Opacity = 0;
        Loaded += (_, _) => PlayEntrance();

        GenerateAll();
    }

    // ---------- theming ----------

    private void ApplyTheme()
    {
        Root.Background = _t.Surface;
        Root.BorderBrush = _t.LineStrong;
        TitleLabel.Foreground = _t.Muted;
        ModelChip.BorderBrush = _t.Line;
        ModelLabel.Foreground = _t.Faint;
        VariantsLabel.Foreground = _t.Faint;
        CountLabel.Foreground = _t.Text;
        ModeHint.Foreground = _t.Faint;
        HintLabel.Foreground = _t.Faint;
        CopyBtn.BorderBrush = _t.LineStrong;
        CopyLabel.Foreground = _t.Muted;
        ReplaceBtn.Background = _t.Accent;
        ReplaceLabel.Foreground = _t.OnAccent;
        RefineBorder.Background = _t.Surface2;
        // private (unshared) brush so its Opacity can be animated on focus/blur
        // without touching every other element that uses LineStrong.
        _refineBorderBrush = new SolidColorBrush(((SolidColorBrush)_t.LineStrong).Color) { Opacity = 0.6 };
        RefineBorder.BorderBrush = _refineBorderBrush;
        RefineBox.Foreground = _t.Text;
        RefineBox.CaretBrush = _t.Text;
        RefinePlaceholder.Foreground = _t.Faint;
        RefineStatus.Foreground = _t.Muted;
        RestylePin();
    }

    private void RestylePin()
    {
        // Mono theme: pinned = filled/bordered/bold; unpinned = quiet outline.
        PinBtn.Background = _pinned ? _t.Surface3 : _t.Surface2;
        PinBtn.BorderBrush = _pinned ? _t.LineStrong : _t.Line;
        PinLabel.Foreground = _pinned ? _t.Text : _t.Muted;
        PinLabel.FontWeight = _pinned ? FontWeights.SemiBold : FontWeights.Normal;
        PinLabel.Text = _pinned ? "✦ pinned" : "✦ pin";
    }

    // ---------- positioning + window chrome (borderless, resizable) ----------

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

        // AllowsTransparency=true rules out WindowChrome resize, so we enable the
        // native sizing loop (WS_THICKFRAME — invisible on a borderless layered
        // window) and drive it with manual WM_NCHITTEST edge zones below.
        SetWindowLong(h, GWL_STYLE, GetWindowLong(h, GWL_STYLE) | WS_THICKFRAME);
        HwndSource.FromHwnd(h)?.AddHook(WndProc);

        PositionNearAnchor(h);
    }

    // Place the popup near the trigger-time cursor, on that cursor's monitor,
    // clamped to that monitor's work area, in device px (WPF Left/Top go stale
    // across monitors — SetWindowPos with device px is the reliable path).
    private void PositionNearAnchor(IntPtr h)
    {
        uint dpi = ScreenUtil.DpiForPoint(_anchor.X, _anchor.Y);
        double s = dpi / 96.0;
        var wa = ScreenUtil.WorkAreaForPoint(_anchor.X, _anchor.Y);

        int cx = (int)Math.Round(Width * s);
        int cy = (int)Math.Round(Height * s);
        int pad = (int)Math.Round(8 * s);

        // mirror the mac offset: a touch left of and below the cursor
        int x = _anchor.X - (int)Math.Round(40 * s);
        int y = _anchor.Y + (int)Math.Round(12 * s);
        x = Math.Max(wa.Left + pad, Math.Min(x, wa.Right - cx - pad));
        y = Math.Max(wa.Top + pad, Math.Min(y, wa.Bottom - cy - pad));

        SetWindowPos(h, HWND_TOP, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
        Log.Write($"popup positioned dev={x},{y} dpi={dpi} monitor.work=({wa.Left},{wa.Top},{wa.Right},{wa.Bottom})");
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_NCHITTEST)
        {
            handled = true;
            return (IntPtr)HitTest(hwnd, lParam);
        }
        return IntPtr.Zero;
    }

    private int HitTest(IntPtr hwnd, IntPtr lParam)
    {
        if (!GetWindowRect(hwnd, out var r)) return HTCLIENT;
        int mx = (short)(lParam.ToInt32() & 0xFFFF);
        int my = (short)((lParam.ToInt32() >> 16) & 0xFFFF);

        uint dpi = ScreenUtil.DpiForPoint(mx, my);
        int b = (int)Math.Round(6 * dpi / 96.0);   // ~6 DIP grab border

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
        Settings.Current.PopupWidth = ActualWidth;
        Settings.Current.PopupHeight = ActualHeight;
        Settings.Current.Save();
    }

    // ---------- movable: drag anywhere on the background ----------

    private void Root_MouseDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton != MouseButton.Left) return;
        if (IsInteractive(e.OriginalSource as DependencyObject)) return;
        DragMove();
    }

    // True if the click landed inside a control that owns the mouse (text
    // selection, buttons, slider, cards, scroll thumb) — those must not drag.
    private bool IsInteractive(DependencyObject? src)
    {
        for (var d = src; d != null && d != Root; d = VisualTreeHelper.GetParent(d))
        {
            if (d is TextBoxBase or Slider or Thumb or ScrollBar) return true;
            if (ReferenceEquals(d, CardsScroll) || ReferenceEquals(d, RefineBorder) ||
                ReferenceEquals(d, ChipsPanel) || ReferenceEquals(d, CopyBtn) ||
                ReferenceEquals(d, ReplaceBtn) || ReferenceEquals(d, ModelChip) ||
                ReferenceEquals(d, PinBtn))
                return true;
        }
        return false;
    }

    // ---------- pinned mode ----------

    private void Pin_Click(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        SetPinned(!_pinned);
    }

    private void SetPinned(bool on)
    {
        if (on == _pinned) return;
        _pinned = on;
        RestylePin();
        Anim.ScalePop(PinBtn, 1.12, 160);
        Log.Write($"pinned mode {(on ? "ON" : "OFF")}");
    }

    // Called by the selection watcher when the user selects fresh text in another
    // app while pinned. Must NOT steal focus (user is mid-selection elsewhere).
    public void UpdateSource(string newText, IntPtr hwnd)
    {
        newText = newText.Trim();
        if (newText.Length == 0 || newText == _original.Trim()) return;
        Log.Write($"pinned: new selection ({newText.Length} chars) — regenerating");
        _original = newText;
        _targetHwnd = hwnd;
        // visibly acknowledge the caught selection: dip the card area, then the
        // fresh cards stagger back in over the recovering dip.
        Anim.Dip(CardsScroll, 0.35, 320);
        GenerateAll();
    }

    // ---------- chips ----------

    private void BuildChips()
    {
        ChipsPanel.Children.Clear();
        _chipBorders.Clear();
        foreach (var tone in Tones)
        {
            var label = new TextBlock { Text = tone, FontSize = 12 };
            var chip = new Border
            {
                Child = label,
                // WPF doesn't clamp oversized radii like CSS — anything over half the
                // chip height renders as an oval, so this must stay ≈ height/2
                CornerRadius = new CornerRadius(13),
                BorderThickness = new Thickness(1),
                Padding = new Thickness(12, 4, 12, 4),
                Margin = new Thickness(0, 0, 6, 0),
                Cursor = Cursors.Hand,
                Tag = tone,
            };
            chip.MouseLeftButtonUp += (_, _) => { SetTone(tone); };
            chip.MouseEnter += (_, _) => { if ((string)chip.Tag != _tone) Anim.OpacityTo(chip, 1.0, 100); };
            chip.MouseLeave += (_, _) => { if ((string)chip.Tag != _tone) Anim.OpacityTo(chip, 0.9, 120); Anim.ScaleTo(chip, 1.0, 90); };
            chip.PreviewMouseLeftButtonDown += (_, _) => Anim.ScaleTo(chip, 0.95, 80);
            chip.PreviewMouseLeftButtonUp += (_, _) => Anim.ScaleTo(chip, 1.0, 90);
            _chipBorders.Add(chip);
            ChipsPanel.Children.Add(chip);
        }

        _customToneBox = new TextBox
        {
            FontSize = 12,
            Width = 110,
            BorderThickness = new Thickness(0),
            Background = System.Windows.Media.Brushes.Transparent,
            Foreground = _t.Text,
            CaretBrush = _t.Text,
        };
        _customToneBox.KeyDown += (_, e) =>
        {
            if (e.Key == Key.Enter && !string.IsNullOrWhiteSpace(_customToneBox.Text))
                SetTone(_customToneBox.Text.Trim());
        };
        var custom = new Border
        {
            Child = _customToneBox,
            CornerRadius = new CornerRadius(13),
            BorderThickness = new Thickness(1),
            BorderBrush = _t.LineStrong,
            Padding = new Thickness(10, 3, 10, 3),
        };
        ChipsPanel.Children.Add(custom);
        RestyleChips();
    }

    private void RestyleChips()
    {
        foreach (var chip in _chipBorders)
        {
            bool on = (string)chip.Tag == _tone;
            chip.Background = on ? _t.Surface3 : _t.Surface2;
            chip.BorderBrush = on ? _t.LineStrong : _t.Line;
            var label = (TextBlock)chip.Child;
            label.Foreground = on ? _t.Text : _t.Muted;
            label.FontWeight = on ? FontWeights.SemiBold : FontWeights.Normal;
            Anim.OpacityTo(chip, on ? 1.0 : 0.9, 100);
        }
    }

    private void SetTone(string tone)
    {
        if (tone == _tone) return;
        _tone = tone;
        RestyleChips();
        var picked = _chipBorders.FirstOrDefault(c => (string)c.Tag == tone);
        if (picked != null) Anim.ScalePop(picked);
        GenerateAll();
    }

    // ---------- slider ----------

    private DispatcherTimer? _sliderDebounce;

    private void Slider_ValueChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        int n = (int)Math.Round(e.NewValue);
        if (CountLabel != null)
        {
            if (CountLabel.Text != n.ToString()) Anim.ScalePop(CountLabel, 1.18, 150);
            CountLabel.Text = n.ToString();
        }
        if (ModeHint != null) ModeHint.Text = n == 1 ? "single rewrite" : "pick a card";
        if (n == _count) return;
        // debounce so dragging across ticks doesn't fire a request per tick
        _sliderDebounce?.Stop();
        _sliderDebounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(350) };
        _sliderDebounce.Tick += (_, _) =>
        {
            _sliderDebounce!.Stop();
            _count = n;
            Settings.Current.DefaultCount = n;
            Settings.Current.Save();
            GenerateAll();
        };
        _sliderDebounce.Start();
    }

    // ---------- generation ----------

    private void CancelAll()
    {
        foreach (var c in _cts) c.Cancel();
        _cts.Clear();
        _refining = false;
        if (RefineBox != null) RefineBox.IsEnabled = true;
        if (RefineBorder != null)
        {
            RefineBorder.BeginAnimation(UIElement.OpacityProperty, null);
            RefineBorder.Opacity = 1;
        }
        if (RefineStatus != null) RefineStatus.Text = "↵";
    }

    private void GenerateAll()
    {
        CancelAll();
        foreach (var c in _cards) c.StopDots();
        _cards.Clear();
        CardsPanel.Children.Clear();
        _results = new string?[_count];
        _errors = new string?[_count];
        _selected = 0;

        for (int i = 0; i < _count; i++)
        {
            int idx = i;
            var card = new VariantCard(idx, _t, SelectCard);
            card.EnterFresh();
            card.SetSelected(idx == 0, animate: false);
            _cards.Add(card);
            CardsPanel.Children.Add(card.Root);
            // stagger the cards in as a skeleton: fade + rise ~8px, ~50ms apart.
            Anim.FadeSlideIn(card.Root, 8, 180, beginMs: idx * 50);
        }

        for (int i = 0; i < _count; i++)
        {
            int idx = i;
            var cts = new CancellationTokenSource();
            _cts.Add(cts);
            _ = RunVariant(idx, _cards[idx], cts.Token);
        }
    }

    private string? StyleLabel(int idx) =>
        _count > 1 ? Prompts.Styles[idx % Prompts.Styles.Length].Label : null;

    private async Task RunVariant(int idx, VariantCard card, CancellationToken ct)
    {
        try
        {
            var text = await Llm.Complete(Prompts.System, Prompts.Variant(_original, _tone, idx), ct);
            if (ct.IsCancellationRequested) return;
            _results[idx] = text;
            Dispatcher.Invoke(() => card.SetDone(text, StyleLabel(idx)));
        }
        catch (Exception ex)
        {
            if (ct.IsCancellationRequested) return;
            _errors[idx] = ex.Message;
            Dispatcher.Invoke(() => card.SetError(ex.Message));
        }
    }

    private void RefineBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Enter) return;
        var instruction = RefineBox.Text.Trim();
        var current = _selected < _results.Length ? _results[_selected] : null;
        if (instruction.Length == 0 || current == null || _refining || _selected >= _cards.Count) return;

        var card = _cards[_selected];
        Anim.ScalePop(RefineStatus, 1.3, 150);   // Enter-to-send pressed feedback
        RefineBox.Text = "";
        _refining = true;
        SetRefineBusy(true);
        card.ShowRefineLoading();
        int idx = _selected;
        var cts = new CancellationTokenSource();
        _cts.Add(cts);
        _ = Task.Run(async () =>
        {
            string? text = null, error = null;
            try
            {
                text = await Llm.Complete(Prompts.System, Prompts.Refine(current, instruction), cts.Token);
            }
            catch (Exception ex) { error = ex.Message; }
            if (cts.Token.IsCancellationRequested) return;
            Dispatcher.Invoke(() =>
            {
                if (text != null) { _results[idx] = text; card.SetDone(text, StyleLabel(idx)); }
                else if (error != null) { _errors[idx] = error; card.SetError(error); }
                _refining = false;
                SetRefineBusy(false);
                RefineBox.Focus();
            });
        });
    }

    // Dim + disable the refine input while a tuning prompt is in flight; the
    // selected card carries the visible loading pulse.
    private void SetRefineBusy(bool busy)
    {
        RefineBox.IsEnabled = !busy;
        Anim.OpacityTo(RefineBorder, busy ? 0.55 : 1.0, 140);
    }

    // ---------- cards ----------

    private void SelectCard(int i)
    {
        if (i < 0 || i >= _cards.Count) return;
        _selected = i;
        for (int k = 0; k < _cards.Count; k++)
            _cards[k].SetSelected(k == i, animate: true);
    }

    // ---------- actions ----------

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

    // Close() during close (Esc → Close → Deactivated → Close again) throws in WPF.
    // We now also animate out first; _closeRequested makes the whole thing
    // idempotent, so a second close request mid-animation is a no-op (never a
    // second Close() — that was the historical crash).
    public void SafeClose()
    {
        if (_closeRequested) return;
        _closeRequested = true;

        var (s, _) = Anim.Transforms(Root);
        var fade = new DoubleAnimation(0, Anim.Ms(120)) { EasingFunction = Anim.EaseOut };
        fade.Completed += (_, _) => { try { Close(); } catch { } };
        s.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.98, Anim.Ms(120)) { EasingFunction = Anim.EaseOut });
        s.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.98, Anim.Ms(120)) { EasingFunction = Anim.EaseOut });
        BeginAnimation(OpacityProperty, fade);
    }

    // ---------- micro-interactions ----------

    private void WireMicroInteractions()
    {
        WireButton(CopyBtn, 0.9);
        WireButton(ReplaceBtn, 1.0);
        WireButton(PinBtn, 1.0);
        WireButton(ModelChip, 0.85);
    }

    // Hover raises opacity; press gives a small scale dip. Additive to the
    // existing MouseLeftButtonUp click handlers (uses tunneling Preview events).
    private static void WireButton(Border b, double baseOp)
    {
        b.Opacity = baseOp;
        b.MouseEnter += (_, _) => Anim.OpacityTo(b, 1.0, 100);
        b.MouseLeave += (_, _) => { Anim.OpacityTo(b, baseOp, 120); Anim.ScaleTo(b, 1.0, 90); };
        b.PreviewMouseLeftButtonDown += (_, _) => Anim.ScaleTo(b, 0.95, 80);
        b.PreviewMouseLeftButtonUp += (_, _) => Anim.ScaleTo(b, 1.0, 90);
    }

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape) { SetPinned(false); SafeClose(); e.Handled = true; return; }
        if ((Keyboard.Modifiers & ModifierKeys.Control) == 0) return;
        switch (e.Key)
        {
            case Key.Enter: DoReplace(); e.Handled = true; break;
            case Key.R: GenerateAll(); e.Handled = true; break;
            case >= Key.D1 and <= Key.D5:
                SelectCard(e.Key - Key.D1); e.Handled = true; break;
        }
    }

    private void Copy_Click(object sender, MouseButtonEventArgs e) => DoCopy();
    private void Replace_Click(object sender, MouseButtonEventArgs e) => DoReplace();

    private void DoCopy()
    {
        var text = _selected < _results.Length ? _results[_selected] : null;
        if (text == null) { System.Media.SystemSounds.Beep.Play(); return; }
        try { Clipboard.SetText(text); } catch { }
        SafeClose();
    }

    private async void DoReplace()
    {
        var text = _selected < _results.Length ? _results[_selected] : null;
        if (text == null) { System.Media.SystemSounds.Beep.Play(); return; }
        var hwnd = _targetHwnd;
        SafeClose();
        await Capture.PasteInto(hwnd, text);
    }
}
