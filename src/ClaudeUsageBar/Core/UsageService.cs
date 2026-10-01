using System.Diagnostics.CodeAnalysis;
using System.Text.Json;

namespace ClaudeUsageBar.Core;

public enum ServiceStatus { Loading, Ok, Error, NeedsLogin }

/// Everything the UI draws; replaced as a whole on every refresh.
public sealed record UsageState(ServiceStatus Status, UsageSnapshot? Snapshot, string PlanName, DateTimeOffset? LastSuccess, string? LastError)
{
    public static readonly UsageState Initial = new(ServiceStatus.Loading, null, "", null, null);
}

/// Token → (renew) → fetch → state. Keeps the last good snapshot when a refresh fails.
public sealed class UsageService(ICredentialStore credentials, IUsageApi api, ITokenRenewer renewer, TimeProvider clock)
{
    public static readonly TimeSpan PollInterval = TimeSpan.FromMinutes(5);
    public static readonly TimeSpan StaleAfter = TimeSpan.FromMinutes(15);
    static readonly TimeSpan ExpirySkew = TimeSpan.FromMinutes(1);
    static readonly TimeSpan AfterReset = TimeSpan.FromSeconds(15);
    static readonly TimeSpan MaxBackoff = TimeSpan.FromMinutes(30);

    readonly SemaphoreSlim gate = new(1, 1);
    int rateLimitStreak; // consecutive HTTP 429 answers; the endpoint refills slowly once drained

    public UsageState State { get; private set; } = UsageState.Initial;
    public event Action<UsageState>? Changed;

    public async Task RefreshAsync(CancellationToken ct = default)
    {
        await gate.WaitAsync(ct);
        try
        {
            State = await FetchAsync(ct);
            Log.Write($"refresh: {State.Status} session={State.Snapshot?.Session?.UsedPercent} week={State.Snapshot?.Weekly?.UsedPercent} {State.LastError}");
            Changed?.Invoke(State);
        }
        finally { gate.Release(); }
    }

    /// Next automatic refresh: the poll interval, or just after the session limit resets if that comes sooner;
    /// while rate limited, 10 → 20 → 30 min.
    public TimeSpan NextDelay()
    {
        if (rateLimitStreak > 0)
            return TimeSpan.FromTicks(Math.Min(MaxBackoff.Ticks, PollInterval.Ticks << Math.Min(rateLimitStreak, 8)));
        var now = clock.GetUtcNow();
        if (State.Snapshot?.Session?.ResetsAt is { } reset && reset > now && reset - now + AfterReset < PollInterval)
            return reset - now + AfterReset;
        return PollInterval;
    }

    async Task<UsageState> FetchAsync(CancellationToken ct)
    {
        var creds = credentials.Read();
        if (!IsUsable(creds))
        {
            await renewer.TryRenewAsync(ct);
            creds = credentials.Read();
            if (!IsUsable(creds)) return NeedsLogin(creds, "CLI login expired");
        }

        var result = await api.FetchAsync(creds.AccessToken, ct);
        if (result.Status == ApiStatus.Unauthorized)
        {
            await renewer.TryRenewAsync(ct);
            creds = credentials.Read();
            if (!IsUsable(creds)) return NeedsLogin(creds, "CLI login expired");
            result = await api.FetchAsync(creds.AccessToken, ct);
            if (result.Status == ApiStatus.Unauthorized) return NeedsLogin(creds, result.Error);
        }

        var plan = Format.PlanName(creds.SubscriptionType, creds.RateLimitTier);
        if (result.Status == ApiStatus.RateLimited) rateLimitStreak++;
        if (result.Status is ApiStatus.Failed or ApiStatus.RateLimited)
        {
            // a failed refresh only matters once the data already on screen gets old
            bool fresh = State.LastSuccess is { } last && clock.GetUtcNow() - last <= StaleAfter;
            return State with { Status = fresh ? ServiceStatus.Ok : ServiceStatus.Error, PlanName = plan, LastError = result.Error };
        }
        try
        {
            var snapshot = UsageParser.Parse(result.Json ?? "", clock.GetUtcNow());
            rateLimitStreak = 0;
            return new UsageState(ServiceStatus.Ok, snapshot, plan, snapshot.FetchedAt, null);
        }
        catch (JsonException)
        {
            return State with { Status = ServiceStatus.Error, PlanName = plan, LastError = "Unreadable API response" };
        }
    }

    bool IsUsable([NotNullWhen(true)] Credentials? c) => c is not null && c.ExpiresAt - ExpirySkew > clock.GetUtcNow();

    UsageState NeedsLogin(Credentials? c, string? error) => State with
    {
        Status = ServiceStatus.NeedsLogin,
        PlanName = c is null ? State.PlanName : Format.PlanName(c.SubscriptionType, c.RateLimitTier),
        LastError = error,
    };
}
