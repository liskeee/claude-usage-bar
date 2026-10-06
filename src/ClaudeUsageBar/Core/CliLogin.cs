using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ClaudeUsageBar.Core;

/// The Claude Code CLI login on disk: `claudeAiOauth` in <configDir>\.credentials.json and `oauthAccount` in the
/// global config. The only code that writes Claude Code's files: it replaces those two keys, drops the
/// account-scoped caches (as `claude auth logout` does) and leaves everything else as it was.
public sealed class CliLogin(string configDir, string globalConfigPath, string? backupDir = null)
{
    const int Attempts = 3;

    /// Global config keys Claude Code removes on logout: they describe the previous account.
    public static readonly IReadOnlyList<string> AccountCaches =
    [
        "subscriptionNoticeCount", "hasAvailableSubscription", "additionalModelOptionsCache", "additionalModelOptionsAnsweredAt",
        "additionalModelCostsCache", "modelAccessCache", "orgModelDefaultCache", "cachedArtifactRoster", "artifactRosterDenied",
        "lastSeenOrgDefaultUpdatedAt", "clientDataCache", "clientDataCacheSlots", "autoCompactWindowsCache", "cachedUsageUtilization",
    ];

    static readonly JsonSerializerOptions WriteOptions = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping, // keep non-ASCII paths and names as the CLI wrote them
    };
    static readonly UTF8Encoding Utf8NoBom = new(encoderShouldEmitUTF8Identifier: false);

    /// Test hook: runs between reading a file and replacing it, where a running Claude Code session may write it.
    public Action<string>? BeforeReplace { get; init; }

    string CredentialsPath => Path.Combine(configDir, ".credentials.json");

    /// The CLI login in the user's home: ~\.claude\.credentials.json and ~\.claude.json.
    public static CliLogin Default(string backupDir)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return new(Path.Combine(home, ".claude"), Path.Combine(home, ".claude.json"), backupDir);
    }

    /// The login of a CLI run with CLAUDE_CONFIG_DIR=<dir>, which keeps its global config in <dir>\.claude.json.
    public static CliLogin ForConfigDir(string dir) => new(dir, Path.Combine(dir, ".claude.json"));

    /// Null when a file is missing or unreadable, or holds no claude.ai login.
    public AccountLogin? ReadCurrent()
    {
        try
        {
            if (Load(CredentialsPath)?.Root["claudeAiOauth"] is not JsonObject oauth) return null;
            if (Load(globalConfigPath)?.Root["oauthAccount"] is not JsonObject account) return null;
            var login = new AccountLogin(oauth, account);
            return login.Key.AccountUuid.Length > 0 ? login : null;
        }
        catch (IOException) { return null; }
    }

    /// Makes `login` the CLI's login. Throws IOException when a file can't be written; both files then keep the old login.
    public void Write(AccountLogin login)
    {
        try { Backup(); }
        catch (UnauthorizedAccessException ex) { throw new IOException(ex.Message, ex); }

        var credentialsBefore = Update(CredentialsPath, root => root["claudeAiOauth"] = login.Oauth.DeepClone());
        try
        {
            Update(globalConfigPath, root =>
            {
                root["oauthAccount"] = login.Account.DeepClone();
                foreach (var key in AccountCaches) root.Remove(key);
            });
        }
        catch (IOException)
        {
            Restore(CredentialsPath, credentialsBefore); // one account's tokens under another account's name would be worse
            throw;
        }
    }

    void Backup()
    {
        if (backupDir is null) return;
        Directory.CreateDirectory(backupDir);
        foreach (var path in new[] { CredentialsPath, globalConfigPath })
            if (File.Exists(path)) File.Copy(path, Path.Combine(backupDir, Path.GetFileName(path)), overwrite: true);
    }

    /// Read → edit → atomic replace. Running Claude Code sessions rewrite ~\.claude.json often: when the file changed
    /// after we read it, start over from its new content. Returns the file as it was before the edit (null: no file).
    FileState? Update(string path, Action<JsonObject> edit)
    {
        for (int attempt = 1; ; attempt++)
        {
            try
            {
                var before = Load(path);
                var root = before?.Root ?? new JsonObject();
                edit(root);
                var temp = WriteTemp(path, root.ToJsonString(WriteOptions));
                try
                {
                    BeforeReplace?.Invoke(path);
                    if (ChangedSince(path, before)) throw new IOException($"{Path.GetFileName(path)} changed while being updated");
                    File.Move(temp, path, overwrite: true);
                }
                finally { File.Delete(temp); }
                return before;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                Log.Write($"login: {Path.GetFileName(path)}, attempt {attempt} of {Attempts}: {ex.Message}");
                if (attempt == Attempts) throw new IOException($"{Path.GetFileName(path)} not written: {ex.Message}", ex);
                Thread.Sleep(50 * attempt);
            }
            catch (Exception ex)
            {
                // content .NET can't write back (e.g. a lone escaped surrogate Node left in a string): retrying won't help,
                // and the caller must still restore what it already wrote
                Log.Write($"login: {Path.GetFileName(path)} can't be rewritten: {ex.GetType().Name}");
                throw new IOException($"{Path.GetFileName(path)} can't be rewritten: {ex.Message}", ex);
            }
        }
    }

    void Restore(string path, FileState? before)
    {
        try
        {
            if (before is null) { File.Delete(path); return; }
            File.Move(WriteTemp(path, before.Text), path, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Write($"login: couldn't restore {Path.GetFileName(path)}: {ex.Message}");
        }
    }

    static string WriteTemp(string path, string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = $"{path}.{Guid.NewGuid():N}.tmp";
        File.WriteAllText(temp, text, Utf8NoBom);
        return temp;
    }

    static bool ChangedSince(string path, FileState? before)
    {
        var now = new FileInfo(path);
        if (before is null) return now.Exists;
        return !now.Exists || now.LastWriteTimeUtc != before.WriteTimeUtc || now.Length != before.Length;
    }

    sealed record FileState(JsonObject Root, string Text, DateTime WriteTimeUtc, long Length);

    /// Null when the file doesn't exist; IOException when it can't be read or isn't a JSON object.
    static FileState? Load(string path)
    {
        var info = new FileInfo(path); // taken before reading: a write after this point counts as a change
        if (!info.Exists) return null;
        try
        {
            string text;
            // the CLI rewrites these files at any time; share everything so we never block it
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (var reader = new StreamReader(stream, Encoding.UTF8))
                text = reader.ReadToEnd();
            var root = JsonNode.Parse(text) as JsonObject ?? throw new JsonException("not a JSON object");
            return new FileState(root, text, info.LastWriteTimeUtc, info.Length);
        }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
        catch (JsonException ex) { throw new IOException($"{Path.GetFileName(path)} is not valid JSON", ex); }
        catch (UnauthorizedAccessException ex) { throw new IOException(ex.Message, ex); }
    }
}
