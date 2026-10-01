namespace ClaudeUsageBar.Core;

public enum LimitKind { Session, Weekly, WeeklyScoped }

/// One usage limit exactly as claude.ai → Settings → Usage shows it (percent = used).
public sealed record LimitInfo(LimitKind Kind, string Label, double UsedPercent, DateTimeOffset? ResetsAt);

public sealed record UsageSnapshot(IReadOnlyList<LimitInfo> Limits, DateTimeOffset FetchedAt)
{
    public LimitInfo? Session => Limits.FirstOrDefault(l => l.Kind == LimitKind.Session);
    public LimitInfo? Weekly => Limits.FirstOrDefault(l => l.Kind == LimitKind.Weekly);
}
