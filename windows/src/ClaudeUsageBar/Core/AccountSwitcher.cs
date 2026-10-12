namespace ClaudeUsageBar.Core;

public enum AccountError { ClaudeNotFound, LoginFailed, WriteFailed }

/// A user action on accounts that failed; the active login is unchanged.
public sealed class AccountException(AccountError error, string message, Exception? inner = null) : Exception(message, inner)
{
    public AccountError Error { get; } = error;
}

/// Saved accounts ↔ the Claude Code CLI login: captures the active login, switches to a saved one, adds new ones.
/// `cliLock` is shared with the token renewer: a `claude -p` refresh must never write the old account's tokens
/// over a login that was just switched to.
public sealed class AccountSwitcher(
    CliLogin cli,
    AccountStore store,
    SemaphoreSlim cliLock,
    string loginRoot,
    Func<string?, string, CancellationToken, Task<bool>> runLogin,
    TimeProvider clock)
{
    AccountKey? lastSeen; // the last account read from the CLI; null until the first read

    public AccountLogin? Active { get; private set; }
    public bool IsLoginRunning { get; private set; }
    public IReadOnlyList<SavedAccount> Accounts => store.All;

    /// The CLI now has another login (or a fresh one); everything shown for the previous one is stale.
    public event Action? Switched;

    /// Reads the active CLI login and saves it when it is new or changed: token rotation, `/login` by hand.
    /// Another account signed in by hand raises Switched, like a switch from the menu.
    public void Sync()
    {
        Active = cli.ReadCurrent();
        if (Active is null) return;
        bool switchedByHand = lastSeen is { } before && before != Active.Key;
        lastSeen = Active.Key;
        Save(Active);
        if (switchedByHand)
        {
            Log.Write($"accounts: signed in by hand as {Active}");
            Switched?.Invoke();
        }
    }

    void Save(AccountLogin login)
    {
        if (store.Find(login.Key) is { } saved && saved.Login.SameAs(login)) return;
        // another saved account's refresh token under this name is a half-written pair, not a new login: saving it
        // would replace this account's real tokens
        if (login.RefreshToken is { } token && store.All.Any(s => s.Key != login.Key && s.Login.RefreshToken == token))
        {
            Log.Write($"accounts: {login} carries another account's tokens, not saved");
            return;
        }
        store.Upsert(new SavedAccount(login, clock.GetUtcNow()));
        Log.Write($"accounts: saved {login}");
    }

    public async Task SwitchToAsync(AccountKey key, CancellationToken ct = default)
    {
        await cliLock.WaitAsync(ct);
        try
        {
            Sync(); // the account being left may have rotated its tokens since the last sync
            if (Active?.Key == key) return;
            var target = store.Find(key) ?? throw new InvalidOperationException($"No saved account {key}");
            Apply(target.Login);
        }
        finally { cliLock.Release(); }
    }

    /// Signs in with `claude auth login` in a throwaway CLAUDE_CONFIG_DIR, so the current login is never signed out,
    /// then saves the new login and switches to it. `email` pre-fills the login page (for "sign in again").
    public async Task AddAccountAsync(string? email, CancellationToken ct = default)
    {
        if (IsLoginRunning) return;
        IsLoginRunning = true;
        var dir = Path.Combine(loginRoot, $"login-{Guid.NewGuid():N}");
        try
        {
            RemoveLeftoverLoginDirs();
            Directory.CreateDirectory(dir);
            if (!await runLogin(email, dir, ct))
                throw new AccountException(AccountError.LoginFailed, "claude auth login failed or was closed");
            var login = CliLogin.ForConfigDir(dir).ReadCurrent()
                ?? throw new AccountException(AccountError.LoginFailed, "claude auth login left no login");
            await cliLock.WaitAsync(ct);
            try
            {
                Sync(); // after the login, not before: the account being left may have rotated its tokens meanwhile
                var saved = new SavedAccount(login, clock.GetUtcNow());
                if (Active?.Key == login.Key)
                {
                    // a fresh login of the active account replaces its dead tokens; store it only once the CLI has it,
                    // or the next Sync would put the dead tokens back over it anyway
                    Apply(login);
                    store.Upsert(saved);
                }
                else
                {
                    store.Upsert(saved);
                    Apply(login);
                }
            }
            finally { cliLock.Release(); }
        }
        finally
        {
            DeleteDir(dir); // it holds live tokens
            IsLoginRunning = false;
        }
    }

    /// Forgets a saved account. No server call: its login stays valid wherever else it is used.
    public void Remove(AccountKey key)
    {
        Sync();
        if (Active?.Key == key) throw new InvalidOperationException("The active account can't be removed");
        store.Remove(key);
        Log.Write($"accounts: removed {key}");
    }

    void Apply(AccountLogin login)
    {
        try { cli.Write(login); }
        catch (Exception ex) { throw new AccountException(AccountError.WriteFailed, ex.Message, ex); }
        Active = cli.ReadCurrent();
        lastSeen = Active?.Key ?? lastSeen;
        Log.Write($"accounts: switched to {login}");
        Switched?.Invoke();
        if (Active?.Key != login.Key)
            throw new AccountException(AccountError.WriteFailed, $"CLI login reads back as {Active?.ToString() ?? "nothing"}");
    }

    // a login dir left by a crash or a kill still holds tokens; only one login runs at a time, so none is in use
    void RemoveLeftoverLoginDirs()
    {
        if (!Directory.Exists(loginRoot)) return;
        foreach (var dir in Directory.GetDirectories(loginRoot, "login-*")) DeleteDir(dir);
    }

    static void DeleteDir(string dir)
    {
        try { if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Write($"accounts: can't delete {Path.GetFileName(dir)}: {ex.Message}");
        }
    }
}
