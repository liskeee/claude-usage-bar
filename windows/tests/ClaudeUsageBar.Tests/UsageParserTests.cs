using ClaudeUsageBar.Core;

namespace ClaudeUsageBar.Tests;

public class UsageParserTests
{
    static readonly DateTimeOffset FetchedAt = new(2026, 10, 1, 13, 41, 47, TimeSpan.FromHours(2));

    [Fact]
    public void Parse_RealResponse_ReadsSessionWeeklyAndScopedLimits()
    {
        var snap = UsageParser.Parse(Fixtures.Usage, FetchedAt);

        Assert.Equal(3, snap.Limits.Count);
        Assert.Equal(new LimitInfo(LimitKind.Session, 26, DateTimeOffset.Parse("2026-10-01T18:00:00.345899+02:00")), snap.Session);
        Assert.Equal(new LimitInfo(LimitKind.Weekly, 22, DateTimeOffset.Parse("2026-10-08T08:00:00.345927+02:00")), snap.Weekly);
        Assert.Equal(new LimitInfo(LimitKind.WeeklyScoped, 3, DateTimeOffset.Parse("2026-10-08T08:00:00.346176+02:00"), "Fable"), snap.Limits[2]);
        Assert.Equal(FetchedAt, snap.FetchedAt);
    }

    [Fact]
    public void Parse_WithoutLimitsArray_FallsBackToFiveHourAndSevenDay()
    {
        const string json = """
            {"five_hour":{"utilization":41.0,"resets_at":"2026-10-01T18:00:00+02:00"},
             "seven_day":{"utilization":12.5,"resets_at":"2026-10-08T08:00:00+02:00"}}
            """;

        var snap = UsageParser.Parse(json, FetchedAt);

        Assert.Equal(2, snap.Limits.Count);
        Assert.Equal(41.0, snap.Session!.UsedPercent);
        Assert.Equal(12.5, snap.Weekly!.UsedPercent);
        Assert.Equal(DateTimeOffset.Parse("2026-10-08T08:00:00+02:00"), snap.Weekly.ResetsAt);
    }

    [Fact]
    public void Parse_SkipsUnknownKindsAndEntriesWithoutPercent()
    {
        const string json = """
            {"limits":[
              {"kind":"session","percent":5,"resets_at":null},
              {"kind":"monthly_mystery","percent":50,"resets_at":"2026-11-01T00:00:00Z"},
              {"kind":"weekly_all","percent":null,"resets_at":"2026-10-08T08:00:00Z"}]}
            """;

        var snap = UsageParser.Parse(json, FetchedAt);

        var only = Assert.Single(snap.Limits);
        Assert.Equal(LimitKind.Session, only.Kind);
        Assert.Null(only.ResetsAt);
        Assert.Null(snap.Weekly);
    }

    [Fact]
    public void Parse_ScopedLimitWithoutModelName_HasNoModel()
    {
        const string json = """{"limits":[{"kind":"weekly_scoped","percent":7,"resets_at":null,"scope":null}]}""";

        var only = Assert.Single(UsageParser.Parse(json, FetchedAt).Limits);
        Assert.Equal(LimitKind.WeeklyScoped, only.Kind);
        Assert.Null(only.Model);
    }
}
