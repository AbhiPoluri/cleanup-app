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
    private readonly uint _pid = (uint)Environment.ProcessId;

    private FloatingButtonWindow? _button;
    private POINT _downAt;
    private uint _lastUpTime;
    private POINT _lastUpAt;

    public SelectionWatcher(Action onClicked, Func<bool> popupOpen)
    {
        _onClicked = onClicked;
        _popupOpen = popupOpen;
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
        Log.Write($"gesture: dragged={dragged} dbl={doubleClick} enabled={Settings.Current.FloatingButton} popupOpen={_popupOpen()} ours={IsOurWindowAt(pt)}");
        if (!Settings.Current.FloatingButton) return;
        if (_popupOpen()) return;
        if (IsOurWindowAt(pt)) return;

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

    private readonly DispatcherTimer _autoHide = new() { Interval = TimeSpan.FromSeconds(4) };

    public FloatingButtonWindow(Action onClick)
    {
        var t = Theme.Detect();
        Width = 30; Height = 30;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = System.Windows.Media.Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        ShowActivated = false;
        ResizeMode = ResizeMode.NoResize;

        var border = new Border
        {
            CornerRadius = new CornerRadius(15),
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
        Show(); // realize the HWND so DPI is known
        var src = PresentationSource.FromVisual(this);
        double scale = src?.CompositionTarget?.TransformToDevice.M11 ?? 1.0;
        double x = screenX / scale + 14, y = screenY / scale - 38;
        var wa = SystemParameters.WorkArea;
        Left = Math.Max(wa.Left + 4, Math.Min(x, wa.Right - Width - 4));
        Top = Math.Max(wa.Top + 4, Math.Min(y, wa.Bottom - Height - 4));
        _autoHide.Stop();
        _autoHide.Start();
    }

    public void HideButton()
    {
        _autoHide.Stop();
        if (IsVisible) Hide();
    }

    public bool IsMouseOverButton(int screenX, int screenY)
    {
        if (!IsVisible) return false;
        var src = PresentationSource.FromVisual(this);
        double scale = src?.CompositionTarget?.TransformToDevice.M11 ?? 1.0;
        double x = screenX / scale, y = screenY / scale;
        return x >= Left && x <= Left + Width && y >= Top && y <= Top + Height;
    }
}
