using System.Collections;
using System.Globalization;
using System.Reflection;
using System.Text.RegularExpressions;
using ClaudeUsageBar.Core;

namespace ClaudeUsageBar.Tests;

public class TextsTests
{
    // every placeholder the code fills in; a typo in a translation shows up as an unknown one
    static readonly HashSet<string> KnownPlaceholders =
        ["model", "m", "h", "d", "duration", "time", "weekday", "day", "month", "monthNumber", "countdown", "moment", "ago"];

    public static TheoryData<string> Languages => new(Texts.Available);

    [Fact]
    public void EnglishAndPolish_AreAvailable() =>
        Assert.Superset(new HashSet<string> { "en", "pl" }, Texts.Available.ToHashSet());

    [Theory]
    [MemberData(nameof(Languages))]
    public void EveryLanguage_HasAllTexts_WithoutEmptyValues(string code)
    {
        var texts = Texts.Load(code);

        foreach (var (path, value) in Strings(texts))
            Assert.False(string.IsNullOrWhiteSpace(value), $"{code}: {path} is empty");
        Assert.Equal(7, texts.Time.Weekdays.Length);
        Assert.Equal(12, texts.Time.Months.Length);
    }

    [Theory]
    [MemberData(nameof(Languages))]
    public void EveryLanguage_UsesOnlyKnownPlaceholders(string code)
    {
        foreach (var (path, value) in Strings(Texts.Load(code)))
            foreach (Match m in Regex.Matches(value, @"\{(\w+)\}"))
                Assert.True(KnownPlaceholders.Contains(m.Groups[1].Value), $"{code}: {path} uses unknown {{{m.Groups[1].Value}}}");
    }

    [Theory]
    [InlineData("pl-PL", "Odśwież")]
    [InlineData("pl", "Odśwież")]
    [InlineData("en-US", "Refresh")]
    [InlineData("de-DE", "Refresh")] // no German file: falls back to English
    [InlineData("", "Refresh")]      // invariant culture
    public void ForCulture_PicksWindowsLanguage_OrEnglish(string culture, string refresh) =>
        Assert.Equal(refresh, Texts.ForCulture(CultureInfo.GetCultureInfo(culture)).Popup.Refresh);

    [Fact]
    public void Fill_ReplacesNamedPlaceholders() =>
        Assert.Equal("Resets in 2h · today 18:00", Texts.Fill("Resets {countdown} · {moment}", ("countdown", "in 2h"), ("moment", "today 18:00")));

    /// All string values in the object graph, with their property path.
    static IEnumerable<(string Path, string Value)> Strings(object node, string path = "")
    {
        foreach (var p in node.GetType().GetProperties(BindingFlags.Public | BindingFlags.Instance))
        {
            var value = p.GetValue(node);
            var name = $"{path}{p.Name}";
            switch (value)
            {
                case string s: yield return (name, s); break;
                case IEnumerable items and not string:
                    int i = 0;
                    foreach (var item in items) yield return ($"{name}[{i++}]", item as string ?? "");
                    break;
                case not null when p.PropertyType.Namespace == typeof(Texts).Namespace:
                    foreach (var inner in Strings(value, name + ".")) yield return inner;
                    break;
            }
        }
    }
}
