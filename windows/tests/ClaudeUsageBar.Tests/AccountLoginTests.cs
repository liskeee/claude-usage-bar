using System.Text.Json.Nodes;
using ClaudeUsageBar.Core;

namespace ClaudeUsageBar.Tests;

public class AccountLoginTests
{
    static readonly DateTimeOffset Expiry = new(2026, 11, 5, 0, 0, 0, TimeSpan.Zero);

    [Fact]
    public void ReadsKeyEmailPlanAndRefreshExpiry()
    {
        var login = Logins.Make("a", "a@example.com", tier: "default_claude_max_20x", refreshExpires: Expiry);

        Assert.Equal(new AccountKey("acc-a", "org-1"), login.Key);
        Assert.Equal("a@example.com", login.Email);
        Assert.Equal("a@example.com's Organization", login.OrganizationName);
        Assert.Equal("Max 20x", login.PlanName);
        Assert.Equal(Expiry, login.RefreshTokenExpiresAt);
    }

    [Fact]
    public void MissingRefreshExpiry_IsNull()
    {
        var a = Logins.Make("a", "a@example.com");
        var oauth = (JsonObject)a.Oauth.DeepClone();
        oauth.Remove("refreshTokenExpiresAt");

        Assert.Null(new AccountLogin(oauth, a.Account).RefreshTokenExpiresAt);
    }

    [Fact]
    public void SameAs_ComparesTokensAndAccount()
    {
        Assert.True(Logins.Make("a", "a@example.com").SameAs(Logins.Make("a", "a@example.com")));
        Assert.False(Logins.Make("a", "a@example.com").SameAs(Logins.Make("a", "a@example.com", token: "2")));
        Assert.False(Logins.Make("a", "a@example.com").SameAs(Logins.Make("a", "a@example.com", tier: "default_claude_max_20x")));
    }

    [Fact]
    public void KeepsItsOwnCopyOfTheJson()
    {
        var file = JsonNode.Parse("""{"claudeAiOauth":{"accessToken":"t1"},"oauthAccount":{"accountUuid":"u"}}""")!.AsObject();
        var login = new AccountLogin(file["claudeAiOauth"]!.AsObject(), file["oauthAccount"]!.AsObject());

        file["claudeAiOauth"]!["accessToken"] = "changed";

        Assert.Equal("t1", Logins.AccessToken(login));
        Assert.NotNull(new JsonObject { ["copy"] = login.Oauth.DeepClone() }); // detached from the file's tree
    }

    [Fact]
    public void ToString_ShowsNoTokensAndNoFullEmail()
    {
        var text = Logins.Make("a", "alice@example.com").ToString();

        Assert.DoesNotContain("access-", text);
        Assert.DoesNotContain("refresh-", text);
        Assert.DoesNotContain("alice@", text);
        Assert.Contains("a***@example.com", text);
    }
}
