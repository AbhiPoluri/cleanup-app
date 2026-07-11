using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;

namespace Cleanup;

// PopClip-style trigger: select text with the mouse anywhere, a small ✦ button
// fades in near the selection end; clicking it opens the cleanup popup.
public sealed class SelectionWatcher : IDisposable
{
    private const int WH_MOUSE_LL = 14;
    private const int WM_LBUTTONDOWN = 0x0201, WM_LBUTTONUP = 0x0202, WM_MOUSEWHEEL = 0x020A;
    private const int DragThresholdPx = 15;

    private delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    private struct MSLLHOOKSTRUCT { public POINT pt; public uint mouseData, flags, time; public UIntPtr dwExtraInfo; }

    [DllImport("user32.dll", SetLastError = true)] private static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("kernel32.dll", CharSet = CharSet.Auto)] private static extern IntPtr GetModuleHandle(string? lpModuleName);
    [DllImport("user32.dll")] private static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")] private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] private static extern uint GetDoubleClickTime();

    private readonly HookProc _proc;   // held so the GC can't collect the hook callback
    private readonly IntPtr _hook;
    private readonly Action _onClicked;   // ✦ chip → open the popup
    private readonly Action _onInstant;   // ⚡ chip → hands-free auto-replace
    private readonly Func<bool> _popupOpen;
    private readonly Func<bool> _autoMode;
    private readonly Action<string, IntPtr> _onAutoText;
    private readonly uint _pid = (uint)Environment.ProcessId;

    private FloatingButtonWindow? _button;
    private POINT _downAt;
    private uint _lastUpTime;
    private POINT _lastUpAt;

    public SelectionWatcher(Action onClicked, Action onInstant, Func<bool> popupOpen,
                            Func<bool> autoMode, Action<string, IntPtr> onAutoText)
    {
        _onClicked = onClicked;
        _onInstant = onInstant;
        _popupOpen = popupOpen;
        _autoMode = autoMode;
        _onAutoText = onAutoText;
        _proc = Hook;
        _hook = SetWindowsHookEx(WH_MOUSE_LL, _proc, GetModuleHandle(null), 0);
        Log.Write(_hook == IntPtr.Zero
            ? $"mouse hook FAILED (err {Marshal.GetLastWin32Error()}) — floating button disabled"
            : "mouse hook installed");
    }

    private IntPtr Hook(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var info = Marshal.PtrToStructure<MSLLHOOKSTRUCT>(lParam);
            switch ((int)wParam)
            {
                case WM_LBUTTONDOWN:
                    _downAt = info.pt;
                    if (_button?.IsMouseOverButton(info.pt.X, info.pt.Y) != true)
                        HideButton();
                    break;
                case WM_LBUTTONUP:
                    OnMouseUp(info.pt);
                    break;
                case WM_MOUSEWHEEL:
                    HideButton();
                    break;
            }
        }
        return CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    private void OnMouseUp(POINT pt)
    {
        int dx = Math.Abs(pt.X - _downAt.X), dy = Math.Abs(pt.Y - _downAt.Y);
        bool dragged = dx > DragThresholdPx || dy > DragThresholdPx;

        uint now = (uint)Environment.TickCount;
        bool doubleClick = now - _lastUpTime < GetDoubleClickTime()
                           && Math.Abs(pt.X - _lastUpAt.X) < 6 && Math.Abs(pt.Y - _lastUpAt.Y) < 6;
        _lastUpTime = now;
        _lastUpAt = pt;

        if (!dragged && !doubleClick) return;
        // never react to selections made inside our own popup / floating button
        if (IsOurWindowAt(pt)) return;

        // auto mode: the popup itself is the receiver — capture the new selection
        // and feed it in (no floating button). Same 250ms settle as the normal path.
        if (_autoMode())
        {
            Log.Write($"auto gesture: dragged={dragged} dbl={doubleClick} — capturing selection");
            var autoTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
            autoTimer.Tick += async (_, _) =>
            {
                autoTimer.Stop();
                var (text, hwnd) = await Capture.GrabSelection();
                if (!string.IsNullOrWhiteSpace(text))
                    _onAutoText(text!, hwnd);
            };
            autoTimer.Start();
            return;
        }

        Log.Write($"gesture: dragged={dragged} dbl={doubleClick} enabled={Settings.Current.FloatingButton} popupOpen={_popupOpen()}");
        if (!Settings.Current.FloatingButton) return;
        if (_popupOpen()) return;

        // small delay so the button doesn't flash mid-interaction
        var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            ShowButton(pt.X, pt.Y);
        };
        timer.Start();
    }

    private bool IsOurWindowAt(POINT pt)
    {
        var hwnd = WindowFromPoint(pt);
        if (hwnd == IntPtr.Zero) return false;
        GetWindowThreadProcessId(hwnd, out var pid);
        return pid == _pid;
    }

    private void ShowButton(int screenX, int screenY)
    {
        _button ??= new FloatingButtonWindow(
            onStar: () =>
            {
                Log.Write("floating ✦ clicked");
                HideButton();
                _onClicked();
            },
            onBolt: () =>
            {
                Log.Write("floating ⚡ clicked");
                HideButton();
                _onInstant();
            });
        Log.Write($"floating buttons shown near {screenX},{screenY}");
        _button.ShowNear(screenX, screenY);
    }

    private void HideButton() => _button?.HideButton();

    // tray-menu test: shows the button unconditionally to isolate hook vs window failures
    public void ShowTestButton(int screenX, int screenY) => ShowButton(screenX, screenY);

    public void Dispose()
    {
        if (_hook != IntPtr.Zero) UnhookWindowsHookEx(_hook);
        _button?.Close();
    }
}

public sealed class FloatingButtonWindow : Window
{
    private const int GWL_EXSTYLE = -20;
    private const int WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOOLWINDOW = 0x00000080;

    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] private static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint flags);

    private static readonly IntPtr HWND_TOPMOST = new(-1);
    private const uint SWP_NOACTIVATE = 0x0010, SWP_SHOWWINDOW = 0x0040;

    // logical (DIP) chip size; user-configurable (Settings.FloatingButtonSize,
    // 22–48, default 30). Read fresh on each ShowNear so a size change in Settings
    // takes effect on the next appearance. Physical size scales with monitor DPI.
    private static double BtnDip => Math.Clamp(Settings.Current.FloatingButtonSize, 22, 48);
    // gap (DIP) between the two chips; scales with the chip size
    private static double GapDip => Math.Round(BtnDip * 0.2);

    private readonly DispatcherTimer _autoHide = new() { Interval = TimeSpan.FromSeconds(4) };
    private readonly StackPanel _row;
    private readonly Border _star;
    private readonly TextBlock _starGlyph;
    private readonly Border _bolt;
    private readonly TextBlock _boltGlyph;
    private readonly ScaleTransform _scale = new(1, 1);
    private bool _hiding;

    public FloatingButtonWindow(Action onStar, Action onBolt)
    {
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = System.Windows.Media.Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;

        // Two chips side by side in a single window: ✦ opens the popup, ⚡ runs the
        // hands-free instant-replace. One window keeps a single z-order/positioning
        // pass and one auto-hide/fade for both. The transparent gap between the
        // rounded pills makes them read as two separate buttons.
        _star = MakeChip("✦", onStar, out _starGlyph);
        _star.Margin = new Thickness(0, 0, GapDip, 0);
        _bolt = MakeChip("⚡", onBolt, out _boltGlyph);
        _row = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            RenderTransformOrigin = new Point(0.5, 0.5),
            RenderTransform = _scale,
        };
        _row.Children.Add(_star);
        _row.Children.Add(_bolt);
        Content = _row;

        _autoHide.Tick += (_, _) => { _autoHide.Stop(); HideButton(); };
    }

    private static Border MakeChip(string glyph, Action onClick, out TextBlock glyphBlock)
    {
        var t = Theme.Detect();
        var border = new Border
        {
            // corner-radius = height/2 for a pill/circle. WPF does NOT clamp
            // oversized radii like CSS — a fixed 99 renders ovals — so it must
            // track the DIP size (15 = 30/2).
            CornerRadius = new CornerRadius(BtnDip / 2),
            Background = t.Surface,
            BorderBrush = t.LineStrong,
            BorderThickness = new Thickness(1),
            Cursor = Cursors.Hand,
            Width = BtnDip,
            Height = BtnDip,
            // ⚡ styled exactly like ✦ — glyph in the accent/text colour, same surface
            Child = glyphBlock = new TextBlock
            {
                Text = glyph,
                FontSize = BtnDip * 0.43,   // ~13 at size 30; scales with the chip
                Foreground = t.Accent,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        };
        border.MouseLeftButtonUp += (_, e) => { e.Handled = true; onClick(); };
        return border;
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        // never steal focus — the source app must keep its selection active
        var h = new WindowInteropHelper(this).Handle;
        SetWindowLong(h, GWL_EXSTYLE, GetWindowLong(h, GWL_EXSTYLE) | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW);
    }

    public void ShowNear(int screenX, int screenY)
    {
        // pick up the current configured size before realizing/placing the window
        double dip = BtnDip;
        double gap = GapDip;
        double rowDip = dip * 2 + gap;
        // corner-radius = height/2 keeps each chip a perfect circle (WPF won't clamp
        // an oversized radius like CSS, so it must track the live size, not a const).
        foreach (var (chip, gl) in new[] { (_star, _starGlyph), (_bolt, _boltGlyph) })
        {
            chip.Width = chip.Height = dip;
            chip.CornerRadius = new CornerRadius(dip / 2);
            gl.FontSize = dip * 0.43;
        }
        _star.Margin = new Thickness(0, 0, gap, 0);
        Width = rowDip; Height = dip;

        if (!IsVisible) Show(); // realize the HWND
        var h = new WindowInteropHelper(this).Handle;
        // Size and offsets in device px, scaled to the target monitor's DPI so the
        // chips are the same physical size on every screen. Flip below the cursor
        // if too close to the top. A window shown without activation isn't raised —
        // HWND_TOPMOST pins it above the foreground app without stealing focus.
        uint dpi = ScreenUtil.DpiForPoint(screenX, screenY);
        double s = dpi / 96.0;
        int w = (int)Math.Round(rowDip * s);
        int hgt = (int)Math.Round(dip * s);
        int x = screenX + (int)Math.Round(16 * s);
        int y = screenY - (int)Math.Round(46 * s);
        if (y < (int)Math.Round(4 * s)) y = screenY + (int)Math.Round(20 * s);
        SetWindowPos(h, HWND_TOPMOST, x, y, w, hgt, SWP_NOACTIVATE | SWP_SHOWWINDOW);

        // fade + scale in (~120ms). Cancels any in-flight hide.
        _hiding = false;
        var d = new Duration(TimeSpan.FromMilliseconds(120));
        var ease = new QuadraticEase { EasingMode = EasingMode.EaseOut };
        _row.Opacity = 0;
        _scale.ScaleX = _scale.ScaleY = 0.8;
        _row.BeginAnimation(OpacityProperty, new DoubleAnimation(0, 1, d) { EasingFunction = ease });
        _scale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.8, 1, d) { EasingFunction = ease });
        _scale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.8, 1, d) { EasingFunction = ease });

        _autoHide.Stop();
        _autoHide.Start();
    }

    public void HideButton()
    {
        _autoHide.Stop();
        if (!IsVisible || _hiding) return;
        _hiding = true;

        var d = new Duration(TimeSpan.FromMilliseconds(100));
        var ease = new QuadraticEase { EasingMode = EasingMode.EaseOut };
        var fade = new DoubleAnimation(0, d) { EasingFunction = ease };
        fade.Completed += (_, _) =>
        {
            if (!_hiding) return;   // a re-show raced us — keep it visible
            _hiding = false;
            Hide();
            _row.BeginAnimation(OpacityProperty, null);
            _row.Opacity = 1;
            _scale.ScaleX = _scale.ScaleY = 1;
        };
        _scale.BeginAnimation(ScaleTransform.ScaleXProperty, new DoubleAnimation(0.9, d) { EasingFunction = ease });
        _scale.BeginAnimation(ScaleTransform.ScaleYProperty, new DoubleAnimation(0.9, d) { EasingFunction = ease });
        _row.BeginAnimation(OpacityProperty, fade);
    }

    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [StructLayout(LayoutKind.Sequential)]
    private struct RECT { public int Left, Top, Right, Bottom; }

    public bool IsMouseOverButton(int screenX, int screenY)
    {
        if (!IsVisible) return false;
        var h = new WindowInteropHelper(this).Handle;
        if (!GetWindowRect(h, out var r)) return false;
        return screenX >= r.Left && screenX <= r.Right && screenY >= r.Top && screenY <= r.Bottom;
    }
}

// Hands-free progress indicator: a small ✦ chip that pulses near the cursor while
// an auto-replace generation is in flight. Same NOACTIVATE + topmost + DPI-scaled
// SetWindowPos device-px pattern as FloatingButtonWindow so it never steals focus
// (which would kill the source app's selection). The pulse animates opacity only
// (Mono-legal), like LoadingDots.
public sealed class ProgressChipWindow : Window
{
    private const int GWL_EXSTYLE = -20;
    private const int WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOOLWINDOW = 0x00000080;

    [DllImport("user32.dll")] private static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] private static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int x, int y, int cx, int cy, uint flags);

    private static readonly IntPtr HWND_TOPMOST = new(-1);
    private const uint SWP_NOACTIVATE = 0x0010, SWP_SHOWWINDOW = 0x0040;

    private const double Dip = 30;   // fixed logical size — matches the ✦ button default
    private readonly TextBlock _glyph;

    public ProgressChipWindow()
    {
        var t = Theme.Detect();
        Width = Dip; Height = Dip;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = System.Windows.Media.Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;

        _glyph = new TextBlock
        {
            Text = "✦",
            FontSize = Dip * 0.43,
            Foreground = t.Accent,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
        };
        Content = new Border
        {
            CornerRadius = new CornerRadius(Dip / 2),
            Background = t.Surface,
            BorderBrush = t.LineStrong,
            BorderThickness = new Thickness(1),
            Child = _glyph,
        };
    }

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        // never steal focus — the source app must keep its selection active
        var h = new WindowInteropHelper(this).Handle;
        SetWindowLong(h, GWL_EXSTYLE, GetWindowLong(h, GWL_EXSTYLE) | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW);
    }

    public void ShowNear(int screenX, int screenY)
    {
        if (!IsVisible) Show();   // realize the HWND
        var h = new WindowInteropHelper(this).Handle;
        uint dpi = ScreenUtil.DpiForPoint(screenX, screenY);
        double s = dpi / 96.0;
        int size = (int)Math.Round(Dip * s);
        int x = screenX + (int)Math.Round(16 * s);
        int y = screenY - (int)Math.Round(46 * s);
        if (y < (int)Math.Round(4 * s)) y = screenY + (int)Math.Round(20 * s);
        SetWindowPos(h, HWND_TOPMOST, x, y, size, size, SWP_NOACTIVATE | SWP_SHOWWINDOW);

        // pulse the glyph opacity forever until hidden (opacity only → Mono-legal)
        var pulse = new DoubleAnimation(0.9, 0.3, Anim.Ms(600))
        {
            AutoReverse = true,
            RepeatBehavior = RepeatBehavior.Forever,
            EasingFunction = Anim.EaseInOut,
        };
        _glyph.BeginAnimation(UIElement.OpacityProperty, pulse);
    }

    public void HideChip()
    {
        _glyph.BeginAnimation(UIElement.OpacityProperty, null);   // detaches the clock
        _glyph.Opacity = 1;
        if (IsVisible) Hide();
    }
}
