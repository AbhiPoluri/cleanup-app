using System;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows;

namespace Cleanup;

// Selection capture via simulated Ctrl+C (clipboard restored), and
// replace via refocus + simulated Ctrl+V.
public static class Capture
{
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    private const byte VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_C = 0x43, VK_E = 0x45, VK_V = 0x56;
    private const uint KEYEVENTF_KEYUP = 0x0002;

    private static void KeyDown(byte vk) => keybd_event(vk, 0, 0, UIntPtr.Zero);
    private static void KeyUp(byte vk) => keybd_event(vk, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);

    private static void SendCtrlCombo(byte vk)
    {
        // lift any physically held modifiers/keys from the hotkey chord first,
        // so Ctrl+Shift+E doesn't turn our Ctrl+C into Ctrl+Shift+C
        KeyUp(VK_E); KeyUp(VK_SHIFT); KeyUp(VK_MENU); KeyUp(VK_CONTROL);
        KeyDown(VK_CONTROL);
        KeyDown(vk);
        KeyUp(vk);
        KeyUp(VK_CONTROL);
    }

    private static string? TryGetText()
    {
        try { return Clipboard.ContainsText() ? Clipboard.GetText() : null; }
        catch { return null; }
    }

    private static void TrySetText(string? text)
    {
        try
        {
            if (text == null) Clipboard.Clear();
            else Clipboard.SetText(text);
        }
        catch { }
    }

    public static async Task<(string? Text, IntPtr Hwnd)> GrabSelection()
    {
        var hwnd = GetForegroundWindow();
        var saved = TryGetText();
        SendCtrlCombo(VK_C);
        await Task.Delay(300);
        var captured = TryGetText();
        TrySetText(saved); // put the user's clipboard back immediately
        if (string.IsNullOrWhiteSpace(captured) || captured == saved)
            return (null, hwnd);
        return (captured, hwnd);
    }

    public static async Task PasteInto(IntPtr hwnd, string text)
    {
        var saved = TryGetText();
        if (hwnd != IntPtr.Zero) SetForegroundWindow(hwnd);
        await Task.Delay(250);
        TrySetText(text);
        await Task.Delay(100);
        SendCtrlCombo(VK_V);
        await Task.Delay(600);
        TrySetText(saved);
    }
}
