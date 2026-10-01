using System.Text.Json;

namespace ClaudeUsageBar.Core;

public sealed record Credentials(string AccessToken, DateTimeOffset ExpiresAt, string? SubscriptionType, string? RateLimitTier)
{
    // never let the token reach logs through record printing
    public override string ToString() => $"Credentials {{ ExpiresAt = {ExpiresAt:u}, Plan = {RateLimitTier ?? SubscriptionType} }}";
}

public interface ICredentialStore
{
    /// Null when the Claude Code login file is missing, unreadable or has no claude.ai login.
    Credentials? Read();
}

/// Reads the Claude Code CLI login (~/.claude/.credentials.json). Read-only: the CLI owns this file.
public sealed class FileCredentialStore(string path) : ICredentialStore
{
    public static string DefaultPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", ".credentials.json");

    public Credentials? Read()
    {
        try
        {
            // the CLI rewrites the file when it refreshes; share everything so we never block it
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var doc = JsonDocument.Parse(stream);
            if (!doc.RootElement.TryGetProperty("claudeAiOauth", out var oauth) || oauth.ValueKind != JsonValueKind.Object) return null;
            if (String(oauth, "accessToken") is not { Length: > 0 } token) return null;
            var expires = oauth.TryGetProperty("expiresAt", out var e) && e.ValueKind == JsonValueKind.Number
                ? DateTimeOffset.FromUnixTimeMilliseconds(e.GetInt64())
                : DateTimeOffset.MinValue;
            return new Credentials(token, expires, String(oauth, "subscriptionType"), String(oauth, "rateLimitTier"));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            return null;
        }
    }

    static string? String(JsonElement el, string name) =>
        el.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
}
