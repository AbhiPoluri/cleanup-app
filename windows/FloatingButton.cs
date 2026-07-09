using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
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
    private readonly Action _onClicked;
    private readonly Func<bool> _popupOpen;
    private readonly Func<bool> _pinned;
    private readonly Action<string, IntPtr> _onPinnedText;
    private readonly uint _pid = (uint)Environment.ProcessId;

    private FloatingButtonWindow? _button;
    private POINT _downAt;
    private uint _lastUpTime;
    private POINT _lastUpAt;

    public SelectionWatcher(Action onClicked, Func<bool> popupOpen,
                            Func<bool> pinned, Action<string, IntPtr> onPinnedText)
    {
        _onClicked = onClicked;
        _popupOpen = popupOpen;
        _pinned = pinned;
        _onPinnedText = onPinnedText;
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

        // pinned: the popup itself is the receiver — capture the new selection and
        // feed it in (no floating button). Same 250ms settle as the normal path.
        if (_pinned())
        {
            Log.Write($"pinned gesture: dragged={dragged} dbl={doubleClick} — capturing selection");
            var pinTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
            pinTimer.Tick += async (_, _) =>
            {
                pinTimer.Stop();
                var (text, hwnd) = await Capture.GrabSelection();
                if (!string.IsNullOrWhiteSpace(text))
                    _onPinnedText(text!, hwnd);
            };
            pinTimer.Start();
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
        _button ??= new FloatingButtonWindow(() =>
        {
            Log.Write("floating button clicked");
            HideButton();
            _onClicked();
        });
        Log.Write($"floating button shown near {screenX},{screenY}");
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

    // logical (DIP) button size; physical size scales with the target monitor DPI
    private const double BtnDip = 30;

    private readonly DispatcherTimer _autoHide = new() { Interval = TimeSpan.FromSeconds(4) };

    public FloatingButtonWindow(Action onClick)
    {
        var t = Theme.Detect();
        Width = BtnDip; Height = BtnDip;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = System.Windows.Media.Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;

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
            Child = new TextBlock
            {
                Text = "✦",
                FontSize = 13,
                Foreground = t.Accent,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        };
        border.MouseLeftButtonUp += (_, e) => { e.Handled = true; onClick(); };
        Content = border;

        _autoHide.Tick += (_, _) => { _autoHide.Stop(); Hide(); };
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
        if (!IsVisible) Show(); // realize the HWND
        var h = new WindowInteropHelper(this).Handle;
        // Size and offsets in device px, scaled to the target monitor's DPI so the
        // button is the same physical size on every screen. Flip below the cursor
        // if too close to the top. A window shown without activation isn't raised —
        // HWND_TOPMOST pins it above the foreground app without stealing focus.
        uint dpi = ScreenUtil.DpiForPoint(screenX, screenY);
        double s = dpi / 96.0;
        int size = (int)Math.Round(BtnDip * s);
        int x = screenX + (int)Math.Round(16 * s);
        int y = screenY - (int)Math.Round(46 * s);
        if (y < (int)Math.Round(4 * s)) y = screenY + (int)Math.Round(20 * s);
        SetWindowPos(h, HWND_TOPMOST, x, y, size, size, SWP_NOACTIVATE | SWP_SHOWWINDOW);
        _autoHide.Stop();
        _autoHide.Start();
    }

    public void HideButton()
    {
        _autoHide.Stop();
        if (IsVisible) Hide();
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
