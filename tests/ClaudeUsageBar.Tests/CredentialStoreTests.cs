using ClaudeUsageBar.Core;

namespace ClaudeUsageBar.Tests;

public sealed class CredentialStoreTests : IDisposable
{
    readonly string path = Path.Combine(Path.GetTempPath(), $"clb-test-{Guid.NewGuid():N}.json");

    public void Dispose() => File.Delete(path);

    [Fact]
    public void Read_ParsesTokenExpiryAndPlan()
    {
        File.WriteAllText(path, """
            {"mcpOAuth":{},"claudeAiOauth":{"accessToken":"test-token","refreshToken":"test-refresh","expiresAt":1790271138070,"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}
            """);

        var c = new FileCredentialStore(path).Read();

        Assert.NotNull(c);
        Assert.Equal("test-token", c.AccessToken);
        Assert.Equal(DateTimeOffset.FromUnixTimeMilliseconds(1790271138070), c.ExpiresAt);
        Assert.Equal("max", c.SubscriptionType);
        Assert.Equal("default_claude_max_20x", c.RateLimitTier);
    }

    [Fact]
    public void Read_MissingFile_ReturnsNull() => Assert.Null(new FileCredentialStore(path).Read());

    [Fact]
    public void Read_MalformedJson_ReturnsNull()
    {
        File.WriteAllText(path, "{not json");
        Assert.Null(new FileCredentialStore(path).Read());
    }

    [Fact]
    public void Read_WithoutClaudeLogin_ReturnsNull()
    {
        File.WriteAllText(path, """{"mcpOAuth":{}}""");
        Assert.Null(new FileCredentialStore(path).Read());
    }

    [Fact]
    public void ToString_DoesNotLeakToken() =>
        Assert.DoesNotContain("secret-value", new Credentials("secret-value", DateTimeOffset.UnixEpoch, null, null).ToString());
}
