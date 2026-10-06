using System.ComponentModel;
using System.Diagnostics;
using System.Text.RegularExpressions;

namespace ClaudeUsageBar.Core;

/// Runs `claude auth login` for a new account in its own console window, isolated with CLAUDE_CONFIG_DIR=<dir>,
/// so the user's current login is never touched.
public static class LoginRunner
{
    public const string WindowTitle = "ClaudeUsageBar: add account";
    const string CmdSpecial = "&|<>^%\"";
    // anything cmd.exe would interpret is not passed; the user then types the address in the browser
    static readonly Regex PlainEmail = new(@"^[A-Za-z0-9._+\-]+@[A-Za-z0-9.\-]+$");

    /// cmd.exe arguments: UTF-8 console (for translated hints), window title, hint, then the login.
    /// cmd /c returns the exit code of its last command: claude's.
    public static string CommandLine(string claudeExe, string? email, string hint)
    {
        var login = $"\"{claudeExe}\" auth login";
        if (email is not null && PlainEmail.IsMatch(email)) login += $" --email {email}";
        var safeHint = new string(hint.Where(c => !CmdSpecial.Contains(c)).ToArray());
        return $"/d /s /c \"chcp 65001 >nul & title {WindowTitle} & echo {safeHint} & echo. & {login}\"";
    }

    /// True when the login finished; false when it failed or the window was closed.
    public static async Task<bool> RunAsync(string hint, string? email, string configDir, CancellationToken ct)
    {
        var exe = CliTokenRenewer.FindClaude() ?? throw new AccountException(AccountError.ClaudeNotFound, "claude.exe not found");
        var psi = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "cmd.exe"), CommandLine(exe, email, hint))
        {
            UseShellExecute = false,
            CreateNoWindow = false, // we have no console: cmd gets a window of its own
            WorkingDirectory = configDir,
        };
        CliTokenRenewer.ClearClaudeEnvironment(psi);
        psi.Environment["CLAUDE_CONFIG_DIR"] = configDir;

        Process? process;
        try { process = Process.Start(psi); }
        catch (Win32Exception ex) { throw new AccountException(AccountError.LoginFailed, $"cannot start cmd.exe: {ex.Message}", ex); }
        if (process is null) throw new AccountException(AccountError.LoginFailed, "cmd.exe did not start");

        using (process)
        {
            int exitCode = await RunToExitAsync(process, ct);
            Log.Write($"login: claude auth login exited with {exitCode}");
            return exitCode == 0;
        }
    }

    /// Waits for the login window to close; cancelling closes it at once, inside Cancel(): on app exit nothing
    /// posted to the UI thread afterwards runs, and the window would outlive the app.
    public static async Task<int> RunToExitAsync(Process process, CancellationToken ct)
    {
        using (ct.Register(() =>
               {
                   try { process.Kill(entireProcessTree: true); }
                   catch (Exception ex) when (ex is InvalidOperationException or Win32Exception) { } // already gone
               }))
            await process.WaitForExitAsync(ct);
        return process.ExitCode;
    }
}
