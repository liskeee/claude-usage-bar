using ClaudeUsageBar.Core;
using ClaudeUsageBar.UI;

namespace ClaudeUsageBar.Tests;

public class DetailsRendererTests
{
    static readonly DateTimeOffset Now = new(2026, 10, 1, 14, 10, 0, TimeSpan.FromHours(2));

    [Fact]
    public void LogicalHeight_GrowsWithNumberOfLimits()
    {
        Assert.Equal(146, DetailsRenderer.LogicalHeight(UsageState.Initial));
        var three = UsageState.Initial with { Status = ServiceStatus.Ok, Snapshot = UsageParser.Parse(Fixtures.Usage, Now), LastSuccess = Now };
        Assert.Equal(262, DetailsRenderer.LogicalHeight(three));
    }

    [Theory]
    [InlineData(ServiceStatus.Loading)]
    [InlineData(ServiceStatus.Ok)]
    [InlineData(ServiceStatus.Error)]
    [InlineData(ServiceStatus.NeedsLogin)]
    public void Draw_EveryStatus_RendersOnThemedSurface(ServiceStatus status)
    {
        var snapshot = status == ServiceStatus.Loading ? null : UsageParser.Parse(Fixtures.Usage, Now);
        var state = new UsageState(status, snapshot, "Max 20x", snapshot is null ? null : Now, status == ServiceStatus.Error ? "HTTP 503" : null);
        var size = new Size(DetailsRenderer.LogicalWidth, DetailsRenderer.LogicalHeight(state));
        using var bmp = new Bitmap(size.Width, size.Height);
        using var g = Graphics.FromImage(bmp);

        DetailsRenderer.Draw(g, size, 1f, state, Now, Theme.Dark);

        Assert.Equal(Theme.Dark.Surface.ToArgb(), bmp.GetPixel(2, 2).ToArgb());
    }

    [Theory]
    [InlineData(ServiceStatus.Ok, 2, "Updated 2m ago")]
    [InlineData(ServiceStatus.Ok, 0, "Updated just now")]
    [InlineData(ServiceStatus.Error, 12, "Refresh failed · updated 12m ago")]
    [InlineData(ServiceStatus.NeedsLogin, 2, "Sign in: run claude in a terminal")]
    [InlineData(ServiceStatus.Loading, 0, "Loading…")]
    public void FooterText_DescribesStatusAndAge(ServiceStatus status, int minutesAgo, string expected)
    {
        var state = new UsageState(status, null, "", status == ServiceStatus.Loading ? null : Now.AddMinutes(-minutesAgo), null);
        Assert.Equal(expected, DetailsRenderer.FooterText(state, Now));
    }

    [Fact]
    public void FooterText_ErrorBeforeAnyData() =>
        Assert.Equal("Couldn't load data", DetailsRenderer.FooterText(new UsageState(ServiceStatus.Error, null, "", null, "HTTP 503"), Now));

    [Theory]
    [InlineData(ServiceStatus.Loading, "Loading data…")]
    [InlineData(ServiceStatus.Error, "No data yet · retrying in a few minutes")]
    [InlineData(ServiceStatus.NeedsLogin, "No data: Claude Code login expired")]
    public void EmptyText_MatchesStatus(ServiceStatus status, string expected) =>
        Assert.Equal(expected, DetailsRenderer.EmptyText(new UsageState(status, null, "", null, null)));

    [Fact]
    public void ResetText_ShowsCountdownAndMoment()
    {
        var now = new DateTimeOffset(new DateTime(2026, 10, 1, 15, 21, 0, DateTimeKind.Local));
        var reset = new DateTimeOffset(new DateTime(2026, 10, 1, 17, 59, 59, 900, DateTimeKind.Local));
        Assert.Equal("Resets in 2h 38m · today 18:00", DetailsRenderer.ResetText(reset, now));
    }

    [Fact]
    public void RefreshRect_SitsInBottomRightCorner()
    {
        var rect = DetailsRenderer.RefreshRect(new Size(300, 262), 1f);
        Assert.True(rect.Contains(270, 245));
        Assert.False(rect.Contains(30, 245));
    }
}
