using System.ComponentModel;
using System.Diagnostics;

namespace ClaudeUsageBar.Core;

public interface ITokenRenewer
{
    /// Asks the official CLI to refresh its login; false when throttled, missing or failed.
    Task<bool> TryRenewAsync(CancellationToken ct);
}

/// Renews the Claude Code login with one tiny `claude -p` call: the CLI refreshes its own token file.
public sealed class CliTokenRenewer(TimeProvider clock, Func<CancellationToken, Task<bool>> runCli) : ITokenRenewer
{
    public static readonly TimeSpan MinInterval = TimeSpan.FromMinutes(30);
    static readonly TimeSpan RunTimeout = TimeSpan.FromSeconds(90);
    static readonly string[] Arguments = ["-p", "ok", "--model", "haiku", "--safe-mode", "--no-session-persistence"];

    DateTimeOffset? lastAttempt;

    public async Task<bool> TryRenewAsync(CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        if (lastAttempt is { } last && now - last < MinInterval) return false;
        lastAttempt = now;
        return await runCli(ct);
    }

    public static CliTokenRenewer CreateDefault(string workDir) => new(TimeProvider.System, ct => RunClaudeAsync(workDir, ct));

    public static string? FindClaude()
    {
        var dirs = (Environment.GetEnvironmentVariable("PATH") ?? "")
            .Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Append(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Microsoft", "WinGet", "Links"))
            .Append(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".local", "bin"));
        foreach (var dir in dirs)
        {
            try
            {
                var candidate = Path.Combine(dir, "claude.exe");
                if (File.Exists(candidate)) return candidate;
            }
            catch (ArgumentException) { } // malformed PATH entry
        }
        return null;
    }

    static async Task<bool> RunClaudeAsync(string workDir, CancellationToken ct)
    {
        if (FindClaude() is not { } exe) { Log.Write("renew: claude.exe not found"); return false; }
        Directory.CreateDirectory(workDir);
        var psi = new ProcessStartInfo(exe)
        {
            WorkingDirectory = workDir,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var arg in Arguments) psi.ArgumentList.Add(arg);
        // never inherit auth or proxy settings from a Claude session that happened to start us
        foreach (var key in psi.Environment.Keys.Where(k =>
                     k.StartsWith("CLAUDE", StringComparison.OrdinalIgnoreCase) ||
                     k.StartsWith("ANTHROPIC", StringComparison.OrdinalIgnoreCase)).ToList())
            psi.Environment.Remove(key);

        Process? process;
        try { process = Process.Start(psi); }
        catch (Win32Exception ex) { Log.Write($"renew: cannot start claude: {ex.Message}"); return false; }
        if (process is null) return false;

        using (process)
        using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct))
        {
            timeout.CancelAfter(RunTimeout);
            process.StandardInput.Close();
            try
            {
                var stdout = process.StandardOutput.ReadToEndAsync(timeout.Token);
                var stderr = process.StandardError.ReadToEndAsync(timeout.Token);
                await process.WaitForExitAsync(timeout.Token);
                await Task.WhenAll(stdout, stderr);
                Log.Write($"renew: claude exited with {process.ExitCode}");
                return process.ExitCode == 0;
            }
            catch (OperationCanceledException)
            {
                try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
                Log.Write("renew: claude timed out");
                return false;
            }
        }
    }
}
