using ClaudeUsageBar.Core;

namespace ClaudeUsageBar.Tests;

static class Fixtures
{
    /// Real /api/oauth/usage response captured on 2026-10-01 13:41 (no secrets inside).
    public static string Usage => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "usage-2026-10-01.json"));
}

sealed class FakeClock(DateTimeOffset now) : TimeProvider
{
    public DateTimeOffset Now { get; set; } = now;
    public override DateTimeOffset GetUtcNow() => Now.ToUniversalTime();
}

sealed class FakeCreds : ICredentialStore
{
    public Credentials? Current { get; set; }
    public Credentials? Read() => Current;
}

sealed class FakeRenewer : ITokenRenewer
{
    public int Calls { get; private set; }
    public Func<bool> OnRenew { get; set; } = () => false;

    public Task<bool> TryRenewAsync(CancellationToken ct)
    {
        Calls++;
        return Task.FromResult(OnRenew());
    }
}

sealed class FakeApi : IUsageApi
{
    public List<string> Tokens { get; } = [];
    public Func<string, UsageApiResult> Respond { get; set; } = _ => new(ApiStatus.Ok, Fixtures.Usage);

    public Task<UsageApiResult> FetchAsync(string accessToken, CancellationToken ct)
    {
        Tokens.Add(accessToken);
        return Task.FromResult(Respond(accessToken));
    }
}
