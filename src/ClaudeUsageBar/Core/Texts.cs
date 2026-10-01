using System.Globalization;
using System.Reflection;
using System.Text.Json;

namespace ClaudeUsageBar.Core;

/// UI strings for one language, read from the embedded Localization/<code>.json.
/// Templates use named placeholders such as {time}; see Texts.Fill.
public sealed class Texts
{
    public required LimitTexts Limits { get; init; }
    public required BarTexts Bar { get; init; }
    public required TimeTexts Time { get; init; }
    public required PopupTexts Popup { get; init; }
    public required MenuTexts Menu { get; init; }
    public required string AutostartDescription { get; init; }

    const string ResourcePrefix = "Localization.";
    const string Fallback = "en";
    static readonly Assembly Assembly = typeof(Texts).Assembly;
    static readonly JsonSerializerOptions Options = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    /// Two-letter codes of the embedded languages.
    public static IReadOnlyList<string> Available { get; } = Assembly.GetManifestResourceNames()
        .Where(n => n.StartsWith(ResourcePrefix) && n.EndsWith(".json"))
        .Select(n => n[ResourcePrefix.Length..^".json".Length])
        .Order()
        .ToList();

    /// Throws when the language is not embedded or its file misses a required text.
    public static Texts Load(string code)
    {
        using var stream = Assembly.GetManifestResourceStream($"{ResourcePrefix}{code}.json")
            ?? throw new ArgumentException($"No translation for '{code}'", nameof(code));
        return JsonSerializer.Deserialize<Texts>(stream, Options) ?? throw new JsonException($"Empty translation '{code}'");
    }

    /// The Windows display language if it is translated, English otherwise.
    public static Texts ForCulture(CultureInfo culture) =>
        Load(Available.Contains(culture.TwoLetterISOLanguageName) ? culture.TwoLetterISOLanguageName : Fallback);

    public static string Fill(string template, params (string Key, string Value)[] values)
    {
        foreach (var (key, value) in values) template = template.Replace($"{{{key}}}", value);
        return template;
    }
}

public sealed class LimitTexts
{
    public required string Session { get; init; }
    public required string Weekly { get; init; }
    public required string Scoped { get; init; }
    public required string UnknownModel { get; init; }
}

public sealed class BarTexts
{
    public required string Session { get; init; }
    public required string Week { get; init; }
    public required string SignIn { get; init; }
}

public sealed class TimeTexts
{
    public required string LessThanMinute { get; init; }
    public required string Minutes { get; init; }
    public required string HoursMinutes { get; init; }
    public required string DaysHours { get; init; }
    public required string InAMoment { get; init; }
    public required string In { get; init; }
    public required string JustNow { get; init; }
    public required string Ago { get; init; }
    public required string Today { get; init; }
    public required string Tomorrow { get; init; }
    public required string OtherDay { get; init; }
    public required string[] Weekdays { get; init; }
    public required string[] Months { get; init; }
}

public sealed class PopupTexts
{
    public required string ResetLine { get; init; }
    public required string Updated { get; init; }
    public required string RefreshFailed { get; init; }
    public required string LoadFailed { get; init; }
    public required string SignIn { get; init; }
    public required string Loading { get; init; }
    public required string EmptyLoading { get; init; }
    public required string EmptyError { get; init; }
    public required string EmptyNeedsLogin { get; init; }
    public required string Refresh { get; init; }
}

public sealed class MenuTexts
{
    public required string RefreshNow { get; init; }
    public required string StartWithWindows { get; init; }
    public required string Exit { get; init; }
}
