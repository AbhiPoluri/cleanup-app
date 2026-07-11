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

        // Two global hotkeys + two floating chips feed two entry points:
        //   main    → open the popup (Ctrl+Shift+E / ✦ chip)
        //   instant → hands-free auto-replace (Ctrl+Shift+R / ⚡ chip)
        _hotkey = new HotkeyWindow(OnMainTrigger, () => OnInstantTrigger("hotkey"));
        _watcher = new SelectionWatcher(
            OnMainTrigger,
            () => OnInstantTrigger("chip"),
            () => _popup != null,
            () => _popup?.IsAutoMode == true,
            (text, hwnd) => _popup?.UpdateSource(text, hwnd));
    }

    public void RefreshHotkey()
    {
        _hotkey.Reregister();
        _tray.Text = TrayTip();
    }

    private static string TrayTip() =>
        $"Cleanup {Updater.DisplayVersion} — {Settings.Current.HotkeyDisplay} on selected text";

    // Main trigger (Ctrl+Shift+E hotkey / ✦ chip): capture → open the popup.
    private async void OnMainTrigger()
    {
        Log.Write("trigger fired (main)");
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

    // Instant trigger (Ctrl+Shift+R hotkey / ⚡ chip): hands-free auto-replace.
    // Works regardless of popup state — a stray popup is closed first so they
    // don't fight over the clipboard. A second instant trigger while a generation
    // is in flight cancels it.
    private async void OnInstantTrigger(string source)
    {
        Log.Write($"trigger fired (instant, {source})");
        if (_autoCts != null)
        {
            Log.Write($"autoreplace: cancelled by second trigger ({source})");
            _autoCts.Cancel();
            HideAutoChip();
            return;
        }
        _popup?.SafeClose();
        await AutoReplace(source);
    }

    // Hands-free: capture → generate ONE balanced variant (no popup, no streaming)
    // → paste straight back over the selection. On any failure (LLM error, empty
    // result) fall back to the normal popup, which surfaces errors well. An empty
    // capture just beeps (there's nothing to rewrite or fall back to).
    private async Task AutoReplace(string source)
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
            Log.Write($"autoreplace: start src={source} len={text.Length} backend={Settings.Current.Backend}");

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

// Hidden message-only window that owns the two global hotkeys: the main popup
// trigger (id 1, Ctrl+Shift+E) and the instant auto-replace trigger (id 2,
// Ctrl+Shift+R). Both are re-registered together whenever Settings changes.
public sealed class HotkeyWindow : WF.NativeWindow, IDisposable
{
    private const int WM_HOTKEY = 0x0312;
    private const int MainId = 1, InstantId = 2;
    private readonly Action _onMain;
    private readonly Action _onInstant;

    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    private static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    public HotkeyWindow(Action onMain, Action onInstant)
    {
        _onMain = onMain;
        _onInstant = onInstant;
        CreateHandle(new WF.CreateParams());
        Reregister();
    }

    public void Reregister()
    {
        var s = Settings.Current;
        Register(MainId, s.HotkeyModifiers, s.HotkeyKey, s.HotkeyDisplay, "popup");
        Register(InstantId, s.HotkeyModifiers2, s.HotkeyKey2, s.HotkeyDisplay2, "instant");
    }

    private void Register(int id, uint mods, uint vk, string display, string what)
    {
        UnregisterHotKey(Handle, id);
        if (RegisterHotKey(Handle, id, mods, vk))
        {
            Log.Write($"{what} hotkey {display} registered");
        }
        else
        {
            Log.Write($"{what} hotkey {display} FAILED to register — another app owns it");
            WF.MessageBox.Show(
                $"Another app already owns {display}, so the Cleanup {what} hotkey won't work.\n" +
                "Pick a different hotkey in Settings, or use the floating buttons.",
                "Cleanup");
        }
    }

    protected override void WndProc(ref WF.Message m)
    {
        if (m.Msg == WM_HOTKEY)
        {
            if (m.WParam.ToInt32() == InstantId) _onInstant();
            else _onMain();
        }
        base.WndProc(ref m);
    }

    public void Dispose()
    {
        UnregisterHotKey(Handle, MainId);
        UnregisterHotKey(Handle, InstantId);
        DestroyHandle();
    }
}
