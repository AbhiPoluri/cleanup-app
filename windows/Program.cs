using System;
using System.Drawing;
using System.Linq;
using WF = System.Windows.Forms;

namespace Cleanup;

public static class Program
{
    public const string SampleText =
        "hey can u send me the notes from todays lecture i missed it cuz my bus was late lol " +
        "also did prof say anything abt the midterm format";

    public static bool TestMode { get; private set; }

    [STAThread]
    public static void Main(string[] args)
    {
        TestMode = args.Contains("--test");

        using var mutex = new System.Threading.Mutex(true, "CleanupSingleInstance", out bool first);
        if (!first)
        {
            WF.MessageBox.Show("Cleanup is already running — check the tray. Quit it there before starting a new one.",
                "Cleanup");
            return;
        }

        Log.Write($"=== Cleanup starting (test={TestMode}) ===");
        AppDomain.CurrentDomain.UnhandledException += (_, e) =>
            Log.Write("FATAL: " + e.ExceptionObject);

        var app = new System.Windows.Application
        {
            ShutdownMode = System.Windows.ShutdownMode.OnExplicitShutdown,
        };
        app.DispatcherUnhandledException += (_, e) =>
        {
            Log.Write("UNHANDLED: " + e.Exception);
            e.Handled = true;
        };

        var controller = new AppController();
        if (TestMode)
            app.Dispatcher.BeginInvoke(() => controller.ShowPopup(SampleText, IntPtr.Zero));
        app.Run();
        controller.Dispose();
    }
}

public sealed class AppController : IDisposable
{
    private readonly WF.NotifyIcon _tray;
    private readonly HotkeyWindow _hotkey;
    private readonly SelectionWatcher _watcher;
    private PopupWindow? _popup;

    public AppController()
    {
        _tray = new WF.NotifyIcon
        {
            Icon = MakeTrayIcon(),
            Visible = true,
            Text = "Cleanup — Ctrl+Shift+E on selected text",
        };
        var menu = new WF.ContextMenuStrip();
        menu.Items.Add("Test Popup", null, (_, _) => ShowPopup(Program.SampleText, IntPtr.Zero));
        menu.Items.Add("Settings…", null, (_, _) => OpenSettings());
        menu.Items.Add("Open Log", null, (_, _) =>
        {
            try { System.Diagnostics.Process.Start("notepad.exe", Log.FilePath); } catch { }
        });
        menu.Items.Add(new WF.ToolStripSeparator());
        menu.Items.Add("Quit Cleanup", null, (_, _) =>
        {
            _tray.Visible = false;
            System.Windows.Application.Current.Shutdown();
        });
        _tray.ContextMenuStrip = menu;

        _hotkey = new HotkeyWindow(OnHotkey);
        _watcher = new SelectionWatcher(OnHotkey, () => _popup != null);
    }

    private async void OnHotkey()
    {
        Log.Write("trigger fired");
        if (_popup != null) return;
        var (text, hwnd) = await Capture.GrabSelection();
        if (text == null)
        {
            System.Media.SystemSounds.Beep.Play();
            return;
        }
        ShowPopup(text, hwnd);
    }

    public void ShowPopup(string text, IntPtr targetHwnd)
    {
        _popup?.SafeClose();
        _popup = new PopupWindow(text, targetHwnd);
        _popup.Closed += (_, _) => _popup = null;
        _popup.Show();
        _popup.Activate();
        Log.Write($"popup shown at {_popup.Left:F0},{_popup.Top:F0} ({text.Length} chars)");
    }

    public static void OpenSettings()
    {
        var w = new SettingsWindow();
        w.Show();
        w.Activate();
    }

    private static Icon MakeTrayIcon()
    {
        using var bmp = new Bitmap(32, 32);
        using var g = Graphics.FromImage(bmp);
        g.Clear(Color.Transparent);
        using var font = new Font("Segoe UI Symbol", 20, FontStyle.Bold, GraphicsUnit.Pixel);
        var color = Theme.Detect() == Theme.Dark ? Color.White : Color.Black;
        using var brush = new SolidBrush(color);
        g.DrawString("✦", font, brush, 3f, 3f);
        return Icon.FromHandle(bmp.GetHicon());
    }

    public void Dispose()
    {
        _tray.Visible = false;
        _tray.Dispose();
        _hotkey.Dispose();
        _watcher.Dispose();
    }
}

// Hidden message-only window that owns the global Ctrl+Shift+E hotkey.
public sealed class HotkeyWindow : WF.NativeWindow, IDisposable
{
    private const int WM_HOTKEY = 0x0312;
    private const uint MOD_CONTROL = 0x0002, MOD_SHIFT = 0x0004;
    private const uint VK_E = 0x45;
    private readonly Action _callback;

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    public HotkeyWindow(Action callback)
    {
        _callback = callback;
        CreateHandle(new WF.CreateParams());
        if (RegisterHotKey(Handle, 1, MOD_CONTROL | MOD_SHIFT, VK_E))
        {
            Log.Write("hotkey Ctrl+Shift+E registered");
        }
        else
        {
            Log.Write("hotkey Ctrl+Shift+E FAILED to register — another app owns it");
            WF.MessageBox.Show(
                "Another app already owns Ctrl+Shift+E, so the Cleanup hotkey won't work.\n" +
                "Use the floating ✦ button or the tray menu instead (or free up the shortcut).",
                "Cleanup");
        }
    }

    protected override void WndProc(ref WF.Message m)
    {
        if (m.Msg == WM_HOTKEY) _callback();
        base.WndProc(ref m);
    }

    public void Dispose()
    {
        UnregisterHotKey(Handle, 1);
        DestroyHandle();
    }
}
