using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Shapes;   // Path, Rectangle (WPF)
using GdiBitmap = System.Drawing.Bitmap;
using GdiRect = System.Drawing.Rectangle;

namespace Cleanup;

// Fullscreen (whole-virtual-screen) borderless overlay for the interactive area snip.
// Shows the frozen desktop bitmap at full brightness with a 40% black wash over it; the
// drag rectangle cuts a clear "hole" in the wash (EvenOdd geometry) with an accent border.
//
// Coordinates: the SELECTION is tracked in device pixels via GetCursorPos (virtual-screen
// space) so the crop is always pixel-exact regardless of monitor DPI. The rubber-band is
// only a visual guide, drawn in DIPs using this window's own DPI scale — exact on the
// window's home monitor, close enough elsewhere; the captured image is unaffected either way.
public sealed class SnipOverlayWindow : Window
{
    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] private static extern int SetWindowLong(IntPtr h, int i, int v);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr h);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out POINT p);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr o);

    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X, Y; }

    private const int GWL_EXSTYLE = -20;
    private const int WS_EX_TOOLWINDOW = 0x00000080;
    private static readonly IntPtr HWND_TOPMOST = new(-1);
    private const uint SWP_SHOWWINDOW = 0x0040;

    private readonly int _vx, _vy, _vw, _vh;   // virtual-screen rect, device px
    private readonly Action<GdiRect?> _done;
    private readonly Path _dark;
    private readonly Rectangle _selBorder;
    private readonly Canvas _canvas;
    private readonly Theme _t = Theme.Detect();

    private double _scale = 1;                  // device px per DIP (this window's DPI)
    private bool _dragging, _finished;
    private POINT _start;                       // drag origin, device px (virtual coords)

    public SnipOverlayWindow(GdiBitmap frozen, int vx, int vy, int vw, int vh, Action<GdiRect?> done)
    {
        _vx = vx; _vy = vy; _vw = vw; _vh = vh; _done = done;

        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        AllowsTransparency = false;             // opaque frozen screenshot fills the window
        ShowInTaskbar = false;
        Topmost = true;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Background = Brushes.Black;
        Cursor = Cursors.Cross;

        var img = new Image { Source = ToBitmapSource(frozen), Stretch = Stretch.Fill };
        _dark = new Path { Fill = new SolidColorBrush(Color.FromArgb(102, 0, 0, 0)) };   // 40% black wash
        _selBorder = new Rectangle
        {
            Stroke = _t.Accent,
            StrokeThickness = 1.5,
            Visibility = Visibility.Collapsed,
            IsHitTestVisible = false,
        };
        _canvas = new Canvas { IsHitTestVisible = false };
        _canvas.Children.Add(_selBorder);

        var grid = new Grid();
        grid.Children.Add(img);
        grid.Children.Add(_dark);
        grid.Children.Add(_canvas);
        Content = grid;

        MouseLeftButtonDown += OnDown;
        MouseMove += OnMove;
        MouseLeftButtonUp += OnUp;
        KeyDown += (_, e) => { if (e.Key == Key.Escape) { e.Handled = true; Finish(null); } };
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var h = new WindowInteropHelper(this).Handle;
        SetWindowLong(h, GWL_EXSTYLE, GetWindowLong(h, GWL_EXSTYLE) | WS_EX_TOOLWINDOW);
        try { uint dpi = GetDpiForWindow(h); if (dpi > 0) _scale = dpi / 96.0; } catch { }
        SetWindowPos(h, HWND_TOPMOST, _vx, _vy, _vw, _vh, SWP_SHOWWINDOW);
        UpdateDark(null);
        Activate();
        Focus();
    }

    private void OnDown(object sender, MouseButtonEventArgs e)
    {
        GetCursorPos(out _start);
        _dragging = true;
        CaptureMouse();
    }

    private void OnMove(object sender, MouseEventArgs e)
    {
        if (!_dragging) return;
        DrawSelection(CurrentRect());
    }

    private void OnUp(object sender, MouseButtonEventArgs e)
    {
        if (!_dragging) return;
        _dragging = false;
        ReleaseMouseCapture();
        Finish(CurrentRect());
    }

    // Selection rect in FROZEN-BITMAP-LOCAL device px (0-based into the frozen bitmap).
    private GdiRect CurrentRect()
    {
        GetCursorPos(out var cur);
        int x = Math.Min(_start.X, cur.X) - _vx;
        int y = Math.Min(_start.Y, cur.Y) - _vy;
        int w = Math.Abs(cur.X - _start.X);
        int h = Math.Abs(cur.Y - _start.Y);
        return new GdiRect(x, y, w, h);
    }

    private void DrawSelection(GdiRect r)
    {
        double dx = r.X / _scale, dy = r.Y / _scale, dw = r.Width / _scale, dh = r.Height / _scale;
        Canvas.SetLeft(_selBorder, dx);
        Canvas.SetTop(_selBorder, dy);
        _selBorder.Width = dw;
        _selBorder.Height = dh;
        _selBorder.Visibility = (dw > 0 && dh > 0) ? Visibility.Visible : Visibility.Collapsed;
        UpdateDark(r);
    }

    // Dark wash = whole window minus the selection (EvenOdd fill punches the hole).
    private void UpdateDark(GdiRect? r)
    {
        double fw = _vw / _scale, fh = _vh / _scale;
        var full = new RectangleGeometry(new Rect(0, 0, fw, fh));
        if (r is not { Width: > 0, Height: > 0 } s) { _dark.Data = full; return; }
        var inner = new RectangleGeometry(new Rect(s.X / _scale, s.Y / _scale, s.Width / _scale, s.Height / _scale));
        var grp = new GeometryGroup { FillRule = FillRule.EvenOdd };
        grp.Children.Add(full);
        grp.Children.Add(inner);
        _dark.Data = grp;
    }

    private void Finish(GdiRect? sel)
    {
        if (_finished) return;
        _finished = true;
        try { Close(); } catch { }
        _done(sel);
    }

    private static BitmapSource ToBitmapSource(GdiBitmap bmp)
    {
        var h = bmp.GetHbitmap();
        try
        {
            var src = Imaging.CreateBitmapSourceFromHBitmap(
                h, IntPtr.Zero, Int32Rect.Empty, BitmapSizeOptions.FromEmptyOptions());
            src.Freeze();
            return src;
        }
        finally { DeleteObject(h); }
    }
}
