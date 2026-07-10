using System;
using System.Drawing;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
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
    private WF.ToolStripMenuItem? _autoReplaceItem;
    // in-flight hands-free generation (null when idle) + its progress chip
    private CancellationTokenSource? _autoCts;
    private ProgressChipWindow? _autoChip;

    public static AppController? Current { get; private set; }

    public AppController()
    {
        Current = this;
        _tray = new WF.NotifyIcon
        {
            Icon = MakeTrayIcon(),
            Visible = true,
            Text = TrayTip(),
        };
        var menu = new WF.ContextMenuStrip();
        menu.Items.Add("Test Popup", null, (_, _) => ShowPopup(Program.SampleText, IntPtr.Zero));
        menu.Items.Add("Settings…", null, (_, _) => OpenSettings());
        var autoReplaceItem = new WF.ToolStripMenuItem("Auto-replace first variant")
        {
            CheckOnClick = true,
            Checked = Settings.Current.AutoReplace,
        };
        autoReplaceItem.CheckedChanged += (_, _) =>
        {
            if (Settings.Current.AutoReplace == autoReplaceItem.Checked) return;
            Settings.Current.AutoReplace = autoReplaceItem.Checked;
            Settings.Current.Save();
            Log.Write($"autoreplace toggled {(autoReplaceItem.Checked ? "ON" : "OFF")} (tray)");
        };
        menu.Items.Add(autoReplaceItem);
        _autoReplaceItem = autoReplaceItem;
        menu.Items.Add("Check for Updates…", null, (_, _) => OpenSettings());
        menu.Items.Add("Test ✦ Button", null, (_, _) =>
        {
            var p = WF.Cursor.Position;
            _watcher.ShowTestButton(p.X, p.Y);
        });
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
        _watcher = new SelectionWatcher(
            OnHotkey,
            () => _popup != null,
            () => _popup?.IsAutoMode == true,
            (text, hwnd) => _popup?.UpdateSource(text, hwnd));
    }

    public void RefreshHotkey()
    {
        _hotkey.Reregister();
        _tray.Text = TrayTip();
    }

    // keep the tray checkmark in sync after the Settings window saves
    public void SyncAutoReplaceMenu()
    {
        if (_autoReplaceItem != null) _autoReplaceItem.Checked = Settings.Current.AutoReplace;
    }

    private static string TrayTip() =>
        $"Cleanup {Updater.DisplayVersion} — {Settings.Current.HotkeyDisplay} on selected text";

    private async void OnHotkey()
    {
        Log.Write("trigger fired");
        // A second trigger while a hands-free generation is in flight cancels it.
        if (_autoCts != null)
        {
            Log.Write("autoreplace: cancelled by second trigger");
            _autoCts.Cancel();
            HideAutoChip();
            return;
        }
        // Hands-free path: bypass the popup entirely.
        if (Settings.Current.AutoReplace)
        {
            _popup?.SafeClose();   // don't let a stray popup fight over the clipboard
            await AutoReplace();
            return;
        }
        if (_popup != null) return;
        // Warm DNS+TCP+TLS to the active remote backend now, in parallel with the
        // capture below, so the first variant skips the cold handshake. No-op for
        // local Ollama / when the pool is already warm.
        _ = Llm.Prewarm();
        var sw = System.Diagnostics.Stopwatch.StartNew();
        // cursor at trigger time — the popup opens on this monitor near this point
        var anchor = ScreenUtil.CursorPos();
        var (text, hwnd) = await Capture.GrabSelection();
        Log.Write($"trigger→capture-complete {sw.ElapsedMilliseconds}ms");
        if (text == null)
        {
            System.Media.SystemSounds.Beep.Play();
            return;
        }
        sw.Restart();
        ShowPopup(text, hwnd, anchor);
        Log.Write($"capture→popup-shown {sw.ElapsedMilliseconds}ms");
    }

    // Hands-free: capture → generate ONE balanced variant (no popup, no streaming)
    // → paste straight back over the selection. On any failure (LLM error, empty
    // result) fall back to the normal popup, which surfaces errors well. An empty
    // capture just beeps (there's nothing to rewrite or fall back to).
    private async Task AutoReplace()
    {
        var cts = new CancellationTokenSource();
        _autoCts = cts;
        var sw = System.Diagnostics.Stopwatch.StartNew();
        IntPtr hwnd = IntPtr.Zero;
        string? text = null;
        try
        {
            _ = Llm.Prewarm();
            var anchor = ScreenUtil.CursorPos();
            (text, hwnd) = await Capture.GrabSelection();
            if (text == null)
            {
                System.Media.SystemSounds.Beep.Play();
                return;
            }
            if (cts.IsCancellationRequested) return;

            ShowAutoChip(anchor);
            Log.Write($"autoreplace: start len={text.Length} backend={Settings.Current.Backend}");

            string result;
            try
            {
                result = await Llm.Complete(
                    Prompts.System, Prompts.Variant(text, Settings.Current.DefaultTone, 0), cts.Token, 0);
            }
            catch (OperationCanceledException)
            {
                Log.Write("autoreplace: cancelled");
                return;
            }
            catch (Exception ex)
            {
                HideAutoChip();
                Log.Write($"autoreplace: failed — {ex.Message} (falling back to popup)");
                ShowPopup(text, hwnd, anchor);
                return;
            }

            if (cts.IsCancellationRequested) return;
            if (string.IsNullOrWhiteSpace(result))
            {
                HideAutoChip();
                Log.Write("autoreplace: failed — empty result (falling back to popup)");
                ShowPopup(text, hwnd, anchor);
                return;
            }

            HideAutoChip();
            await Capture.PasteInto(hwnd, result);
            Log.Write($"autoreplace: done total={sw.ElapsedMilliseconds}ms");
        }
        finally
        {
            HideAutoChip();
            if (ReferenceEquals(_autoCts, cts)) _autoCts = null;
        }
    }

    private void ShowAutoChip(ScreenUtil.NativePoint anchor)
    {
        _autoChip ??= new ProgressChipWindow();
        _autoChip.ShowNear(anchor.X, anchor.Y);
    }

    private void HideAutoChip() => _autoChip?.HideChip();

    public void ShowPopup(string text, IntPtr targetHwnd) =>
        ShowPopup(text, targetHwnd, ScreenUtil.CursorPos());

    public void ShowPopup(string text, IntPtr targetHwnd, ScreenUtil.NativePoint anchor)
    {
        _popup?.SafeClose();
        _popup = new PopupWindow(text, targetHwnd, anchor);
        _popup.Closed += (_, _) => _popup = null;
        _popup.Show();
        _popup.Activate();
        Log.Write($"popup shown ({text.Length} chars)");
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
        _autoCts?.Cancel();
        _autoChip?.Close();
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
    private readonly Action _callback;

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    public HotkeyWindow(Action callback)
    {
        _callback = callback;
        CreateHandle(new WF.CreateParams());
        Reregister();
    }

    public void Reregister()
    {
        UnregisterHotKey(Handle, 1);
        var s = Settings.Current;
        if (RegisterHotKey(Handle, 1, s.HotkeyModifiers, s.HotkeyKey))
        {
            Log.Write($"hotkey {s.HotkeyDisplay} registered");
        }
        else
        {
            Log.Write($"hotkey {s.HotkeyDisplay} FAILED to register — another app owns it");
            WF.MessageBox.Show(
                $"Another app already owns {s.HotkeyDisplay}, so the Cleanup hotkey won't work.\n" +
                "Pick a different hotkey in Settings, or use the floating ✦ button.",
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
