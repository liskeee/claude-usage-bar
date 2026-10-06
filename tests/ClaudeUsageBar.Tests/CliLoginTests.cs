using System.Text.Json.Nodes;
using ClaudeUsageBar.Core;

namespace ClaudeUsageBar.Tests;

public sealed class CliLoginTests : IDisposable
{
    readonly TempDir temp = new();
    readonly AccountLogin a = Logins.Make("a", "a@example.com");
    readonly AccountLogin b = Logins.Make("b", "b@example.com", tier: "default_claude_max_20x");

    string ConfigDir => temp[".claude"];
    string ConfigPath => temp[".claude.json"];
    string CredentialsPath => Path.Combine(ConfigDir, ".credentials.json");

    public void Dispose() => temp.Dispose();

    CliLogin Create(Action<string>? beforeReplace = null) =>
        new(ConfigDir, ConfigPath, temp["backup"]) { BeforeReplace = beforeReplace };

    static JsonObject ReadJson(string path) => JsonNode.Parse(File.ReadAllText(path))!.AsObject();

    [Fact]
    public void ReadCurrent_ReturnsTokensAndAccount()
    {
        Logins.WriteCli(ConfigDir, ConfigPath, a);

        var login = Create().ReadCurrent();

        Assert.NotNull(login);
        Assert.Equal(new AccountKey("acc-a", "org-1"), login.Key);
        Assert.True(login.SameAs(a));
    }

    [Fact]
    public void ReadCurrent_ConfigDirLayout_ReadsTheGlobalConfigInsideTheDir()
    {
        var dir = temp["login-x"];
        Logins.WriteCli(dir, Path.Combine(dir, ".claude.json"), b);

        Assert.Equal("b@example.com", CliLogin.ForConfigDir(dir).ReadCurrent()?.Email);
    }

    [Theory]
    [InlineData("credentials-missing")]
    [InlineData("config-missing")]
    [InlineData("credentials-corrupt")]
    [InlineData("config-corrupt")]
    [InlineData("config-not-an-object")]
    [InlineData("no-claude-login")]
    [InlineData("no-oauth-account")]
    [InlineData("no-account-uuid")]
    public void ReadCurrent_IncompleteLogin_IsNull(string damage)
    {
        Logins.WriteCli(ConfigDir, ConfigPath, a);
        switch (damage)
        {
            case "credentials-missing": File.Delete(CredentialsPath); break;
            case "config-missing": File.Delete(ConfigPath); break;
            case "credentials-corrupt": File.WriteAllText(CredentialsPath, """{"claudeAiOauth":"""); break;
            case "config-corrupt": File.WriteAllText(ConfigPath, "{oops"); break;
            case "config-not-an-object": File.WriteAllText(ConfigPath, "[1,2]"); break;
            case "no-claude-login": File.WriteAllText(CredentialsPath, """{"mcpOAuth":{}}"""); break;
            case "no-oauth-account": File.WriteAllText(ConfigPath, """{"numStartups":1}"""); break;
            case "no-account-uuid": File.WriteAllText(ConfigPath, """{"oauthAccount":{"emailAddress":"a@example.com"}}"""); break;
        }

        Assert.Null(Create().ReadCurrent());
    }

    [Fact]
    public void Write_ReplacesOnlyTheLoginKeys()
    {
        Logins.WriteCli(ConfigDir, ConfigPath, a);
        var credentialsBefore = ReadJson(CredentialsPath);
        var configBefore = ReadJson(ConfigPath);

        Create().Write(b);

        var credentials = ReadJson(CredentialsPath);
        var config = ReadJson(ConfigPath);
        Assert.True(JsonNode.DeepEquals(b.Oauth, credentials["claudeAiOauth"]));
        Assert.True(JsonNode.DeepEquals(b.Account, config["oauthAccount"]));
        credentials.Remove("claudeAiOauth");
        credentialsBefore.Remove("claudeAiOauth");
        config.Remove("oauthAccount");
        configBefore.Remove("oauthAccount");
        foreach (var cache in CliLogin.AccountCaches) configBefore.Remove(cache);
        Assert.True(JsonNode.DeepEquals(credentialsBefore, credentials)); // mcpOAuth intact
        Assert.True(JsonNode.DeepEquals(configBefore, config));           // projects, unknown keys, other caches intact
    }

    [Fact]
    public void Write_DropsAccountCaches_KeepsOtherCaches()
    {
        Logins.WriteCli(ConfigDir, ConfigPath, a);

        Create().Write(b);

        var config = ReadJson(ConfigPath);
        Assert.False(config.ContainsKey("modelAccessCache"));
        Assert.False(config.ContainsKey("cachedUsageUtilization"));
        Assert.True(config.ContainsKey("cachedGrowthBookFeatures"));
    }

    [Fact]
    public void Write_KeepsNonAsciiReadable()
    {
        Logins.WriteCli(ConfigDir, ConfigPath, a);

        Create().Write(b);

        var text = File.ReadAllText(ConfigPath);
        Assert.Contains("C:/Users/Łukasz/zażółć gęślą", text);
        Assert.DoesNotContain("\\u", text);
    }

    [Fact]
    public void Write_KeepsUnknownFieldsOfTheLogin()
    {
        Logins.WriteCli(ConfigDir, ConfigPath, a);
        var oauth = (JsonObject)b.Oauth.DeepClone();
        oauth["clientId"] = "client-123";

        Create().Write(new AccountLogin(oauth, b.Account));

        Assert.Equal("client-123", (string?)ReadJson(CredentialsPath)["claudeAiOauth"]!["clientId"]);
    }

    [Fact]
    public void Write_ThenReadCurrent_IsTheNewAccount()
    {
        Logins.WriteCli(ConfigDir, ConfigPath, a);
        var cli = Create();

        cli.Write(b);

        Assert.True(cli.ReadCurrent()!.SameAs(b));
    }

    [Fact]
    public void Write_WithoutACredentialsFile_CreatesIt()
    {
        Logins.WriteCli(ConfigDir, ConfigPath, a);
        File.Delete(CredentialsPath);
        var cli = Create();

        cli.Write(b);

        Assert.True(cli.ReadCurrent()!.SameAs(b));
    }

    [Fact]
    public void Write_BacksUpBothFilesFirst()
    {
        Logins.WriteCli(ConfigDir, ConfigPath, a);
        var credentials = File.ReadAllText(CredentialsPath);
        var config = File.ReadAllText(ConfigPath);

        Create().Write(b);

        Assert.Equal(credentials, File.ReadAllText(Path.Combine(temp["backup"], ".credentials.json")));
        Assert.Equal(config, File.ReadAllText(Path.Combine(temp["backup"], ".claude.json")));
    }

    [Fact]
    public void Write_LeavesNoTempFiles()
    {
        Logins.WriteCli(ConfigDir, ConfigPath, a);

        Create().Write(b);

        Assert.Empty(Directory.GetFiles(ConfigDir, "*.tmp"));
        Assert.Empty(Directory.GetFiles(temp.Root, "*.tmp"));
    }

    [Fact]
    public void Write_RetriesWhenARunningSessionWritesTheConfig()
    {
        Logins.WriteCli(ConfigDir, ConfigPath, a);
        int calls = 0;
        var cli = Create(path =>
        {
            if (path != ConfigPath || calls++ > 0) return;
            var config = ReadJson(ConfigPath);
            config["lastSessionId"] = "written-by-a-running-session";
            File.WriteAllText(ConfigPath, config.ToJsonString());
        });

        cli.Write(b);

        var after = ReadJson(ConfigPath);
        Assert.Equal("written-by-a-running-session", (string?)after["lastSessionId"]);
        Assert.True(JsonNode.DeepEquals(b.Account, after["oauthAccount"]));
        Assert.Equal(2, calls);
    }

    [Fact]
    public void Write_GivesUpAfterThreeAttempts_AndLeavesTheOldLogin()
    {
        Logins.WriteCli(ConfigDir, ConfigPath, a);
        var credentialsBefore = File.ReadAllText(CredentialsPath);
        int n = 0;
        // trailing spaces keep the JSON valid but change its size every time
        var cli = Create(path => { if (path == ConfigPath) File.AppendAllText(ConfigPath, new string(' ', ++n)); });

        Assert.Throws<IOException>(() => cli.Write(b));

        Assert.Equal(3, n);
        Assert.Equal(credentialsBefore, File.ReadAllText(CredentialsPath));
        Assert.True(Create().ReadCurrent()!.SameAs(a));
    }

    [Fact]
    public void Write_DamagedConfig_Throws_AndKeepsTheCredentials()
    {
        Logins.WriteCli(ConfigDir, ConfigPath, a);
        var credentialsBefore = File.ReadAllText(CredentialsPath);
        File.WriteAllText(ConfigPath, "{oops");

        Assert.Throws<IOException>(() => Create().Write(b));

        Assert.Equal(credentialsBefore, File.ReadAllText(CredentialsPath));
        Assert.Equal("{oops", File.ReadAllText(ConfigPath));
    }
}
