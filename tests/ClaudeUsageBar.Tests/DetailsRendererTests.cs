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
    [InlineData("en", ServiceStatus.Loading)]
    [InlineData("en", ServiceStatus.Ok)]
    [InlineData("en", ServiceStatus.Error)]
    [InlineData("en", ServiceStatus.NeedsLogin)]
    [InlineData("pl", ServiceStatus.Ok)]
    [InlineData("pl", ServiceStatus.NeedsLogin)]
    public void Draw_EveryStatus_RendersOnThemedSurface(string lang, ServiceStatus status)
    {
        var snapshot = status == ServiceStatus.Loading ? null : UsageParser.Parse(Fixtures.Usage, Now);
        var state = new UsageState(status, snapshot, "Max 20x", snapshot is null ? null : Now, status == ServiceStatus.Error ? "HTTP 503" : null);
        var size = new Size(DetailsRenderer.LogicalWidth, DetailsRenderer.LogicalHeight(state));
        using var bmp = new Bitmap(size.Width, size.Height);
        using var g = Graphics.FromImage(bmp);

        DetailsRenderer.Draw(g, size, 1f, state, Now, Theme.Dark, Lang.Get(lang));

        Assert.Equal(Theme.Dark.Surface.ToArgb(), bmp.GetPixel(2, 2).ToArgb());
    }

    [Theory]
    [InlineData("en", ServiceStatus.Ok, 2, "Updated 2m ago")]
    [InlineData("en", ServiceStatus.Ok, 0, "Updated just now")]
    [InlineData("en", ServiceStatus.Error, 12, "Refresh failed · updated 12m ago")]
    [InlineData("en", ServiceStatus.NeedsLogin, 2, "Sign in: run claude in a terminal")]
    [InlineData("en", ServiceStatus.Loading, 0, "Loading…")]
    [InlineData("pl", ServiceStatus.Ok, 2, "Odświeżono 2m temu")]
    [InlineData("pl", ServiceStatus.Error, 12, "Nie odświeżono · dane 12m temu")]
    [InlineData("pl", ServiceStatus.NeedsLogin, 2, "Zaloguj się: uruchom claude w terminalu")]
    public void FooterText_DescribesStatusAndAge(string lang, ServiceStatus status, int minutesAgo, string expected)
    {
        var state = new UsageState(status, null, "", status == ServiceStatus.Loading ? null : Now.AddMinutes(-minutesAgo), null);
        Assert.Equal(expected, DetailsRenderer.FooterText(state, Now, Lang.Get(lang)));
    }

    [Fact]
    public void FooterText_ErrorBeforeAnyData() =>
        Assert.Equal("Couldn't load data", DetailsRenderer.FooterText(new UsageState(ServiceStatus.Error, null, "", null, "HTTP 503"), Now, Lang.En));

    [Theory]
    [InlineData("en", ServiceStatus.Loading, "Loading data…")]
    [InlineData("en", ServiceStatus.Error, "No data yet · retrying in a few minutes")]
    [InlineData("en", ServiceStatus.NeedsLogin, "No data: Claude Code login expired")]
    [InlineData("pl", ServiceStatus.Error, "Brak danych · kolejna próba za kilka minut")]
    public void EmptyText_MatchesStatus(string lang, ServiceStatus status, string expected) =>
        Assert.Equal(expected, DetailsRenderer.EmptyText(new UsageState(status, null, "", null, null), Lang.Get(lang)));

    [Theory]
    [InlineData("en", "Resets in 2h 38m · today 18:00")]
    [InlineData("pl", "Reset za 2h 38m · dziś 18:00")]
    public void ResetText_ShowsCountdownAndMoment(string lang, string expected)
    {
        var now = new DateTimeOffset(new DateTime(2026, 10, 1, 15, 21, 0, DateTimeKind.Local));
        var reset = new DateTimeOffset(new DateTime(2026, 10, 1, 17, 59, 59, 900, DateTimeKind.Local));
        Assert.Equal(expected, DetailsRenderer.ResetText(reset, now, Lang.Get(lang)));
    }

    [Fact]
    public void RefreshRect_SitsInBottomRightCorner()
    {
        var rect = DetailsRenderer.RefreshRect(new Size(300, 262), 1f);
        Assert.True(rect.Contains(270, 245));
        Assert.False(rect.Contains(30, 245));
    }
}
