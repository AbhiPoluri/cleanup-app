using System;
using System.Runtime.InteropServices;

namespace Cleanup;

// Shared per-monitor geometry + DPI helpers. All coordinates here are DEVICE
// PIXELS (what Win32 speaks) — WPF Left/Top/Width are DIPs and are unreliable
// once a window is moved across monitors, so positioning is done in device px
// via SetWindowPos and only converted to DIPs when handing sizes back to WPF.
public static class ScreenUtil
{
    [StructLayout(LayoutKind.Sequential)]
    public struct NativePoint { public int X, Y; }

    [StructLayout(LayoutKind.Sequential)]
    public struct NativeRect
    {
        public int Left, Top, Right, Bottom;
        public int Width => Right - Left;
        public int Height => Bottom - Top;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MONITORINFO
    {
        public int cbSize;
        public NativeRect rcMonitor;
        public NativeRect rcWork;
        public uint dwFlags;
    }

    private const uint MONITOR_DEFAULTTONEAREST = 2;
    private const int MDT_EFFECTIVE_DPI = 0;

    [DllImport("user32.dll")] private static extern bool GetCursorPos(out NativePoint p);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromPoint(NativePoint pt, uint flags);
    [DllImport("user32.dll")] private static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO mi);

    // shcore.dll ships on Win 8.1+; wrapped so a missing export degrades to 96 DPI.
    [DllImport("shcore.dll")] private static extern int GetDpiForMonitor(IntPtr hmon, int dpiType, out uint dpiX, out uint dpiY);

    public static NativePoint CursorPos()
    {
        GetCursorPos(out var p);
        return p;
    }

    private static IntPtr MonitorAt(int x, int y) =>
        MonitorFromPoint(new NativePoint { X = x, Y = y }, MONITOR_DEFAULTTONEAREST);

    // Effective DPI of the monitor under the given device-pixel point (96 = 100%).
    public static uint DpiForPoint(int x, int y)
    {
        try
        {
            var mon = MonitorAt(x, y);
            if (mon != IntPtr.Zero && GetDpiForMonitor(mon, MDT_EFFECTIVE_DPI, out var dx, out _) == 0 && dx > 0)
                return dx;
        }
        catch { /* shcore missing / pre-8.1 → fall through */ }
        return 96;
    }

    // Work area (excludes taskbar) of the monitor under the given point, device px.
    public static NativeRect WorkAreaForPoint(int x, int y)
    {
        var mon = MonitorAt(x, y);
        if (mon != IntPtr.Zero)
        {
            var mi = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
            if (GetMonitorInfo(mon, ref mi)) return mi.rcWork;
        }
        // last-resort full virtual-screen-ish fallback
        return new NativeRect { Left = 0, Top = 0, Right = 1920, Bottom = 1080 };
    }
}
