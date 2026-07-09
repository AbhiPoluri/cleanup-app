using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;

namespace Cleanup;

// Pop-out side-by-side diff viewer. Left pane = the original text with deletions
// marked; right pane = the selected variant with insertions marked. Both panes
// share the GitHub-style red/green diff palette (the one sanctioned exception to
// the Mono zero-hue rule); all chrome stays strictly mono.
//
// Owned by the PopupWindow: one instance at a time, re-clicking the pop-out
// button focuses it, and PopupWindow.SafeClose closes it. It live-syncs through
// Update(), which the popup calls on every content change (selection, refine,
// regenerate, auto-mode capture).
public sealed class DiffWindow : Window
{
    private readonly Theme _t = Theme.Detect();
    private readonly Border _root;
    private readonly RichTextBox _left;
    private readonly RichTextBox _right;
    private double _fontSize;

    // remembered across opens within the session
    private static double _lastW = 760, _lastH = 440;
    private static double _lastLeft = double.NaN, _lastTop = double.NaN;

    public DiffWindow(string original, string? variant, double fontSize)
    {
        _fontSize = fontSize;
        Title = "Diff — Cleanup";
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.CanResize;
        ShowInTaskbar = true;
        Topmost = true;
        MinWidth = 460;
        MinHeight = 260;
        Width = _lastW;
        Height = _lastH;
        if (double.IsNaN(_lastLeft)) WindowStartupLocation = WindowStartupLocation.CenterScreen;
        else { WindowStartupLocation = WindowStartupLocation.Manual; Left = _lastLeft; Top = _lastTop; }

        _left = MakePane();
        _right = MakePane();

        var body = new Grid();
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var leftPanel = MakePanel("ORIGINAL", _left);
        var divider = new Border { Width = 1, Background = _t.Line, Margin = new Thickness(0, 8, 0, 8) };
        var rightPanel = MakePanel("REWRITE", _right);
        Grid.SetColumn(leftPanel, 0);
        Grid.SetColumn(divider, 1);
        Grid.SetColumn(rightPanel, 2);
        body.Children.Add(leftPanel);
        body.Children.Add(divider);
        body.Children.Add(rightPanel);

        var dock = new DockPanel();
        var titleBar = MakeTitleBar();
        DockPanel.SetDock(titleBar, Dock.Top);
        dock.Children.Add(titleBar);
        dock.Children.Add(body);

        _root = new Border
        {
            Child = dock,
            Background = _t.Surface,
            BorderBrush = _t.LineStrong,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
        };
        Content = _root;

        Opacity = 0;
        Loaded += (_, _) => Anim.OpacityTo(this, 1.0, 140);
        Closing += (_, _) =>
        {
            _lastW = ActualWidth; _lastH = ActualHeight;
            _lastLeft = Left; _lastTop = Top;
        };

        Update(original, variant, fontSize);
    }

    private RichTextBox MakePane()
    {
        var box = new RichTextBox
        {
            FontSize = _fontSize,
            IsReadOnly = true,
            IsDocumentEnabled = true,
            BorderThickness = new Thickness(0),
            Background = Brushes.Transparent,
            Foreground = _t.Text,
            Padding = new Thickness(0),
            IsTabStop = false,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            SelectionBrush = _t.Muted,
            SelectionOpacity = 0.35,
        };
        box.Document.PagePadding = new Thickness(0);
        return box;
    }

    private Border MakePanel(string header, RichTextBox box)
    {
        var label = new TextBlock
        {
            Text = header,
            FontSize = 10,
            FontFamily = new FontFamily("Consolas"),
            Foreground = _t.Faint,
            Margin = new Thickness(0, 0, 0, 8),
        };
        var stack = new DockPanel { Margin = new Thickness(16, 6, 16, 16) };
        DockPanel.SetDock(label, Dock.Top);
        stack.Children.Add(label);
        stack.Children.Add(box);
        return new Border { Child = stack };
    }

    private FrameworkElement MakeTitleBar()
    {
        var grid = new Grid { Margin = new Thickness(16, 11, 12, 6) };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var title = new TextBlock
        {
            Text = "Diff",
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = _t.Muted,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Grid.SetColumn(title, 0);

        var closeLabel = new TextBlock { Text = "✕", FontSize = 12, Foreground = _t.Muted };
        var closeBtn = new Border
        {
            Child = closeLabel,
            Background = _t.Surface2,
            BorderBrush = _t.Line,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(5),
            Padding = new Thickness(7, 2, 7, 2),
            Cursor = Cursors.Hand,
        };
        closeBtn.MouseLeftButtonUp += (_, e) => { e.Handled = true; Close(); };
        closeBtn.MouseEnter += (_, _) => Anim.OpacityTo(closeBtn, 1.0, 100);
        closeBtn.MouseLeave += (_, _) => Anim.OpacityTo(closeBtn, 0.85, 120);
        closeBtn.Opacity = 0.85;
        Grid.SetColumn(closeBtn, 1);

        grid.Children.Add(title);
        grid.Children.Add(closeBtn);

        // drag-to-move: only when the press lands on the bar itself, not the ✕
        grid.MouseLeftButtonDown += (_, e) =>
        {
            if (e.ChangedButton != MouseButton.Left) return;
            if (IsInside(e.OriginalSource as DependencyObject, closeBtn)) return;
            try { DragMove(); } catch { }
        };
        return grid;
    }

    private static bool IsInside(DependencyObject? src, DependencyObject target)
    {
        for (var d = src; d != null; d = VisualTreeHelper.GetParent(d))
            if (ReferenceEquals(d, target)) return true;
        return false;
    }

    // ---- live sync ----

    public void Update(string original, string? variant, double fontSize)
    {
        _fontSize = fontSize;
        _left.FontSize = _right.FontSize = fontSize;

        if (variant == null)
        {
            RenderPlain(_left, original);
            RenderWaiting(_right);
            return;
        }

        var segs = Diff.Compute(original, variant);
        RenderSide(_left, segs, isLeft: true);
        RenderSide(_right, segs, isLeft: false);
    }

    // Left pane rebuilds the original (Same + Removed); right pane rebuilds the
    // variant (Same + Added). Deletions are struck + red-tinted on the left,
    // insertions are bold + green-tinted on the right.
    private void RenderSide(RichTextBox box, List<DiffSegment> segs, bool isLeft)
    {
        var doc = box.Document;
        doc.Blocks.Clear();
        var para = new Paragraph { Margin = new Thickness(0), LineHeight = _fontSize + 7 };
        foreach (var seg in segs)
        {
            switch (seg.Kind)
            {
                case DiffKind.Same:
                    para.Inlines.Add(new Run(seg.Text) { Foreground = _t.Text });
                    break;
                case DiffKind.Removed when isLeft:
                    para.Inlines.Add(new Run(seg.Text)
                    {
                        Foreground = _t.DiffDelText,
                        Background = _t.DiffDelBg,
                        TextDecorations = TextDecorations.Strikethrough,
                    });
                    break;
                case DiffKind.Added when !isLeft:
                    para.Inlines.Add(new Run(seg.Text)
                    {
                        Foreground = _t.DiffAddText,
                        Background = _t.DiffAddBg,
                        FontWeight = FontWeights.SemiBold,
                    });
                    break;
                // Removed on the right / Added on the left: not part of that side.
            }
        }
        doc.Blocks.Add(para);
    }

    private void RenderPlain(RichTextBox box, string text)
    {
        var doc = box.Document;
        doc.Blocks.Clear();
        var para = new Paragraph { Margin = new Thickness(0), LineHeight = _fontSize + 7 };
        para.Inlines.Add(new Run(text) { Foreground = _t.Text });
        doc.Blocks.Add(para);
    }

    private void RenderWaiting(RichTextBox box)
    {
        var doc = box.Document;
        doc.Blocks.Clear();
        var para = new Paragraph { Margin = new Thickness(0) };
        para.Inlines.Add(new Run("waiting for variant…") { Foreground = _t.Faint });
        doc.Blocks.Add(para);
    }

    // ---- borderless resize (mirrors PopupWindow: WS_THICKFRAME + manual hit-test) ----

    private const int GWL_STYLE = -16;
    private const int WS_THICKFRAME = 0x00040000;
    private const int WM_NCHITTEST = 0x0084;
    private const int HTCLIENT = 1, HTLEFT = 10, HTRIGHT = 11, HTTOP = 12, HTTOPLEFT = 13,
                      HTTOPRIGHT = 14, HTBOTTOM = 15, HTBOTTOMLEFT = 16, HTBOTTOMRIGHT = 17;

    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] private static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out ScreenUtil.NativeRect r);

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var h = new WindowInteropHelper(this).Handle;
        SetWindowLong(h, GWL_STYLE, GetWindowLong(h, GWL_STYLE) | WS_THICKFRAME);
        HwndSource.FromHwnd(h)?.AddHook(WndProc);
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
}
