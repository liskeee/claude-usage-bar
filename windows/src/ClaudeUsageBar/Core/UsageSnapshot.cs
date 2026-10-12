namespace ClaudeUsageBar.Core;

public enum LimitKind { Session, Weekly, WeeklyScoped }

/// One usage limit exactly as claude.ai → Settings → Usage shows it (percent = used).
/// Model is set for per-model weekly limits (e.g. "Fable"); the label is localized by the UI.
public sealed record LimitInfo(LimitKind Kind, double UsedPercent, DateTimeOffset? ResetsAt, string? Model = null);

public sealed record UsageSnapshot(IReadOnlyList<LimitInfo> Limits, DateTimeOffset FetchedAt)
{
    public LimitInfo? Session => Limits.FirstOrDefault(l => l.Kind == LimitKind.Session);
    public LimitInfo? Weekly => Limits.FirstOrDefault(l => l.Kind == LimitKind.Weekly);
}
