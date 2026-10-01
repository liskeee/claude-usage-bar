using ClaudeUsageBar.Core;

namespace ClaudeUsageBar.Tests;

public class TokenRenewerTests
{
    readonly FakeClock clock = new(new DateTimeOffset(2026, 10, 1, 14, 0, 0, TimeSpan.Zero));
    int runs;

    CliTokenRenewer Create(bool cliSucceeds = true) => new(clock, _ => { runs++; return Task.FromResult(cliSucceeds); });

    [Fact]
    public async Task FirstAttempt_RunsCli()
    {
        Assert.True(await Create().TryRenewAsync(default));
        Assert.Equal(1, runs);
    }

    [Fact]
    public async Task SecondAttemptWithin30Minutes_IsSkipped()
    {
        var renewer = Create();
        await renewer.TryRenewAsync(default);
        clock.Now = clock.Now.AddMinutes(29);

        Assert.False(await renewer.TryRenewAsync(default));
        Assert.Equal(1, runs);
    }

    [Fact]
    public async Task AttemptAfter30Minutes_RunsAgain()
    {
        var renewer = Create();
        await renewer.TryRenewAsync(default);
        clock.Now = clock.Now.AddMinutes(30);

        Assert.True(await renewer.TryRenewAsync(default));
        Assert.Equal(2, runs);
    }

    [Fact]
    public async Task FailedRun_StillCountsTowardTheLimit()
    {
        var renewer = Create(cliSucceeds: false);
        Assert.False(await renewer.TryRenewAsync(default));
        clock.Now = clock.Now.AddMinutes(5);

        Assert.False(await renewer.TryRenewAsync(default));
        Assert.Equal(1, runs);
    }
}
