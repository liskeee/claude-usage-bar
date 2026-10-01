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
    [InlineData("en", -5, "<1m")]
    [InlineData("en", 30, "<1m")]
    [InlineData("en", 52 * 60, "52m")]
    [InlineData("en", 3 * 3600 + 49 * 60 + 28, "3h 49m")]
    [InlineData("en", 6 * 86400 + 17 * 3600 + 49 * 60, "6d 17h")]
    [InlineData("pl", 3 * 3600 + 49 * 60 + 28, "3h 49m")]
    public void CountdownShort_IsCompact(string lang, int seconds, string expected) =>
        Assert.Equal(expected, Format.CountdownShort(TimeSpan.FromSeconds(seconds), Lang.Get(lang)));

    [Theory]
    [InlineData("en", 30, "in a moment")]
    [InlineData("en", 52 * 60, "in 52m")]
    [InlineData("en", 6 * 86400 + 17 * 3600 + 49 * 60, "in 6d 17h")]
    [InlineData("pl", 30, "za chwilę")]
    [InlineData("pl", 3 * 3600 + 49 * 60 + 28, "za 3h 49m")]
    public void CountdownLong_IsReadable(string lang, int seconds, string expected) =>
        Assert.Equal(expected, Format.CountdownLong(TimeSpan.FromSeconds(seconds), Lang.Get(lang)));

    [Theory]
    [InlineData("en", -3, "just now")]
    [InlineData("en", 2 * 60, "2m ago")]
    [InlineData("en", 59 * 60 + 59, "59m ago")]
    [InlineData("en", 26 * 3600, "1d 2h ago")]
    [InlineData("pl", 20, "przed chwilą")]
    [InlineData("pl", 3600 + 5 * 60, "1h 5m temu")]
    public void Ago_SaysHowLongAgo(string lang, int seconds, string expected) =>
        Assert.Equal(expected, Format.Ago(TimeSpan.FromSeconds(seconds), Lang.Get(lang)));

    [Theory]
    [InlineData("en", 1, 18, 0, "today 18:00")]
    [InlineData("en", 2, 8, 0, "tomorrow 08:00")]
    [InlineData("en", 8, 8, 0, "Thu 8 Oct, 08:00")]
    [InlineData("en", 4, 23, 5, "Sun 4 Oct, 23:05")]
    [InlineData("pl", 1, 18, 0, "dziś 18:00")]
    [InlineData("pl", 2, 8, 0, "jutro 08:00")]
    [InlineData("pl", 8, 8, 0, "czw. 8.10, 08:00")]
    [InlineData("pl", 4, 23, 5, "niedz. 4.10, 23:05")]
    public void ResetMoment_UsesRelativeDayOrWeekday(string lang, int day, int hour, int minute, string expected)
    {
        var now = new DateTime(2026, 10, 1, 14, 10, 0); // Thursday
        Assert.Equal(expected, Format.ResetMoment(new DateTime(2026, 10, day, hour, minute, 0), now, Lang.Get(lang)));
    }

    [Fact]
    public void ResetMoment_RoundsToTheNearestMinute()
    {
        var now = new DateTime(2026, 10, 1, 14, 10, 0);
        Assert.Equal("today 18:00", Format.ResetMoment(new DateTime(2026, 10, 1, 17, 59, 59, 900), now, Lang.En));
        Assert.Equal("tomorrow 00:00", Format.ResetMoment(new DateTime(2026, 10, 1, 23, 59, 59, 900), now, Lang.En));
    }

    [Theory]
    [InlineData("en", LimitKind.Session, null, "Current session")]
    [InlineData("en", LimitKind.Weekly, null, "This week")]
    [InlineData("en", LimitKind.WeeklyScoped, "Fable", "Fable this week")]
    [InlineData("en", LimitKind.WeeklyScoped, null, "Model this week")]
    [InlineData("pl", LimitKind.Session, null, "Sesja (5 h)")]
    [InlineData("pl", LimitKind.Weekly, null, "Tydzień")]
    [InlineData("pl", LimitKind.WeeklyScoped, "Fable", "Fable · tydzień")]
    public void LimitLabel_IsTranslated(string lang, LimitKind kind, string? model, string expected) =>
        Assert.Equal(expected, Format.LimitLabel(new LimitInfo(kind, 10, null, model), Lang.Get(lang)));

    [Theory]
    [InlineData("max", "default_claude_max_20x", "Max 20x")]
    [InlineData("max", "default_claude_max_5x", "Max 5x")]
    [InlineData("pro", null, "Pro")]
    [InlineData(null, null, "")]
    public void PlanName_PrefersRateLimitTier(string? subscription, string? tier, string expected) =>
        Assert.Equal(expected, Format.PlanName(subscription, tier));
}
