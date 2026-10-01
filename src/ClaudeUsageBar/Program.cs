using System.Globalization;
using ClaudeUsageBar.Core;
using ClaudeUsageBar.UI;

namespace ClaudeUsageBar;

static class Program
{
    [STAThread]
    static void Main()
    {
        using var mutex = new Mutex(initiallyOwned: true, @"Local\ClaudeUsageBar.SingleInstance", out bool isFirstInstance);
        if (!isFirstInstance) return;

        var dataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "ClaudeUsageBar");
        Directory.CreateDirectory(dataDir);
        Log.FilePath = Path.Combine(dataDir, "log.txt");
        Log.Write($"start {Environment.ProcessPath}");

        ApplicationConfiguration.Initialize();
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += (_, e) => Log.Write($"ui error: {e.Exception}");
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Log.Write($"fatal: {e.ExceptionObject}");
        // async continuations (refresh, CLI renewal) must come back to the UI thread
        SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());

        // the Windows display language, if there is a translation for it; English otherwise
        var texts = Texts.ForCulture(CultureInfo.CurrentUICulture);
        Log.Write($"language: {CultureInfo.CurrentUICulture.Name} (available: {string.Join(", ", Texts.Available)})");
        if (Environment.ProcessPath is { } exe) Autostart.EnableOnFirstRun(exe, dataDir, texts.AutostartDescription);

        var service = new UsageService(
            new FileCredentialStore(FileCredentialStore.DefaultPath),
            new HttpUsageApi(),
            CliTokenRenewer.CreateDefault(Path.Combine(dataDir, "work")),
            TimeProvider.System);
        Application.Run(new App(service, texts));
        Log.Write("exit");
    }
}
