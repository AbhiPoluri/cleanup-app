using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
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
    private bool _auto;
    private bool _diffOn;
    // batch timing (all touched on the UI thread only)
    private System.Diagnostics.Stopwatch? _batchSw;
    private int _batchLanded;
    private bool _batchFirstLogged;
    private DiffWindow? _popOut;
    private readonly double _fontSize = Math.Clamp(Settings.Current.FontSize, 11, 18);

    // auto mode = capture new selections made anywhere and feed them in (without
    // stealing focus). Never persisted — always starts off.
    public bool IsAutoMode => _auto;

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
        // content text size (item: font size adjuster) — chrome/labels stay fixed
        DiffBox.FontSize = _fontSize;
        RefineBox.FontSize = _fontSize;
        RefinePlaceholder.FontSize = _fontSize;
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

        // restore persisted diff-view state (no animation on first layout)
        _diffOn = Settings.Current.DiffView;
        RestyleDiffToggle();
        DiffPanel.Visibility = _diffOn ? Visibility.Visible : Visibility.Collapsed;

        // Click-away no longer closes by default. Only when the user opts into
        // "Auto-close when clicking away" in Settings — and never while auto mode
        // is on, nor while the pop-out diff window is open (clicking it would
        // otherwise dismiss the popup out from under it).
        Deactivated += (_, _) =>
        {
            if (!Program.TestMode && Settings.Current.AutoClose && !_auto && _popOut == null)
                SafeClose();
        };
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
        DiffPanel.Background = _t.Surface2;
        DiffPanel.BorderBrush = _t.Line;
        DiffBox.Foreground = _t.Text;
        DiffBox.Document.PagePadding = new Thickness(0);
        // mono selection highlight — no system blue
        DiffBox.SelectionBrush = _t.Muted;
        DiffBox.SelectionOpacity = 0.35;
        // close button (quiet outline, like the other title-bar controls)
        CloseBtn.Background = _t.Surface2;
        CloseBtn.BorderBrush = _t.Line;
        CloseLabel.Foreground = _t.Muted;
        // pop-out button (quiet outline, mirrors the diff toggle)
        PopOutBtn.Background = _t.Surface2;
        PopOutBtn.BorderBrush = _t.Line;
        PopOutLabel.Foreground = _t.Muted;
        RestyleAuto();
        RestyleDiffToggle();
    }

    private void RestyleAuto()
    {
        // Mono theme: auto ON = filled/bordered/bold; OFF = quiet outline.
        AutoBtn.Background = _auto ? _t.Surface3 : _t.Surface2;
        AutoBtn.BorderBrush = _auto ? _t.LineStrong : _t.Line;
        AutoLabel.Foreground = _auto ? _t.Text : _t.Muted;
        AutoLabel.FontWeight = _auto ? FontWeights.SemiBold : FontWeights.Normal;
        AutoLabel.Text = _auto ? "⟳ auto ●" : "⟳ auto";
    }

    // ---------- diff view ----------

    private void Diff_Click(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        SetDiff(!_diffOn);
    }

    private void SetDiff(bool on)
    {
        if (on == _diffOn && DiffPanel.Visibility == (on ? Visibility.Visible : Visibility.Collapsed)) return;
        _diffOn = on;
        Settings.Current.DiffView = on;
        Settings.Current.Save();
        RestyleDiffToggle();
        Anim.ScalePop(DiffBtn, 1.12, 160);

        if (on)
        {
            DiffPanel.Visibility = Visibility.Visible;
            RenderDiff();
            Anim.FadeSlideIn(DiffPanel, 6, 140);   // quick fade+slide over the expanding row
        }
        else
        {
            // fade out, then collapse the row (fade covers the instant layout snap)
            var fade = new DoubleAnimation(0, Anim.Ms(120)) { EasingFunction = Anim.EaseOut };
            fade.Completed += (_, _) => { if (!_diffOn) DiffPanel.Visibility = Visibility.Collapsed; };
            DiffPanel.BeginAnimation(UIElement.OpacityProperty, fade);
        }
        Log.Write($"diff view {(on ? "ON" : "OFF")}");
    }

    private void RestyleDiffToggle()
    {
        // Mono theme: on = filled/bordered/bold; off = quiet outline (mirrors pin).
        DiffBtn.Background = _diffOn ? _t.Surface3 : _t.Surface2;
        DiffBtn.BorderBrush = _diffOn ? _t.LineStrong : _t.Line;
        DiffLabel.Foreground = _diffOn ? _t.Text : _t.Muted;
        DiffLabel.FontWeight = _diffOn ? FontWeights.SemiBold : FontWeights.Normal;
    }

    // Rebuild the inline diff of _original → selected variant. No-op unless the
    // panel is on. Renders removed text struck+dim, added text bold on a raised
    // surface, unchanged text plain — all zero-hue (Mono-legal diff semantics).
    private void RenderDiff()
    {
        if (!_diffOn || DiffBox == null) return;
        var doc = DiffBox.Document;
        doc.Blocks.Clear();
        var para = new Paragraph { Margin = new Thickness(0), LineHeight = 20 };

        string? current = _selected < _results.Length ? _results[_selected] : null;
        if (current == null)
        {
            para.Inlines.Add(DimRun("waiting for variant…"));
        }
        else
        {
            var segs = Diff.Compute(_original, current);
            bool changed = segs.Exists(s => s.Kind != DiffKind.Same);
            if (!changed)
                para.Inlines.Add(DimRun("no changes"));
            else
                foreach (var seg in segs)
                    para.Inlines.Add(MakeDiffRun(seg));
        }
        doc.Blocks.Add(para);
    }

    // Selected variant's text, or null while it's still loading.
    private string? CurrentResult() => _selected < _results.Length ? _results[_selected] : null;

    // Push the current original→variant state to BOTH diff surfaces: the inline
    // panel (guarded by _diffOn) and the pop-out window (if open). Called from
    // every content change — selection, variant-done, refine-done, regenerate,
    // and auto-mode capture — so the two stay in lockstep.
    private void RefreshDiffs()
    {
        RenderDiff();
        _popOut?.Update(_original, CurrentResult(), _fontSize);
    }

    // ---------- pop-out diff window ----------

    private void PopOut_Click(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        Anim.ScalePop(PopOutBtn, 1.12, 160);
        if (_popOut != null) { _popOut.Activate(); return; }   // single instance → focus it
        _popOut = new DiffWindow(_original, CurrentResult(), _fontSize);
        _popOut.Closed += (_, _) => _popOut = null;
        _popOut.Show();
        _popOut.Activate();
        Log.Write("diff popped out");
    }

    private Run DimRun(string text) => new(text) { Foreground = _t.Faint };

    private Run MakeDiffRun(DiffSegment seg)
    {
        var run = new Run(seg.Text);
        switch (seg.Kind)
        {
            case DiffKind.Removed:
                run.Foreground = _t.DiffDelText;
                run.Background = _t.DiffDelBg;
                run.TextDecorations = TextDecorations.Strikethrough;
                break;
            case DiffKind.Added:
                run.Foreground = _t.DiffAddText;
                run.Background = _t.DiffAddBg;
                run.FontWeight = FontWeights.SemiBold;
                break;
            default:   // Same
                run.Foreground = _t.Text;
                break;
        }
        return run;
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
                ReferenceEquals(d, AutoBtn) || ReferenceEquals(d, DiffPanel) ||
                ReferenceEquals(d, DiffBtn) || ReferenceEquals(d, PopOutBtn) ||
                ReferenceEquals(d, CloseBtn))
                return true;
        }
        return false;
    }

    // ---------- auto mode ----------

    private void Auto_Click(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        SetAuto(!_auto);
    }

    private void SetAuto(bool on)
    {
        if (on == _auto) return;
        _auto = on;
        RestyleAuto();
        Anim.ScalePop(AutoBtn, 1.12, 160);
        Log.Write($"auto mode {(on ? "ON" : "OFF")}");
    }

    private void Close_Click(object sender, MouseButtonEventArgs e)
    {
        e.Handled = true;
        SafeClose();
    }

    // Called by the selection watcher when the user selects fresh text in another
    // app while auto mode is on. Must NOT steal focus (user is mid-selection).
    public void UpdateSource(string newText, IntPtr hwnd)
    {
        newText = newText.Trim();
        if (newText.Length == 0 || newText == _original.Trim()) return;
        Log.Write($"auto: new selection ({newText.Length} chars) — regenerating");
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

        // batch wall-clock: start now, one line per landed variant advances it,
        // completion line when the last variant lands.
        _batchSw = System.Diagnostics.Stopwatch.StartNew();
        _batchLanded = 0;
        _batchFirstLogged = false;
        Log.Write($"batch start count={_count} backend={Settings.Current.Backend} textlen={_original.Length}");

        for (int i = 0; i < _count; i++)
        {
            int idx = i;
            var card = new VariantCard(idx, _t, SelectCard, _fontSize);
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

        // fresh selection has no result yet → diff shows its "waiting" state
        RefreshDiffs();
    }

    private string? StyleLabel(int idx) =>
        _count > 1 ? Prompts.Styles[idx % Prompts.Styles.Length].Label : null;

    private async Task RunVariant(int idx, VariantCard card, CancellationToken ct)
    {
        try
        {
            // Live tokens into the card as they stream. Display-only: the returned
            // text below is the source of truth. Guarded so a partial from a
            // superseded batch (tone change / regenerate / auto recapture) can never
            // write into the new batch's card — mirrors OnVariantLanded's token guard.
            void OnPartial(string acc)
            {
                if (ct.IsCancellationRequested) return;
                _ = Dispatcher.BeginInvoke(() =>
                {
                    if (ct.IsCancellationRequested) return;
                    if (idx >= _cards.Count || !ReferenceEquals(_cards[idx], card)) return;
                    card.ShowPartial(acc);
                });
            }
            var text = await Llm.Complete(Prompts.System, Prompts.Variant(_original, _tone, idx), ct, idx, OnPartial);
            if (ct.IsCancellationRequested) return;
            _results[idx] = text;
            // InvokeAsync (not blocking Invoke) so this LLM-task thread isn't parked
            // waiting on the UI thread while other variants are still streaming in.
            _ = Dispatcher.InvokeAsync(() =>
            {
                card.SetDone(text, StyleLabel(idx));
                if (idx == _selected) RefreshDiffs();
                OnVariantLanded(ct);
            });
        }
        catch (Exception ex)
        {
            if (ct.IsCancellationRequested) return;
            _errors[idx] = ex.Message;
            _ = Dispatcher.InvokeAsync(() => { card.SetError(ex.Message); OnVariantLanded(ct); });
        }
    }

    // UI-thread only: advances the batch counters. Logs the perceived "first
    // variant done" latency once, and the batch wall-clock when the last lands.
    // Guarded by the batch's own token so a superseded batch (tone change,
    // regenerate, auto-mode recapture) can't log against the new one.
    private void OnVariantLanded(CancellationToken ct)
    {
        if (ct.IsCancellationRequested || _batchSw == null) return;
        _batchLanded++;
        if (!_batchFirstLogged)
        {
            _batchFirstLogged = true;
            Log.Write($"popup: first-variant-done {_batchSw.ElapsedMilliseconds}ms");
        }
        if (_batchLanded >= _count)
        {
            Log.Write($"batch done count={_count} wall={_batchSw.ElapsedMilliseconds}ms");
            _batchSw.Stop();
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
                void OnPartial(string acc)
                {
                    if (cts.Token.IsCancellationRequested) return;
                    _ = Dispatcher.BeginInvoke(() =>
                    {
                        if (cts.Token.IsCancellationRequested) return;
                        if (idx >= _cards.Count || !ReferenceEquals(_cards[idx], card)) return;
                        card.ShowPartial(acc);
                    });
                }
                text = await Llm.Complete(Prompts.System, Prompts.Refine(current, instruction), cts.Token, idx, OnPartial);
            }
            catch (Exception ex) { error = ex.Message; }
            if (cts.Token.IsCancellationRequested) return;
            Dispatcher.Invoke(() =>
            {
                if (text != null) { _results[idx] = text; card.SetDone(text, StyleLabel(idx)); if (idx == _selected) RefreshDiffs(); }
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
        RefreshDiffs();
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

        // tear down the pop-out diff window with the popup (its own Closed handler
        // clears _popOut; Close is a no-op if it's already gone).
        try { _popOut?.Close(); } catch { }
        _popOut = null;

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
        WireButton(AutoBtn, 1.0);
        WireButton(CloseBtn, 0.85);
        WireButton(ModelChip, 0.85);
        WireButton(DiffBtn, 1.0);
        WireButton(PopOutBtn, 1.0);
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
        if (e.Key == Key.Escape) { SetAuto(false); SafeClose(); e.Handled = true; return; }
        if ((Keyboard.Modifiers & ModifierKeys.Control) == 0) return;
        switch (e.Key)
        {
            case Key.Enter: DoReplace(); e.Handled = true; break;
            case Key.R: GenerateAll(); e.Handled = true; break;
            case Key.D: SetDiff(!_diffOn); e.Handled = true; break;
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
