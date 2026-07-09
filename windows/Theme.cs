using System.Windows.Media;
using Microsoft.Win32;

namespace Cleanup;

// Mono palette — locked visual spec: zero hue, dark/light pair.
public class Theme
{
    public required Brush Surface, Surface2, Surface3, Line, LineStrong, Text, Muted, Faint, Accent, OnAccent;
    // Diff-only colours — the single sanctioned exception to the zero-hue rule.
    // GitHub-style muted red/green, used exclusively inside the diff viewer
    // (inline panel + pop-out). Everything else in the app stays mono.
    public required Brush DiffAddText, DiffAddBg, DiffDelText, DiffDelBg;

    private static Brush B(byte r, byte g, byte b) =>
        new SolidColorBrush(Color.FromRgb(r, g, b));
    private static Brush A(byte a, byte r, byte g, byte b) =>
        new SolidColorBrush(Color.FromArgb(a, r, g, b));

    public static readonly Theme Dark = new()
    {
        Surface = B(0x1C, 0x1C, 0x1C), Surface2 = B(0x26, 0x26, 0x26), Surface3 = B(0x30, 0x30, 0x30),
        Line = A(26, 255, 255, 255), LineStrong = A(51, 255, 255, 255),
        Text = B(0xF2, 0xF2, 0xF2), Muted = B(0x9E, 0x9E, 0x9E), Faint = B(0x6E, 0x6E, 0x6E),
        Accent = B(0xF2, 0xF2, 0xF2), OnAccent = B(0x11, 0x11, 0x11),
        // GitHub-dark diff palette: soft red/green text on ~25% tinted fills.
        DiffAddText = B(0x85, 0xE8, 0x9D), DiffAddBg = A(64, 0x1F, 0x6F, 0x3A),
        DiffDelText = B(0xF9, 0x75, 0x83), DiffDelBg = A(64, 0x8B, 0x1E, 0x2B),
    };

    public static readonly Theme Light = new()
    {
        Surface = B(0xFC, 0xFC, 0xFB), Surface2 = B(0xF1, 0xF1, 0xEF), Surface3 = B(0xE4, 0xE4, 0xE1),
        Line = A(23, 0, 0, 0), LineStrong = A(46, 0, 0, 0),
        Text = B(0x1A, 0x1A, 0x18), Muted = B(0x5F, 0x5F, 0x5C), Faint = B(0x93, 0x93, 0x8F),
        Accent = B(0x1A, 0x1A, 0x18), OnAccent = B(0xFC, 0xFC, 0xFB),
        // GitHub-light diff palette: deep red/green text on pale tinted fills.
        DiffAddText = B(0x22, 0x86, 0x3A), DiffAddBg = B(0xE6, 0xFF, 0xED),
        DiffDelText = B(0xCB, 0x24, 0x31), DiffDelBg = B(0xFF, 0xEE, 0xF0),
    };

    public static Theme Detect()
    {
        try
        {
            var v = Registry.GetValue(
                @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                "AppsUseLightTheme", 1);
            return (v is int i && i == 0) ? Dark : Light;
        }
        catch { return Light; }
    }
}
