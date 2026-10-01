using System.Globalization;
using System.Text.RegularExpressions;

namespace ClaudeUsageBar.Core;

public enum Severity { Ok, Warn, Critical }

/// Pure text/number formatting shared by the taskbar readout and the details popup.
public static class Format
{
    // green < 50, amber 50–80, red > 80
    public static Severity SeverityOf(double used) =>
        used < 50 ? Severity.Ok : used <= 80 ? Severity.Warn : Severity.Critical;

    public static string Percent(double used) =>
        $"{Math.Round(used, MidpointRounding.AwayFromZero).ToString("0", CultureInfo.InvariantCulture)}%";

    /// Taskbar countdown: "52m", "3h 49m", "6d 17h".
    public static string CountdownShort(TimeSpan t) =>
        t.TotalMinutes < 1 ? "<1m"
        : t.TotalHours < 1 ? $"{(int)t.TotalMinutes}m"
        : t.TotalDays < 1 ? $"{(int)t.TotalHours}h {t.Minutes}m"
        : $"{(int)t.TotalDays}d {t.Hours}h";

    /// Popup countdown: "in 52m", "in 3h 49m", "in 6d 17h".
    public static string CountdownLong(TimeSpan t) =>
        t.TotalMinutes < 1 ? "in a moment" : $"in {CountdownShort(t)}";

    /// Age of the data: "just now", "2m ago", "1h 5m ago", "1d 2h ago".
    public static string Ago(TimeSpan t) =>
        t.TotalMinutes < 1 ? "just now" : $"{CountdownShort(t)} ago";

    /// "today 18:00", "tomorrow 08:00", "Thu 8 Oct, 08:00" — both arguments in local time.
    public static string ResetMoment(DateTime reset, DateTime now)
    {
        // the API reports e.g. 17:59:59.9 for an 18:00 reset
        reset = new DateTime((reset.Ticks + TimeSpan.TicksPerMinute / 2) / TimeSpan.TicksPerMinute * TimeSpan.TicksPerMinute, reset.Kind);
        var time = reset.ToString("HH:mm", CultureInfo.InvariantCulture);
        if (reset.Date == now.Date) return $"today {time}";
        if (reset.Date == now.Date.AddDays(1)) return $"tomorrow {time}";
        return reset.ToString("ddd d MMM, HH:mm", CultureInfo.InvariantCulture);
    }

    /// "default_claude_max_20x" → "Max 20x"; otherwise the capitalised subscription type.
    public static string PlanName(string? subscriptionType, string? rateLimitTier)
    {
        var max = Regex.Match(rateLimitTier ?? "", @"max_(\d+)x");
        if (max.Success) return $"Max {max.Groups[1].Value}x";
        if (string.IsNullOrWhiteSpace(subscriptionType)) return "";
        return char.ToUpperInvariant(subscriptionType[0]) + subscriptionType[1..];
    }
}
