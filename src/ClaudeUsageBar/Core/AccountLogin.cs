using System.Text.Json;
using System.Text.Json.Nodes;

namespace ClaudeUsageBar.Core;

/// One Claude account: oauthAccount.accountUuid + organizationUuid (one person can be in several organizations).
public readonly record struct AccountKey(string AccountUuid, string OrganizationUuid)
{
    // the log only ever sees uuid prefixes
    public override string ToString() => $"{Short(AccountUuid)}/{Short(OrganizationUuid)}";

    static string Short(string uuid) => uuid.Length > 8 ? uuid[..8] : uuid;
}

/// A Claude Code login as the CLI stores it: `claudeAiOauth` (tokens, plan) and `oauthAccount` (who).
/// Kept as raw JSON copies so fields this app doesn't know (e.g. clientId) are written back unchanged.
public sealed class AccountLogin(JsonObject oauth, JsonObject account)
{
    /// Own copies, detached from the file they came from; DeepClone before putting them into another document.
    public JsonObject Oauth { get; } = (JsonObject)oauth.DeepClone();
    public JsonObject Account { get; } = (JsonObject)account.DeepClone();

    public AccountKey Key => new(String(Account, "accountUuid") ?? "", String(Account, "organizationUuid") ?? "");
    public string Email => String(Account, "emailAddress") ?? "";
    public string? OrganizationName => String(Account, "organizationName");
    public string PlanName => Format.PlanName(String(Oauth, "subscriptionType"), String(Oauth, "rateLimitTier"));

    /// After this the refresh token is dead and only a new `claude auth login` helps; null when the CLI didn't say.
    public DateTimeOffset? RefreshTokenExpiresAt =>
        Oauth["refreshTokenExpiresAt"] is JsonValue v && v.GetValueKind() == JsonValueKind.Number && v.TryGetValue<long>(out var ms)
            ? DateTimeOffset.FromUnixTimeMilliseconds(ms)
            : null;

    /// Same tokens and same account data; a token refresh or a plan change makes them differ.
    public bool SameAs(AccountLogin other) =>
        JsonNode.DeepEquals(Oauth, other.Oauth) && JsonNode.DeepEquals(Account, other.Account);

    // never let tokens reach logs through string formatting
    public override string ToString() => $"{Format.MaskEmail(Email)} {Key}";

    static string? String(JsonObject o, string name) =>
        o[name] is JsonValue v && v.GetValueKind() == JsonValueKind.String ? v.GetValue<string>() : null;
}
