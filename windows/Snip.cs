using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

namespace Cleanup;

// Which flavour of screen capture the ✂ chip / menu asked for.
public enum SnipMode { Area, Window, FullScreen }

// Screen-region capture ("snipping tool"). All geometry here is DEVICE PIXELS in
// virtual-screen coordinates (what Win32/GDI speak). Output is a PNG under
// %TEMP%\Cleanup\snip-<stamp>.png; a cancelled/empty capture returns null silently.
public static class Snip
{
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int nIndex);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hwnd, out RECT r);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT val, int size);

    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] private struct RECT { public int Left, Top, Right, Bottom; }

    private const int SM_XVIRTUALSCREEN = 76, SM_YVIRTUALSCREEN = 77, SM_CXVIRTUALSCREEN = 78, SM_CYVIRTUALSCREEN = 79;
    private const uint GA_ROOT = 2;
    private const int DWMWA_EXTENDED_FRAME_BOUNDS = 9;

    // Whole virtual desktop (all monitors), device px. Process is per-monitor-v2 aware
    // (app.manifest), so these metrics + GetCursorPos are already physical pixels.
    public static (int X, int Y, int W, int H) VirtualScreen() =>
        (GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN),
         GetSystemMetrics(SM_CXVIRTUALSCREEN), GetSystemMetrics(SM_CYVIRTUALSCREEN));

    private static Bitmap Grab(int x, int y, int w, int h)
    {
        var bmp = new Bitmap(Math.Max(1, w), Math.Max(1, h), PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(bmp);
        g.CopyFromScreen(x, y, 0, 0, new Size(Math.Max(1, w), Math.Max(1, h)), CopyPixelOperation.SourceCopy);
        return bmp;
    }

    private static string SavePng(Bitmap bmp)
    {
        var dir = Path.Combine(Path.GetTempPath(), "Cleanup");
        Directory.CreateDirectory(dir);
        var file = Path.Combine(dir, $"snip-{DateTime.Now:yyyyMMdd-HHmmss-fff}.png");
        bmp.Save(file, ImageFormat.Png);
        return file;
    }

    // Whole virtual screen → PNG path (no interaction).
    public static string? CaptureFullScreen()
    {
        try
        {
            var (x, y, w, h) = VirtualScreen();
            using var bmp = Grab(x, y, w, h);
            return SavePng(bmp);
        }
        catch (Exception ex) { Log.Write("snip: fullscreen failed — " + ex.Message); return null; }
    }

    // Foreground window under the cursor → PNG path. A 200ms delay lets the snip menu
    // close and the real target window return to the foreground before we sample it.
    // Uses the DWM extended frame bounds so drop-shadow padding isn't included.
    public static void CaptureWindow(Action<string?> onDone)
    {
        var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMilliseconds(200) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            string? path = null;
            try
            {
                var hwnd = GetForegroundWindow();
                if (hwnd == IntPtr.Zero) { GetCursorPos(out var cp); hwnd = GetAncestor(WindowFromPoint(cp), GA_ROOT); }
                RECT r;
                if (hwnd == IntPtr.Zero ||
                    DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, out r, Marshal.SizeOf<RECT>()) != 0)
                    GetWindowRect(hwnd, out r);
                int w = r.Right - r.Left, h = r.Bottom - r.Top;
                if (w > 0 && h > 0) { using var bmp = Grab(r.Left, r.Top, w, h); path = SavePng(bmp); }
            }
            catch (Exception ex) { Log.Write("snip: window capture failed — " + ex.Message); }
            onDone(path);
        };
        timer.Start();
    }

    // Interactive area capture: freeze the whole desktop into a bitmap FIRST (so the
    // dimmed overlay never captures itself), show the overlay, crop the dragged region
    // from the frozen bitmap. Esc / empty drag → null.
    public static void CaptureArea(Action<string?> onDone)
    {
        Bitmap? frozen = null;
        try
        {
            var (vx, vy, vw, vh) = VirtualScreen();
            frozen = Grab(vx, vy, vw, vh);
            var f = frozen;
            var win = new SnipOverlayWindow(f, vx, vy, vw, vh, sel =>
            {
                string? path = null;
                if (sel is { Width: > 1, Height: > 1 } s)
                {
                    try
                    {
                        // clamp to the frozen bitmap bounds so a fast drag off-screen can't throw
                        int x = Math.Max(0, Math.Min(s.X, f.Width - 1));
                        int y = Math.Max(0, Math.Min(s.Y, f.Height - 1));
                        int w = Math.Min(s.Width, f.Width - x);
                        int h = Math.Min(s.Height, f.Height - y);
                        if (w > 1 && h > 1)
                        {
                            using var crop = f.Clone(new Rectangle(x, y, w, h), f.PixelFormat);
                            path = SavePng(crop);
                        }
                    }
                    catch (Exception ex) { Log.Write("snip: crop failed — " + ex.Message); }
                }
                f.Dispose();
                onDone(path);
            });
            win.Show();
        }
        catch (Exception ex)
        {
            Log.Write("snip: area failed — " + ex.Message);
            frozen?.Dispose();
            onDone(null);
        }
    }
}
