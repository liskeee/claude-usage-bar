using System.Runtime.InteropServices;
using ClaudeUsageBar.Core;

namespace ClaudeUsageBar.UI;

/// Start with Windows through a shortcut in the user's Startup folder.
public static class Autostart
{
    static string ShortcutPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "ClaudeUsageBar.lnk");

    public static bool IsEnabled => File.Exists(ShortcutPath);

    public static void Enable(string exePath, string description)
    {
        var shellType = Type.GetTypeFromProgID("WScript.Shell") ?? throw new InvalidOperationException("WScript.Shell is not available");
        dynamic shell = Activator.CreateInstance(shellType)!;
        try
        {
            dynamic link = shell.CreateShortcut(ShortcutPath);
            link.TargetPath = exePath;
            link.WorkingDirectory = Path.GetDirectoryName(exePath);
            link.Description = description;
            link.Save();
        }
        finally { Marshal.FinalReleaseComObject(shell); }
    }

    public static void Disable() => File.Delete(ShortcutPath);

    /// Turns autostart on only on the very first run; afterwards the menu decides.
    public static void EnableOnFirstRun(string exePath, string dataDir, string description)
    {
        var marker = Path.Combine(dataDir, "first-run.done");
        if (File.Exists(marker)) return;
        try
        {
            Enable(exePath, description);
            Log.Write("autostart enabled (first run)");
        }
        catch (Exception ex) { Log.Write($"autostart failed: {ex.Message}"); }
        File.WriteAllText(marker, DateTimeOffset.Now.ToString("O"));
    }
}
