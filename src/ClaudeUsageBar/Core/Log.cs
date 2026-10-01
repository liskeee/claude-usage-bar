namespace ClaudeUsageBar.Core;

/// Small append-only log (%LOCALAPPDATA%\ClaudeUsageBar\log.txt). Never pass tokens here.
public static class Log
{
    const long MaxBytes = 256 * 1024;
    static readonly Lock Sync = new();

    public static string? FilePath { get; set; }

    public static void Write(string message)
    {
        if (FilePath is null) return;
        lock (Sync)
        {
            try
            {
                var file = new FileInfo(FilePath);
                if (file.Exists && file.Length > MaxBytes) File.Move(FilePath, FilePath + ".old", overwrite: true);
                File.AppendAllText(FilePath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {message}{Environment.NewLine}");
            }
            catch (IOException) { }
        }
    }
}
