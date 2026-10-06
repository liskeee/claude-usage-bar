using ClaudeUsageBar.Core;

namespace ClaudeUsageBar.Tests;

public sealed class AccountSwitcherTests : IDisposable
{
    static readonly DateTimeOffset Now = new(2026, 10, 6, 12, 0, 0, TimeSpan.Zero);

    readonly TempDir temp = new();
    readonly FakeClock clock = new(Now);
    readonly SemaphoreSlim cliLock = new(1, 1);
    readonly AccountStore store;
    readonly AccountLogin a = Logins.Make("a", "a@example.com");
    readonly AccountLogin b = Logins.Make("b", "b@example.com");
    readonly List<(string? Email, string Dir)> logins = [];
    Func<string, Task<bool>> login = _ => Task.FromResult(false); // what the fake `claude auth login` does in its dir
    int switched;

    public AccountSwitcherTests() => store = new AccountStore(temp["data/accounts.dat"]);

    public void Dispose() => temp.Dispose();

    string HomeClaude => temp["home/.claude"];
    string HomeConfig => temp["home/.claude.json"];
    string CredentialsPath => Path.Combine(HomeClaude, ".credentials.json");
    string DataDir => temp["data"];
    CliLogin Cli => new(HomeClaude, HomeConfig, temp["data/backup"]);
    AccountLogin? CliNow => Cli.ReadCurrent();

    AccountSwitcher Create()
    {
        var switcher = new AccountSwitcher(Cli, store, cliLock, DataDir, (email, dir, ct) =>
        {
            logins.Add((email, dir));
            return login(dir);
        }, clock);
        switcher.Switched += () => switched++;
        return switcher;
    }

    void SignInCli(AccountLogin account) => Logins.WriteCli(HomeClaude, HomeConfig, account);

    static Func<string, Task<bool>> LogsIn(AccountLogin account) => dir =>
    {
        Logins.WriteCli(dir, Path.Combine(dir, ".claude.json"), account);
        return Task.FromResult(true);
    };

    [Fact]
    public void Sync_SavesAnAccountSignedInByHand()
    {
        SignInCli(a);
        var switcher = Create();

        switcher.Sync();

        Assert.Equal(a.Key, switcher.Active?.Key);
        Assert.True(Assert.Single(store.All).Login.SameAs(a));
    }

    [Fact]
    public void Sync_UnchangedLogin_KeepsTheSavedCopy()
    {
        SignInCli(a);
        var switcher = Create();
        switcher.Sync();
        clock.Now = Now.AddMinutes(5);

        switcher.Sync();

        Assert.Equal(Now, Assert.Single(store.All).SavedAt);
    }

    [Fact]
    public void Sync_RotatedTokens_UpdateTheSavedCopy()
    {
        SignInCli(a);
        var switcher = Create();
        switcher.Sync();
        SignInCli(Logins.Make("a", "a@example.com", token: "2")); // the CLI refreshed its token

        switcher.Sync();

        Assert.Equal("access-a-2", Logins.AccessToken(Assert.Single(store.All).Login));
    }

    [Fact]
    public void Sync_SignedOut_SavesNothing()
    {
        var switcher = Create();

        switcher.Sync();

        Assert.Null(switcher.Active);
        Assert.Empty(store.All);
    }

    [Fact]
    public async Task SwitchTo_WritesTheTarget_AndKeepsTheLatestTokensOfTheAccountLeft()
    {
        store.Upsert(new SavedAccount(b, Now));
        SignInCli(a);
        var switcher = Create();
        switcher.Sync();
        SignInCli(Logins.Make("a", "a@example.com", token: "2")); // rotated after the last sync

        await switcher.SwitchToAsync(b.Key);

        Assert.True(CliNow!.SameAs(b));
        Assert.Equal(b.Key, switcher.Active?.Key);
        Assert.Equal("access-a-2", Logins.AccessToken(store.Find(a.Key)!.Login));
        Assert.Equal(1, switched);
    }

    [Fact]
    public async Task SwitchTo_TheActiveAccount_ChangesNothing()
    {
        SignInCli(a);
        var switcher = Create();
        var config = File.ReadAllText(HomeConfig);

        await switcher.SwitchToAsync(a.Key);

        Assert.Equal(config, File.ReadAllText(HomeConfig));
        Assert.Equal(0, switched);
    }

    [Fact]
    public async Task SwitchTo_WaitsWhileTheCliIsRenewingItsToken()
    {
        store.Upsert(new SavedAccount(b, Now));
        SignInCli(a);
        var switcher = Create();
        await cliLock.WaitAsync(); // a `claude -p` renewal is running

        var switching = switcher.SwitchToAsync(b.Key);
        Assert.False(switching.IsCompleted);
        Assert.True(CliNow!.SameAs(a));

        cliLock.Release();
        await switching;
        Assert.True(CliNow!.SameAs(b));
        Assert.Equal(1, cliLock.CurrentCount);
    }

    [Fact]
    public async Task SwitchTo_UnwritableConfig_FailsAndKeepsTheActiveAccount()
    {
        store.Upsert(new SavedAccount(b, Now));
        SignInCli(a);
        var switcher = Create();
        switcher.Sync();
        File.WriteAllText(HomeConfig, "{damaged");
        var credentials = File.ReadAllText(CredentialsPath);

        var ex = await Assert.ThrowsAsync<AccountException>(() => switcher.SwitchToAsync(b.Key));

        Assert.Equal(AccountError.WriteFailed, ex.Error);
        Assert.Equal(credentials, File.ReadAllText(CredentialsPath));
        Assert.Equal(0, switched);
        Assert.Equal(1, cliLock.CurrentCount);
    }

    [Fact]
    public async Task AddAccount_SignsInIsolated_SavesTheAccount_AndSwitchesToIt()
    {
        SignInCli(a);
        login = dir =>
        {
            Assert.True(CliNow!.SameAs(a)); // the user's own login stays untouched while signing in
            return LogsIn(b)(dir);
        };
        var switcher = Create();

        await switcher.AddAccountAsync(null);

        var (email, dir) = Assert.Single(logins);
        Assert.Null(email);
        Assert.StartsWith(Path.Combine(DataDir, "login-"), dir);
        Assert.False(Directory.Exists(dir));
        Assert.True(CliNow!.SameAs(b));
        Assert.NotNull(store.Find(a.Key));
        Assert.NotNull(store.Find(b.Key));
        Assert.Equal(1, switched);
        Assert.False(switcher.IsLoginRunning);
    }

    [Fact]
    public async Task AddAccount_LoginFailedOrClosed_ChangesNothing()
    {
        SignInCli(a);
        login = _ => Task.FromResult(false);
        var switcher = Create();

        var ex = await Assert.ThrowsAsync<AccountException>(() => switcher.AddAccountAsync(null));

        Assert.Equal(AccountError.LoginFailed, ex.Error);
        Assert.True(CliNow!.SameAs(a));
        Assert.False(Directory.Exists(Assert.Single(logins).Dir));
        Assert.Equal(0, switched);
        Assert.False(switcher.IsLoginRunning);
    }

    [Fact]
    public async Task AddAccount_ExitedWithoutALogin_IsAFailedLogin()
    {
        SignInCli(a);
        login = _ => Task.FromResult(true);

        var ex = await Assert.ThrowsAsync<AccountException>(() => Create().AddAccountAsync(null));

        Assert.Equal(AccountError.LoginFailed, ex.Error);
        Assert.True(CliNow!.SameAs(a));
    }

    [Fact]
    public async Task AddAccount_Cancelled_RemovesTheTempDir()
    {
        login = _ => Task.FromCanceled<bool>(new CancellationToken(canceled: true));
        var switcher = Create();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => switcher.AddAccountAsync(null));

        Assert.False(Directory.Exists(Assert.Single(logins).Dir));
        Assert.False(switcher.IsLoginRunning);
    }

    [Fact]
    public async Task AddAccount_FreshLoginOfTheActiveAccount_ReplacesItsDeadTokens()
    {
        SignInCli(a);
        var switcher = Create();
        switcher.Sync();
        login = LogsIn(Logins.Make("a", "a@example.com", token: "9"));

        await switcher.AddAccountAsync("a@example.com");

        Assert.Equal("a@example.com", Assert.Single(logins).Email);
        Assert.Equal("access-a-9", Logins.AccessToken(CliNow!));
        Assert.Equal("access-a-9", Logins.AccessToken(Assert.Single(store.All).Login));
        Assert.Equal(1, switched);
    }

    [Fact]
    public async Task AddAccount_FreshLoginOfASavedAccount_RefreshesItAndSwitches()
    {
        store.Upsert(new SavedAccount(Logins.Make("b", "b@example.com", refreshExpires: Now.AddDays(-1)), Now.AddDays(-31)));
        SignInCli(a);
        login = LogsIn(Logins.Make("b", "b@example.com", token: "9"));

        await Create().AddAccountAsync("b@example.com");

        Assert.Equal("access-b-9", Logins.AccessToken(store.Find(b.Key)!.Login));
        Assert.Equal("access-b-9", Logins.AccessToken(CliNow!));
        Assert.NotNull(store.Find(a.Key)); // captured on the way out
    }

    [Fact]
    public async Task AddAccount_OnlyOneLoginAtATime()
    {
        var finish = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        login = dir => { LogsIn(b)(dir); return finish.Task; };
        var switcher = Create();

        var first = switcher.AddAccountAsync(null);
        Assert.True(switcher.IsLoginRunning);
        await switcher.AddAccountAsync(null); // ignored: returns at once
        finish.SetResult(true);
        await first;

        Assert.Single(logins);
        Assert.False(switcher.IsLoginRunning);
    }

    [Fact]
    public async Task AddAccount_RemovesLoginDirsLeftByAnEarlierCrash()
    {
        var leftover = Path.Combine(DataDir, "login-0123");
        Directory.CreateDirectory(leftover);
        File.WriteAllText(Path.Combine(leftover, ".credentials.json"), "{}");

        await Assert.ThrowsAsync<AccountException>(() => Create().AddAccountAsync(null));

        Assert.False(Directory.Exists(leftover));
    }

    [Fact]
    public void Remove_InactiveAccount_ForgetsIt_WithoutTouchingTheCli()
    {
        store.Upsert(new SavedAccount(b, Now));
        SignInCli(a);
        var switcher = Create();
        var credentials = File.ReadAllText(CredentialsPath);
        var config = File.ReadAllText(HomeConfig);

        switcher.Remove(b.Key);

        Assert.Null(store.Find(b.Key));
        Assert.Equal(credentials, File.ReadAllText(CredentialsPath));
        Assert.Equal(config, File.ReadAllText(HomeConfig));
    }

    [Fact]
    public void Remove_ActiveAccount_IsRefused()
    {
        SignInCli(a);
        var switcher = Create();

        Assert.Throws<InvalidOperationException>(() => switcher.Remove(a.Key));

        Assert.NotNull(store.Find(a.Key));
    }
}
