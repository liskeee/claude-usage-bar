using ClaudeUsageBar.Core;

namespace ClaudeUsageBar.Tests;

public class FormatTests
{
    [Theory]
    [InlineData(0, Severity.Ok)]
    [InlineData(49.9, Severity.Ok)]
    [InlineData(50, Severity.Warn)]
    [InlineData(80, Severity.Warn)]
    [InlineData(80.1, Severity.Critical)]
    [InlineData(100, Severity.Critical)]
    public void SeverityOf_UsesSpecThresholds(double used, Severity expected) =>
        Assert.Equal(expected, Format.SeverityOf(used));

    [Theory]
    [InlineData(26.0, "26%")]
    [InlineData(37.5, "38%")]
    [InlineData(36.5, "37%")]
    [InlineData(0.4, "0%")]
    public void Percent_RoundsHalfAwayFromZero(double used, string expected) =>
        Assert.Equal(expected, Format.Percent(used));

    [Theory]
    [InlineData(-5, "<1m")]
    [InlineData(30, "<1m")]
    [InlineData(52 * 60, "52m")]
    [InlineData(3 * 3600 + 49 * 60 + 28, "3h 49m")]
    [InlineData(6 * 86400 + 17 * 3600 + 49 * 60, "6d 17h")]
    public void CountdownShort_IsCompact(int seconds, string expected) =>
        Assert.Equal(expected, Format.CountdownShort(TimeSpan.FromSeconds(seconds)));

    [Theory]
    [InlineData(30, "in a moment")]
    [InlineData(52 * 60, "in 52m")]
    [InlineData(3 * 3600 + 49 * 60 + 28, "in 3h 49m")]
    [InlineData(6 * 86400 + 17 * 3600 + 49 * 60, "in 6d 17h")]
    public void CountdownLong_IsReadable(int seconds, string expected) =>
        Assert.Equal(expected, Format.CountdownLong(TimeSpan.FromSeconds(seconds)));

    [Theory]
    [InlineData(-3, "just now")]
    [InlineData(20, "just now")]
    [InlineData(2 * 60, "2m ago")]
    [InlineData(59 * 60 + 59, "59m ago")]
    [InlineData(3600 + 5 * 60, "1h 5m ago")]
    [InlineData(26 * 3600, "1d 2h ago")]
    public void Ago_SaysHowLongAgo(int seconds, string expected) =>
        Assert.Equal(expected, Format.Ago(TimeSpan.FromSeconds(seconds)));

    [Theory]
    [InlineData(1, 18, 0, "today 18:00")]
    [InlineData(2, 8, 0, "tomorrow 08:00")]
    [InlineData(8, 8, 0, "Thu 8 Oct, 08:00")]
    [InlineData(4, 23, 5, "Sun 4 Oct, 23:05")]
    public void ResetMoment_UsesRelativeDayOrWeekday(int day, int hour, int minute, string expected)
    {
        var now = new DateTime(2026, 10, 1, 14, 10, 0); // Thursday
        Assert.Equal(expected, Format.ResetMoment(new DateTime(2026, 10, day, hour, minute, 0), now));
    }

    [Fact]
    public void ResetMoment_RoundsToTheNearestMinute()
    {
        var now = new DateTime(2026, 10, 1, 14, 10, 0);
        Assert.Equal("today 18:00", Format.ResetMoment(new DateTime(2026, 10, 1, 17, 59, 59, 900), now));
        Assert.Equal("tomorrow 00:00", Format.ResetMoment(new DateTime(2026, 10, 1, 23, 59, 59, 900), now));
    }

    [Theory]
    [InlineData("max", "default_claude_max_20x", "Max 20x")]
    [InlineData("max", "default_claude_max_5x", "Max 5x")]
    [InlineData("pro", null, "Pro")]
    [InlineData(null, null, "")]
    public void PlanName_PrefersRateLimitTier(string? subscription, string? tier, string expected) =>
        Assert.Equal(expected, Format.PlanName(subscription, tier));
}
