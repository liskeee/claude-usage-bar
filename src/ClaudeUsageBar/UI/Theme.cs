using ClaudeUsageBar.Core;
using Microsoft.Win32;

namespace ClaudeUsageBar.UI;

public sealed record Palette(Color Text, Color Muted, Color Track, Color Ok, Color Warn, Color Critical, Color Clay, Color Surface, Color Border, Color Accent);

public static class Theme
{
    public static readonly Palette Dark = new(
        Text: Color.White, Muted: Color.FromArgb(165, 255, 255, 255), Track: Color.FromArgb(55, 255, 255, 255),
        Ok: Color.FromArgb(108, 203, 95), Warn: Color.FromArgb(255, 185, 0), Critical: Color.FromArgb(255, 107, 107),
        Clay: Color.FromArgb(217, 119, 87), Surface: Color.FromArgb(44, 44, 44), Border: Color.FromArgb(64, 64, 64),
        Accent: Color.FromArgb(96, 205, 255));

    public static readonly Palette Light = new(
        Text: Color.FromArgb(26, 26, 26), Muted: Color.FromArgb(160, 0, 0, 0), Track: Color.FromArgb(40, 0, 0, 0),
        Ok: Color.FromArgb(15, 123, 15), Warn: Color.FromArgb(157, 93, 0), Critical: Color.FromArgb(196, 43, 28),
        Clay: Color.FromArgb(193, 95, 60), Surface: Color.FromArgb(249, 249, 249), Border: Color.FromArgb(229, 229, 229),
        Accent: Color.FromArgb(0, 95, 184));

    /// Taskbar and system flyouts follow "Windows mode", not the app mode.
    public static bool IsDarkTaskbar() =>
        Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "SystemUsesLightTheme", 0)
            is not int light || light == 0;

    public static Palette Current => IsDarkTaskbar() ? Dark : Light;

    public static Color SeverityColor(Palette p, double used) => Format.SeverityOf(used) switch
    {
        Severity.Ok => p.Ok,
        Severity.Warn => p.Warn,
        _ => p.Critical,
    };

    // numbers stay neutral for contrast until the limit needs attention
    public static Color NumberColor(Palette p, double used) =>
        Format.SeverityOf(used) == Severity.Ok ? p.Text : SeverityColor(p, used);
}
