using ClaudeUsageBar.Core;

namespace ClaudeUsageBar.Tests;

public class UsageServiceTests
{
    static readonly DateTimeOffset Now = new(2026, 10, 1, 14, 0, 0, TimeSpan.FromHours(2));

    readonly FakeCreds creds = new();
    readonly FakeApi api = new();
    readonly FakeRenewer renewer = new();
    readonly FakeClock clock = new(Now);

    static Credentials Valid(string token = "token-a") => new(token, Now.AddHours(2), "max", "default_claude_max_20x");
    static Credentials Expired(string token = "token-old") => new(token, Now.AddHours(-1), "max", "default_claude_max_20x");

    UsageService Create() => new(creds, api, renewer, clock);

    [Fact]
    public async Task ValidToken_FetchesUsage_WithoutRenewing()
    {
        creds.Current = Valid();
        var service = Create();

        await service.RefreshAsync();

        Assert.Equal(ServiceStatus.Ok, service.State.Status);
        Assert.Equal(26, service.State.Snapshot!.Session!.UsedPercent);
        Assert.Equal("Max 20x", service.State.PlanName);
        Assert.Equal(Now, service.State.LastSuccess);
        Assert.Equal(0, renewer.Calls);
        Assert.Equal(new[] { "token-a" }, api.Tokens);
    }

    [Fact]
    public async Task ExpiredToken_RenewsThenFetchesWithNewToken()
    {
        creds.Current = Expired();
        renewer.OnRenew = () => { creds.Current = Valid("token-new"); return true; };
        var service = Create();

        await service.RefreshAsync();

        Assert.Equal(ServiceStatus.Ok, service.State.Status);
        Assert.Equal(1, renewer.Calls);
        Assert.Equal(new[] { "token-new" }, api.Tokens);
    }

    [Fact]
    public async Task ExpiredToken_RenewFails_NeedsLogin_WithoutCallingApi()
    {
        creds.Current = Expired();
        var service = Create();

        await service.RefreshAsync();

        Assert.Equal(ServiceStatus.NeedsLogin, service.State.Status);
        Assert.Empty(api.Tokens);
    }

    [Fact]
    public async Task MissingLoginFile_TriesToRenew_ThenNeedsLogin()
    {
        var service = Create();

        await service.RefreshAsync();

        Assert.Equal(ServiceStatus.NeedsLogin, service.State.Status);
        Assert.Equal(1, renewer.Calls);
    }

    [Fact]
    public async Task Unauthorized_RenewsAndRetriesOnce()
    {
        creds.Current = Valid("token-revoked");
        api.Respond = t => t == "token-revoked" ? new(ApiStatus.Unauthorized, Error: "HTTP 401") : new(ApiStatus.Ok, Fixtures.Usage);
        renewer.OnRenew = () => { creds.Current = Valid("token-new"); return true; };
        var service = Create();

        await service.RefreshAsync();

        Assert.Equal(ServiceStatus.Ok, service.State.Status);
        Assert.Equal(new[] { "token-revoked", "token-new" }, api.Tokens);
    }

    [Fact]
    public async Task UnauthorizedAgainAfterRenew_NeedsLogin()
    {
        creds.Current = Valid();
        api.Respond = _ => new(ApiStatus.Unauthorized, Error: "HTTP 401");
        renewer.OnRenew = () => true;
        var service = Create();

        await service.RefreshAsync();

        Assert.Equal(ServiceStatus.NeedsLogin, service.State.Status);
        Assert.Equal(2, api.Tokens.Count);
    }

    [Theory]
    [InlineData(ApiStatus.Failed, "HTTP 503")]
    [InlineData(ApiStatus.RateLimited, "HTTP 429")]
    public async Task FailedFetch_WhileDataIsFresh_StaysOk(ApiStatus failure, string error)
    {
        creds.Current = Valid();
        var service = Create();
        await service.RefreshAsync();
        clock.Now = Now.AddMinutes(2); // e.g. a manual "Refresh" right after the automatic refresh
        api.Respond = _ => new(failure, Error: error);

        await service.RefreshAsync();

        Assert.Equal(ServiceStatus.Ok, service.State.Status);
        Assert.Equal(26, service.State.Snapshot!.Session!.UsedPercent);
        Assert.Equal(Now, service.State.LastSuccess);
        Assert.Equal(error, service.State.LastError);
    }

    [Fact]
    public async Task FailedFetch_WhenDataIsStale_IsAnError()
    {
        creds.Current = Valid();
        var service = Create();
        await service.RefreshAsync();
        clock.Now = Now.AddMinutes(16);
        api.Respond = _ => new(ApiStatus.Failed, Error: "HTTP 503");

        await service.RefreshAsync();

        Assert.Equal(ServiceStatus.Error, service.State.Status);
        Assert.Equal(26, service.State.Snapshot!.Session!.UsedPercent);
        Assert.Equal(Now, service.State.LastSuccess);
    }

    [Fact]
    public async Task SuccessAfterFailure_ClearsTheError()
    {
        creds.Current = Valid();
        var service = Create();
        api.Respond = _ => new(ApiStatus.Failed, Error: "HTTP 503");
        await service.RefreshAsync();
        api.Respond = _ => new(ApiStatus.Ok, Fixtures.Usage);

        await service.RefreshAsync();

        Assert.Null(service.State.LastError);
    }

    [Fact]
    public async Task RateLimited_KeepsLastSnapshot_AndBacksOffExponentially()
    {
        creds.Current = Valid();
        var service = Create();
        await service.RefreshAsync();
        api.Respond = _ => new(ApiStatus.RateLimited, Error: "HTTP 429");

        var delays = new List<TimeSpan>();
        for (int i = 0; i < 4; i++)
        {
            await service.RefreshAsync();
            delays.Add(service.NextDelay());
        }

        Assert.Equal(26, service.State.Snapshot!.Session!.UsedPercent);
        Assert.Equal(new[] { 10.0, 20.0, 30.0, 30.0 }, delays.Select(d => d.TotalMinutes));
    }

    [Fact]
    public async Task SuccessAfterRateLimit_ReturnsToPollInterval()
    {
        creds.Current = Valid();
        api.Respond = _ => new(ApiStatus.RateLimited, Error: "HTTP 429");
        var service = Create();
        await service.RefreshAsync();
        api.Respond = _ => new(ApiStatus.Ok, Fixtures.Usage);

        await service.RefreshAsync();

        Assert.Equal(ServiceStatus.Ok, service.State.Status);
        Assert.Equal(UsageService.PollInterval, service.NextDelay());
    }

    [Fact]
    public async Task RateLimited_IgnoresTheSessionResetShortcut()
    {
        creds.Current = Valid();
        var service = Create();
        await service.RefreshAsync();
        clock.Now = new DateTimeOffset(2026, 10, 1, 17, 58, 0, TimeSpan.FromHours(2));
        creds.Current = Valid() with { ExpiresAt = clock.Now.AddHours(2) };
        api.Respond = _ => new(ApiStatus.RateLimited, Error: "HTTP 429");

        await service.RefreshAsync();

        Assert.Equal(TimeSpan.FromMinutes(10), service.NextDelay());
    }

    [Fact]
    public async Task UnreadableResponse_IsAnError()
    {
        creds.Current = Valid();
        api.Respond = _ => new(ApiStatus.Ok, "<html>maintenance</html>");
        var service = Create();

        await service.RefreshAsync();

        Assert.Equal(ServiceStatus.Error, service.State.Status);
        Assert.Null(service.State.Snapshot);
    }

    [Fact]
    public async Task Changed_IsRaisedWithTheNewState()
    {
        creds.Current = Valid();
        var service = Create();
        UsageState? seen = null;
        service.Changed += s => seen = s;

        await service.RefreshAsync();

        Assert.Same(service.State, seen);
    }

    [Fact]
    public async Task NextDelay_IsPollInterval_WhenResetIsFar()
    {
        creds.Current = Valid();
        var service = Create();
        await service.RefreshAsync(); // session resets at 18:00, now 14:00

        Assert.Equal(UsageService.PollInterval, service.NextDelay());
    }

    [Fact]
    public async Task NextDelay_WakesShortlyAfterSessionReset()
    {
        creds.Current = Valid();
        var service = Create();
        await service.RefreshAsync();
        clock.Now = new DateTimeOffset(2026, 10, 1, 17, 58, 0, TimeSpan.FromHours(2));

        // fixture: session resets at 18:00:00.345899 → 2 min 0.35 s + 15 s
        Assert.InRange(service.NextDelay().TotalSeconds, 135, 136);
    }
}
