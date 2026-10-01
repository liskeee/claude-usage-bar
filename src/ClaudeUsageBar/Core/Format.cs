using System.Globalization;
using System.Text.RegularExpressions;

namespace ClaudeUsageBar.Core;

public enum Severity { Ok, Warn, Critical }

/// Text/number formatting shared by the taskbar readout and the details popup; wording comes from Texts.
public static class Format
{
    // green < 50, amber 50–80, red > 80
    public static Severity SeverityOf(double used) =>
        used < 50 ? Severity.Ok : used <= 80 ? Severity.Warn : Severity.Critical;

    public static string Percent(double used) =>
        $"{Math.Round(used, MidpointRounding.AwayFromZero).ToString("0", CultureInfo.InvariantCulture)}%";

    /// Taskbar countdown, e.g. "52m", "3h 49m", "6d 17h".
    public static string CountdownShort(TimeSpan t, Texts texts)
    {
        var time = texts.Time;
        return t.TotalMinutes < 1 ? time.LessThanMinute
            : t.TotalHours < 1 ? Texts.Fill(time.Minutes, ("m", Int((int)t.TotalMinutes)))
            : t.TotalDays < 1 ? Texts.Fill(time.HoursMinutes, ("h", Int((int)t.TotalHours)), ("m", Int(t.Minutes)))
            : Texts.Fill(time.DaysHours, ("d", Int((int)t.TotalDays)), ("h", Int(t.Hours)));
    }

    /// Popup countdown, e.g. "in 3h 49m".
    public static string CountdownLong(TimeSpan t, Texts texts) =>
        t.TotalMinutes < 1 ? texts.Time.InAMoment : Texts.Fill(texts.Time.In, ("duration", CountdownShort(t, texts)));

    /// Age of the data, e.g. "just now", "2m ago".
    public static string Ago(TimeSpan t, Texts texts) =>
        t.TotalMinutes < 1 ? texts.Time.JustNow : Texts.Fill(texts.Time.Ago, ("duration", CountdownShort(t, texts)));

    /// e.g. "today 18:00", "tomorrow 08:00", "Thu 8 Oct, 08:00" — both arguments in local time.
    public static string ResetMoment(DateTime reset, DateTime now, Texts texts)
    {
        // the API reports e.g. 17:59:59.9 for an 18:00 reset
        reset = new DateTime((reset.Ticks + TimeSpan.TicksPerMinute / 2) / TimeSpan.TicksPerMinute * TimeSpan.TicksPerMinute, reset.Kind);
        var time = texts.Time;
        var clock = reset.ToString("HH:mm", CultureInfo.InvariantCulture);
        if (reset.Date == now.Date) return Texts.Fill(time.Today, ("time", clock));
        if (reset.Date == now.Date.AddDays(1)) return Texts.Fill(time.Tomorrow, ("time", clock));
        return Texts.Fill(time.OtherDay,
            ("weekday", time.Weekdays[(int)reset.DayOfWeek]), ("day", Int(reset.Day)),
            ("month", time.Months[reset.Month - 1]), ("monthNumber", Int(reset.Month)), ("time", clock));
    }

    public static string LimitLabel(LimitInfo limit, Texts texts) => limit.Kind switch
    {
        LimitKind.Session => texts.Limits.Session,
        LimitKind.Weekly => texts.Limits.Weekly,
        _ => Texts.Fill(texts.Limits.Scoped, ("model", limit.Model ?? texts.Limits.UnknownModel)),
    };

    /// "default_claude_max_20x" → "Max 20x"; otherwise the capitalised subscription type.
    public static string PlanName(string? subscriptionType, string? rateLimitTier)
    {
        var max = Regex.Match(rateLimitTier ?? "", @"max_(\d+)x");
        if (max.Success) return $"Max {max.Groups[1].Value}x";
        if (string.IsNullOrWhiteSpace(subscriptionType)) return "";
        return char.ToUpperInvariant(subscriptionType[0]) + subscriptionType[1..];
    }

    static string Int(int value) => value.ToString(CultureInfo.InvariantCulture);
}
