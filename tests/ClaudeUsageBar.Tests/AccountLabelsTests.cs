using System.Text.Json.Nodes;
using ClaudeUsageBar.Core;

namespace ClaudeUsageBar.Tests;

public class AccountLabelsTests
{
    static readonly DateTimeOffset Now = new(2026, 10, 6, 12, 0, 0, TimeSpan.Zero);

    static SavedAccount Saved(AccountLogin login) => new(login, Now);

    [Fact]
    public void Label_IsEmailAndPlan()
    {
        var a = Saved(Logins.Make("a", "jan@firma.pl", tier: "default_claude_max_5x"));

        Assert.Equal("jan@firma.pl · Max 5x", AccountLabels.Label(a, [a]));
    }

    [Fact]
    public void Label_SameEmailAndPlanInTwoOrganizations_AddsTheOrganization()
    {
        var personal = Saved(Logins.Make("a", "jan@firma.pl", orgName: "Personal"));
        var work = Saved(Logins.Make("a", "jan@firma.pl", org: "org-2", orgName: "R&D"));
        IReadOnlyList<SavedAccount> all = [personal, work];

        Assert.Equal("jan@firma.pl · Max 5x · Personal", AccountLabels.Label(personal, all));
        Assert.Equal("jan@firma.pl · Max 5x · R&D", AccountLabels.Label(work, all));
    }

    [Fact]
    public void Ordered_IsAlphabeticalByEmail()
    {
        var z = Saved(Logins.Make("z", "zofia@x.pl"));
        var a = Saved(Logins.Make("a", "Adam@x.pl"));

        Assert.Equal(new[] { "Adam@x.pl", "zofia@x.pl" }, AccountLabels.Ordered([z, a]).Select(s => s.Login.Email));
    }

    [Fact]
    public void ForMenu_KeepsAmpersandsVisible() =>
        Assert.Equal("jan@firma.pl · Max 5x · R&&D", AccountLabels.ForMenu("jan@firma.pl · Max 5x · R&D"));

    [Theory]
    [InlineData(-1, true)]
    [InlineData(0, true)]
    [InlineData(1, false)]
    public void NeedsSignIn_OnceTheRefreshTokenExpired(int hoursFromNow, bool expected) =>
        Assert.Equal(expected, AccountLabels.NeedsSignIn(Saved(Logins.Make("a", "a@x.pl", refreshExpires: Now.AddHours(hoursFromNow))), Now));

    [Fact]
    public void NeedsSignIn_UnknownExpiry_IsFalse()
    {
        var login = Logins.Make("a", "a@x.pl");
        var oauth = (JsonObject)login.Oauth.DeepClone();
        oauth.Remove("refreshTokenExpiresAt");

        Assert.False(AccountLabels.NeedsSignIn(Saved(new AccountLogin(oauth, login.Account)), Now));
    }

    [Theory]
    [InlineData("en", false, "a@x.pl · Max 5x")]
    [InlineData("en", true, "a@x.pl · Max 5x — sign in again")]
    [InlineData("pl", true, "a@x.pl · Max 5x — zaloguj ponownie")]
    public void MenuText_MarksAccountsThatNeedANewLogin(string lang, bool needsSignIn, string expected)
    {
        var a = Saved(Logins.Make("a", "a@x.pl"));

        Assert.Equal(expected, AccountLabels.MenuText(a, [a], needsSignIn, Lang.Get(lang)));
    }
}
