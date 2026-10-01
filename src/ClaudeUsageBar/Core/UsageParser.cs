using System.Globalization;
using System.Text.Json;

namespace ClaudeUsageBar.Core;

/// Maps the /api/oauth/usage response to a snapshot; prefers `limits[]`, falls back to `five_hour` / `seven_day`.
public static class UsageParser
{
    public static UsageSnapshot Parse(string json, DateTimeOffset fetchedAt)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        var limits = new List<LimitInfo>();

        if (root.TryGetProperty("limits", out var items) && items.ValueKind == JsonValueKind.Array)
            foreach (var item in items.EnumerateArray())
                if (FromLimitsItem(item) is { } limit) limits.Add(limit);

        if (limits.Count == 0)
        {
            AddLegacy(root, "five_hour", LimitKind.Session, "Current session", limits);
            AddLegacy(root, "seven_day", LimitKind.Weekly, "This week", limits);
        }
        return new UsageSnapshot(limits, fetchedAt);
    }

    static LimitInfo? FromLimitsItem(JsonElement item)
    {
        if (Number(item, "percent") is not { } percent) return null;
        var resets = Date(item, "resets_at");
        return String(item, "kind") switch
        {
            "session" => new LimitInfo(LimitKind.Session, "Current session", percent, resets),
            "weekly_all" => new LimitInfo(LimitKind.Weekly, "This week", percent, resets),
            "weekly_scoped" => new LimitInfo(LimitKind.WeeklyScoped, $"{ModelName(item) ?? "Model"} this week", percent, resets),
            _ => null,
        };
    }

    static void AddLegacy(JsonElement root, string property, LimitKind kind, string label, List<LimitInfo> into)
    {
        if (root.TryGetProperty(property, out var el) && el.ValueKind == JsonValueKind.Object && Number(el, "utilization") is { } used)
            into.Add(new LimitInfo(kind, label, used, Date(el, "resets_at")));
    }

    static string? ModelName(JsonElement item) =>
        item.TryGetProperty("scope", out var scope) && scope.ValueKind == JsonValueKind.Object
        && scope.TryGetProperty("model", out var model) && model.ValueKind == JsonValueKind.Object
            ? String(model, "display_name")
            : null;

    static string? String(JsonElement el, string name) =>
        el.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    static double? Number(JsonElement el, string name) =>
        el.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : null;

    static DateTimeOffset? Date(JsonElement el, string name) =>
        String(el, name) is { } s && DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? d : null;
}
