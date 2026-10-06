using System.Text.Json.Nodes;
using ClaudeUsageBar.Core;

namespace ClaudeUsageBar.Tests;

static class Fixtures
{
    /// Real /api/oauth/usage response captured on 2026-10-01 13:41 (no secrets inside).
    public static string Usage => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "usage-2026-10-01.json"));
}

static class Lang
{
    public static readonly Texts En = Texts.Load("en");
    public static readonly Texts Pl = Texts.Load("pl");
    public static Texts Get(string code) => code == "pl" ? Pl : En;
}

sealed class FakeClock(DateTimeOffset now) : TimeProvider
{
    public DateTimeOffset Now { get; set; } = now;
    public override DateTimeOffset GetUtcNow() => Now.ToUniversalTime();
}

sealed class FakeCreds : ICredentialStore
{
    public Credentials? Current { get; set; }
    public Credentials? Read() => Current;
}

sealed class FakeRenewer : ITokenRenewer
{
    public int Calls { get; private set; }
    public Func<bool> OnRenew { get; set; } = () => false;

    public Task<bool> TryRenewAsync(CancellationToken ct)
    {
        Calls++;
        return Task.FromResult(OnRenew());
    }
}

sealed class FakeApi : IUsageApi
{
    public List<string> Tokens { get; } = [];
    public Func<string, UsageApiResult> Respond { get; set; } = _ => new(ApiStatus.Ok, Fixtures.Usage);

    public Task<UsageApiResult> FetchAsync(string accessToken, CancellationToken ct)
    {
        Tokens.Add(accessToken);
        return Task.FromResult(Respond(accessToken));
    }
}

/// A fresh directory under %TEMP%, deleted afterwards.
sealed class TempDir : IDisposable
{
    public string Root { get; } = Directory.CreateTempSubdirectory("cub-test-").FullName;

    public string this[string relative] => Path.Combine(Root, relative);

    public void Dispose()
    {
        try { Directory.Delete(Root, recursive: true); }
        catch (IOException) { }
    }
}

/// Logins shaped like Claude Code 2.1's files; every token is fake.
static class Logins
{
    public static AccountLogin Make(string id, string email, string token = "1", string org = "org-1", string? orgName = null,
        string tier = "default_claude_max_5x", DateTimeOffset? refreshExpires = null) =>
        new(new JsonObject
            {
                ["accessToken"] = $"access-{id}-{token}",
                ["refreshToken"] = $"refresh-{id}-{token}",
                ["expiresAt"] = 1790271138070,
                ["refreshTokenExpiresAt"] = (refreshExpires ?? new DateTimeOffset(2026, 11, 1, 0, 0, 0, TimeSpan.Zero)).ToUnixTimeMilliseconds(),
                ["scopes"] = new JsonArray("user:inference", "user:profile"),
                ["subscriptionType"] = "max",
                ["rateLimitTier"] = tier,
            },
            new JsonObject
            {
                ["accountUuid"] = $"acc-{id}",
                ["emailAddress"] = email,
                ["organizationUuid"] = org,
                ["organizationName"] = orgName ?? $"{email}'s Organization",
                ["displayName"] = id,
            });

    /// Writes `login` the way the CLI stores it, next to content that must survive a switch.
    public static void WriteCli(string configDir, string globalConfigPath, AccountLogin login)
    {
        Directory.CreateDirectory(configDir);
        File.WriteAllText(Path.Combine(configDir, ".credentials.json"), $$"""
            {"mcpOAuth":{"srv|abc":{"serverName":"srv","accessToken":"mcp-token"} },"claudeAiOauth":{{login.Oauth.ToJsonString()}} }
            """);
        File.WriteAllText(globalConfigPath, $$"""
            {
              "numStartups": 5,
              "projects": { "C:/Users/Łukasz/zażółć gęślą": { "allowedTools": [] } },
              "someFutureSetting": { "nested": [1, 2.50, "x"] },
              "cachedGrowthBookFeatures": { "flag": true },
              "oauthAccount": {{login.Account.ToJsonString()}},
              "modelAccessCache": { "opus": true },
              "cachedUsageUtilization": 0.42
            }
            """);
    }

    public static string AccessToken(AccountLogin login) => login.Oauth["accessToken"]!.GetValue<string>();
}
