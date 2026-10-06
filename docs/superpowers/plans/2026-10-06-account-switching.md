# Account Switching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** From the taskbar menu, switch the account Claude Code CLI is signed in with. Switching needs no browser round-trip, and the bar shows only the active account's usage.

**Architecture:** Three new `Core/` classes. `CliLogin` is the only code that writes Claude Code's files: it swaps `claudeAiOauth` in `.credentials.json` and `oauthAccount` in the global config, atomically and with retries. `AccountStore` keeps the saved logins in a DPAPI-encrypted `accounts.dat`. `AccountSwitcher` does the orchestration: it syncs the active login into the store, switches, adds an account through an isolated `claude auth login` (with `CLAUDE_CONFIG_DIR` set to a temp dir) and removes accounts. `UsageService.Reset()` makes sure the old account's numbers never appear under the new one. A `SemaphoreSlim` shared by the token renewer and the switcher stops a `claude -p` renewal from writing the old account's tokens over a fresh switch.

**Tech Stack:** C# / .NET 9 (`net9.0-windows`), WinForms, `System.Text.Json.Nodes`, `System.Security.Cryptography.ProtectedData` (new), xUnit 2.9.

**Spec:** `docs/superpowers/specs/2026-10-06-account-switching-design.md`

## Global Constraints

- Target framework stays `net9.0-windows`. The only new package is `System.Security.Cryptography.ProtectedData`.
- The app never runs `claude auth logout`. It never runs `claude auth login` against `~/.claude`, only with `CLAUDE_CONFIG_DIR=<temp>`.
- In Claude Code files, the app changes only `claudeAiOauth` (`.credentials.json`) and `oauthAccount` (global config), and removes these caches: `subscriptionNoticeCount`, `hasAvailableSubscription`, `additionalModelOptionsCache`, `additionalModelOptionsAnsweredAt`, `additionalModelCostsCache`, `modelAccessCache`, `orgModelDefaultCache`, `cachedArtifactRoster`, `artifactRosterDenied`, `lastSeenOrgDefaultUpdatedAt`, `clientDataCache`, `clientDataCacheSlots`, `autoCompactWindowsCache`, `cachedUsageUtilization`.
- Global config: `~/.claude.json` for the default dir, `<dir>/.claude.json` for a `CLAUDE_CONFIG_DIR`.
- Each file is written atomically (temp file in the same dir, then replace). Optimistic concurrency on mtime/size, up to 3 attempts.
- Before each write, both files are copied to `%LOCALAPPDATA%\ClaudeUsageBar\backup\` (last one only).
- JSON is written indented, with `JavaScriptEncoder.UnsafeRelaxedJsonEscaping` (non-ASCII is not escaped).
- `%LOCALAPPDATA%\ClaudeUsageBar\accounts.dat` is DPAPI-encrypted (CurrentUser). An unreadable file is renamed to `accounts.dat.bad` and the list starts empty.
- Tokens never reach the log: only masked e-mails (`l***@gmail.com`) and uuid prefixes.
- Every UI text goes in both `Localization/en.json` and `Localization/pl.json`.
- Code style follows the repo: file-scoped namespaces, primary constructors, one-line `///` doc comments, and short comments that explain *why*.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **A refresh or `claude -p` renewal is in flight while the user switches.** The old account's numbers must not appear under the new one, and the renewal must not write the old account's rotated tokens over the new login. Pinned in Task 3 (`RefreshStartedBeforeReset_*`, `Renewal_WaitsForTheCliLock`) and Task 4 (`SwitchTo_WaitsWhileTheCliIsRenewingItsToken`).
2. **Signing in again to the account that is already active** (its refresh token died). The pre-switch capture must not overwrite the fresh tokens with the dead ones. Pinned in Task 4 (`AddAccount_FreshLoginOfTheActiveAccount_ReplacesItsDeadTokens`).
3. **A running Claude Code session rewrites `~/.claude.json` mid-swap.** The app retries and keeps the session's change. After 3 attempts it gives up, and the credentials file is restored so tokens and account never disagree. Pinned in Task 1 (`Write_RetriesWhen…`, `Write_GivesUpAfterThreeAttempts…`).
4. **The app is killed during an add-account login.** A `login-<guid>` dir holding live tokens is left behind, and the next login deletes it. A locked `accounts.dat` must not be mistaken for a damaged one and thrown away. Pinned in Task 4 (`AddAccount_RemovesLoginDirsLeftByAnEarlierCrash`) and Task 2 (`LockedFile_IsNotMistakenForADamagedOne`).
5. **Unusual account names.** Two accounts can share an e-mail and plan, organization names can contain `&` (a menu mnemonic), and an e-mail can contain characters cmd.exe interprets. Labels must stay distinct, and nothing may be injected into the console command. Pinned in Task 5 (`Label_SameEmailAndPlan…`, `ForMenu_KeepsAmpersandsVisible`) and Task 6 (`CommandLine_DropsAnEmailCmdWouldInterpret`, `EveryLanguage_LoginHint_IsSafeForCmd`).

## Where this plan fills spec gaps (deliberate)

- The token renewer and `AccountSwitcher` share a CLI lock (Review Focus 1). The spec is silent here, but without the lock a renewal running during a switch could leave tokens of account A under account B's name.
- `UsageService.Reset()` also drops a refresh that is still in flight and clears the renewer's 30-minute throttle. Without that, an account switched to with an expired access token could show "sign in" for up to 30 minutes.
- `SavedAccount` stores the raw login plus `SavedAt`. E-mail, organization, plan and `refreshTokenExpiresAt` are read from that raw JSON, not copied.
- `AddAccount` captures the active login *after* the browser login finishes (tokens may rotate in the meantime). It writes the new login even when it is the same account (Review Focus 2).
- `SwitchToAsync` is async because it waits for the CLI lock. `App` calls `UsageService.Reset()` from `AccountSwitcher.Switched`, so `Core` doesn't depend on the UI timers.
- The active account is also marked "sign in again" while the service reports `NeedsLogin` (spec: Error handling, first bullet).

## File map

| File | Status | Responsibility |
|---|---|---|
| `src/ClaudeUsageBar/Core/AccountLogin.cs` | create | `AccountKey`, `AccountLogin` (raw `claudeAiOauth` + `oauthAccount`, derived fields) |
| `src/ClaudeUsageBar/Core/CliLogin.cs` | create | read/write the CLI login files |
| `src/ClaudeUsageBar/Core/AccountStore.cs` | create | `SavedAccount`, encrypted `accounts.dat` |
| `src/ClaudeUsageBar/Core/AccountSwitcher.cs` | create | `AccountError`, `AccountException`, sync/switch/add/remove |
| `src/ClaudeUsageBar/Core/AccountLabels.cs` | create | menu wording, ordering, "sign in again" |
| `src/ClaudeUsageBar/Core/LoginRunner.cs` | create | console window running `claude auth login` |
| `src/ClaudeUsageBar/Core/Format.cs` | modify | `MaskEmail` |
| `src/ClaudeUsageBar/Core/TokenRenewer.cs` | modify | `Reset()`, CLI lock, `ClearClaudeEnvironment` |
| `src/ClaudeUsageBar/Core/UsageService.cs` | modify | `Reset()`, discard stale refresh |
| `src/ClaudeUsageBar/Core/Texts.cs`, `Localization/*.json` | modify | `accounts` texts |
| `src/ClaudeUsageBar/UI/Primitives.cs` | modify | `Ellipsize` |
| `src/ClaudeUsageBar/UI/DetailsRenderer.cs`, `UI/DetailsPopup.cs` | modify | account e-mail in the header |
| `src/ClaudeUsageBar/App.cs`, `Program.cs` | modify | menu, wiring |
| `src/ClaudeUsageBar/ClaudeUsageBar.csproj` | modify | ProtectedData package |
| `tests/ClaudeUsageBar.Tests/TestSupport.cs` | modify | `TempDir`, `Logins`, fakes |
| `tests/ClaudeUsageBar.Tests/*Tests.cs` | create/modify | one test file per class |
| `README.md` | modify | accounts section, files |

Run tests with `dotnet test ClaudeUsageBar.sln --nologo` from the repo root. The machine's locale is Polish, so the summary line reads `Powodzenie!` on success and `Niepowodzenie!` on failure. Narrow a run with `--filter "FullyQualifiedName~<ClassName>"`. Baseline: 122 tests pass.

---

### Task 1: `AccountLogin` and `CliLogin`: read and swap the Claude Code login

**Files:**
- Create: `src/ClaudeUsageBar/Core/AccountLogin.cs`
- Create: `src/ClaudeUsageBar/Core/CliLogin.cs`
- Modify: `src/ClaudeUsageBar/Core/Format.cs` (add `MaskEmail`)
- Modify: `tests/ClaudeUsageBar.Tests/TestSupport.cs` (add `TempDir`, `Logins`)
- Create: `tests/ClaudeUsageBar.Tests/AccountLoginTests.cs`
- Create: `tests/ClaudeUsageBar.Tests/CliLoginTests.cs`
- Modify: `tests/ClaudeUsageBar.Tests/FormatTests.cs`

**Interfaces:**
- Consumes: `Format.PlanName(string?, string?)`, `Log.Write(string)` (existing).
- Produces:
  - `public readonly record struct AccountKey(string AccountUuid, string OrganizationUuid)`; its `ToString()` gives uuid prefixes only.
  - `public sealed class AccountLogin(JsonObject oauth, JsonObject account)` with `JsonObject Oauth`, `JsonObject Account` (own deep copies; treat as read-only and `DeepClone()` before inserting elsewhere), `AccountKey Key`, `string Email`, `string? OrganizationName`, `string PlanName`, `DateTimeOffset? RefreshTokenExpiresAt`, `bool SameAs(AccountLogin)`, and a masked `ToString()`.
  - `public sealed class CliLogin(string configDir, string globalConfigPath, string? backupDir = null)` with `static CliLogin Default(string backupDir)`, `static CliLogin ForConfigDir(string dir)`, `static IReadOnlyList<string> AccountCaches`, `Action<string>? BeforeReplace { get; init; }` (test hook, receives the path about to be replaced), `AccountLogin? ReadCurrent()`, and `void Write(AccountLogin)`. `Write` throws `IOException` on failure, and the files then keep the old login.
  - `public static string Format.MaskEmail(string email)`
  - Test helpers: `TempDir` (`Root`, indexer `this[string relative]`), `Logins.Make(...)`, `Logins.WriteCli(configDir, globalConfigPath, login)`, `Logins.AccessToken(login)`.

- [ ] **Step 1: Add the test helpers**

Append to `tests/ClaudeUsageBar.Tests/TestSupport.cs`. Add `using System.Text.Json.Nodes;` at the top, next to the existing `using ClaudeUsageBar.Core;`.

```csharp
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
```

- [ ] **Step 2: Write the failing tests**

Add to `tests/ClaudeUsageBar.Tests/FormatTests.cs`, inside the class:

```csharp
    [Theory]
    [InlineData("lukasz@gmail.com", "l***@gmail.com")]
    [InlineData("a@b.pl", "a***@b.pl")]
    [InlineData("no-at-sign", "***")]
    [InlineData("", "***")]
    public void MaskEmail_KeepsFirstLetterAndDomain(string email, string expected) =>
        Assert.Equal(expected, Format.MaskEmail(email));
```

Create `tests/ClaudeUsageBar.Tests/AccountLoginTests.cs`:

```csharp
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
```

Create `tests/ClaudeUsageBar.Tests/CliLoginTests.cs`:

```csharp
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `dotnet test ClaudeUsageBar.sln --nologo --filter "FullyQualifiedName~CliLoginTests|FullyQualifiedName~AccountLoginTests|FullyQualifiedName~FormatTests"`
Expected: build FAILS with `error CS0246: The type or namespace name 'AccountLogin' could not be found` (and `CliLogin`, `AccountKey`) and `'Format' does not contain a definition for 'MaskEmail'`.

- [ ] **Step 4: Implement `Format.MaskEmail`**

In `src/ClaudeUsageBar/Core/Format.cs`, add after `PlanName`:

```csharp
    /// "lukasz@gmail.com" → "l***@gmail.com": enough to tell accounts apart in the log.
    public static string MaskEmail(string email)
    {
        int at = email.IndexOf('@');
        return at <= 0 ? "***" : $"{email[0]}***{email[at..]}";
    }
```

- [ ] **Step 5: Implement `AccountLogin`**

Create `src/ClaudeUsageBar/Core/AccountLogin.cs`:

```csharp
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
```

- [ ] **Step 6: Implement `CliLogin`**

Create `src/ClaudeUsageBar/Core/CliLogin.cs`:

```csharp
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ClaudeUsageBar.Core;

/// The Claude Code CLI login on disk: `claudeAiOauth` in <configDir>\.credentials.json and `oauthAccount` in the
/// global config. The only code that writes Claude Code's files: it replaces those two keys, drops the
/// account-scoped caches (as `claude auth logout` does) and leaves everything else as it was.
public sealed class CliLogin(string configDir, string globalConfigPath, string? backupDir = null)
{
    const int Attempts = 3;

    /// Global config keys Claude Code removes on logout: they describe the previous account.
    public static readonly IReadOnlyList<string> AccountCaches =
    [
        "subscriptionNoticeCount", "hasAvailableSubscription", "additionalModelOptionsCache", "additionalModelOptionsAnsweredAt",
        "additionalModelCostsCache", "modelAccessCache", "orgModelDefaultCache", "cachedArtifactRoster", "artifactRosterDenied",
        "lastSeenOrgDefaultUpdatedAt", "clientDataCache", "clientDataCacheSlots", "autoCompactWindowsCache", "cachedUsageUtilization",
    ];

    static readonly JsonSerializerOptions WriteOptions = new()
    {
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping, // keep non-ASCII paths and names as the CLI wrote them
    };
    static readonly UTF8Encoding Utf8NoBom = new(encoderShouldEmitUTF8Identifier: false);

    /// Test hook: runs between reading a file and replacing it, where a running Claude Code session may write it.
    public Action<string>? BeforeReplace { get; init; }

    string CredentialsPath => Path.Combine(configDir, ".credentials.json");

    /// The CLI login in the user's home: ~\.claude\.credentials.json and ~\.claude.json.
    public static CliLogin Default(string backupDir)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        return new(Path.Combine(home, ".claude"), Path.Combine(home, ".claude.json"), backupDir);
    }

    /// The login of a CLI run with CLAUDE_CONFIG_DIR=<dir>, which keeps its global config in <dir>\.claude.json.
    public static CliLogin ForConfigDir(string dir) => new(dir, Path.Combine(dir, ".claude.json"));

    /// Null when a file is missing or unreadable, or holds no claude.ai login.
    public AccountLogin? ReadCurrent()
    {
        try
        {
            if (Load(CredentialsPath)?.Root["claudeAiOauth"] is not JsonObject oauth) return null;
            if (Load(globalConfigPath)?.Root["oauthAccount"] is not JsonObject account) return null;
            var login = new AccountLogin(oauth, account);
            return login.Key.AccountUuid.Length > 0 ? login : null;
        }
        catch (IOException) { return null; }
    }

    /// Makes `login` the CLI's login. Throws IOException when a file can't be written; both files then keep the old login.
    public void Write(AccountLogin login)
    {
        try { Backup(); }
        catch (UnauthorizedAccessException ex) { throw new IOException(ex.Message, ex); }

        var credentialsBefore = Update(CredentialsPath, root => root["claudeAiOauth"] = login.Oauth.DeepClone());
        try
        {
            Update(globalConfigPath, root =>
            {
                root["oauthAccount"] = login.Account.DeepClone();
                foreach (var key in AccountCaches) root.Remove(key);
            });
        }
        catch (IOException)
        {
            Restore(CredentialsPath, credentialsBefore); // one account's tokens under another account's name would be worse
            throw;
        }
    }

    void Backup()
    {
        if (backupDir is null) return;
        Directory.CreateDirectory(backupDir);
        foreach (var path in new[] { CredentialsPath, globalConfigPath })
            if (File.Exists(path)) File.Copy(path, Path.Combine(backupDir, Path.GetFileName(path)), overwrite: true);
    }

    /// Read → edit → atomic replace. Running Claude Code sessions rewrite ~\.claude.json often: when the file changed
    /// after we read it, start over from its new content. Returns the file as it was before the edit (null: no file).
    FileState? Update(string path, Action<JsonObject> edit)
    {
        for (int attempt = 1; ; attempt++)
        {
            try
            {
                var before = Load(path);
                var root = before?.Root ?? new JsonObject();
                edit(root);
                var temp = WriteTemp(path, root.ToJsonString(WriteOptions));
                try
                {
                    BeforeReplace?.Invoke(path);
                    if (ChangedSince(path, before)) throw new IOException($"{Path.GetFileName(path)} changed while being updated");
                    File.Move(temp, path, overwrite: true);
                }
                finally { File.Delete(temp); }
                return before;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                Log.Write($"login: {Path.GetFileName(path)}, attempt {attempt} of {Attempts}: {ex.Message}");
                if (attempt == Attempts) throw new IOException($"{Path.GetFileName(path)} not written: {ex.Message}", ex);
                Thread.Sleep(50 * attempt);
            }
        }
    }

    void Restore(string path, FileState? before)
    {
        try
        {
            if (before is null) { File.Delete(path); return; }
            File.Move(WriteTemp(path, before.Text), path, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Write($"login: couldn't restore {Path.GetFileName(path)}: {ex.Message}");
        }
    }

    static string WriteTemp(string path, string text)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = $"{path}.{Guid.NewGuid():N}.tmp";
        File.WriteAllText(temp, text, Utf8NoBom);
        return temp;
    }

    static bool ChangedSince(string path, FileState? before)
    {
        var now = new FileInfo(path);
        if (before is null) return now.Exists;
        return !now.Exists || now.LastWriteTimeUtc != before.WriteTimeUtc || now.Length != before.Length;
    }

    sealed record FileState(JsonObject Root, string Text, DateTime WriteTimeUtc, long Length);

    /// Null when the file doesn't exist; IOException when it can't be read or isn't a JSON object.
    static FileState? Load(string path)
    {
        var info = new FileInfo(path); // taken before reading: a write after this point counts as a change
        if (!info.Exists) return null;
        try
        {
            string text;
            // the CLI rewrites these files at any time; share everything so we never block it
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (var reader = new StreamReader(stream, Encoding.UTF8))
                text = reader.ReadToEnd();
            var root = JsonNode.Parse(text) as JsonObject ?? throw new JsonException("not a JSON object");
            return new FileState(root, text, info.LastWriteTimeUtc, info.Length);
        }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
        catch (JsonException ex) { throw new IOException($"{Path.GetFileName(path)} is not valid JSON", ex); }
        catch (UnauthorizedAccessException ex) { throw new IOException(ex.Message, ex); }
    }
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `dotnet test ClaudeUsageBar.sln --nologo --filter "FullyQualifiedName~CliLoginTests|FullyQualifiedName~AccountLoginTests|FullyQualifiedName~FormatTests"`
Expected: PASS. Then run the full suite (`dotnet test ClaudeUsageBar.sln --nologo`): all green.

- [ ] **Step 8: Commit**

```bash
git add src/ClaudeUsageBar/Core/AccountLogin.cs src/ClaudeUsageBar/Core/CliLogin.cs src/ClaudeUsageBar/Core/Format.cs tests/ClaudeUsageBar.Tests/TestSupport.cs tests/ClaudeUsageBar.Tests/AccountLoginTests.cs tests/ClaudeUsageBar.Tests/CliLoginTests.cs tests/ClaudeUsageBar.Tests/FormatTests.cs
git commit -m "feat: read and swap the Claude Code CLI login (CliLogin)

Only claudeAiOauth and oauthAccount change; account caches are dropped as on logout.
Atomic writes, retry when a running session rewrites ~/.claude.json, backup first.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `AccountStore`: saved accounts encrypted with DPAPI

**Files:**
- Modify: `src/ClaudeUsageBar/ClaudeUsageBar.csproj` (package)
- Create: `src/ClaudeUsageBar/Core/AccountStore.cs`
- Create: `tests/ClaudeUsageBar.Tests/AccountStoreTests.cs`

**Interfaces:**
- Consumes: `AccountLogin`, `AccountKey`, `Log.Write` (Task 1); test helpers `TempDir`, `Logins`.
- Produces:
  - `public sealed record SavedAccount(AccountLogin Login, DateTimeOffset SavedAt)` with `AccountKey Key`.
  - `public sealed class AccountStore(string path)` with `IReadOnlyList<SavedAccount> All` (loaded lazily; throws `IOException` while the file is locked), `SavedAccount? Find(AccountKey)`, `void Upsert(SavedAccount)` (replaces the entry with the same key in place, otherwise appends), and `void Remove(AccountKey)`.
  - File format, decrypted: `{"version":1,"accounts":[{"savedAt":"<ISO 8601 \"O\">","claudeAiOauth":{…},"oauthAccount":{…}}]}`. It is encrypted with `ProtectedData.Protect(bytes, entropy: UTF-8 "ClaudeUsageBar.accounts.v1", DataProtectionScope.CurrentUser)`.

- [ ] **Step 1: Add the package**

Run: `dotnet add src/ClaudeUsageBar/ClaudeUsageBar.csproj package System.Security.Cryptography.ProtectedData --version 9.0.0`
Expected: the csproj gets `<PackageReference Include="System.Security.Cryptography.ProtectedData" Version="9.0.0" />`. The test project picks it up through its project reference.

- [ ] **Step 2: Write the failing tests**

Create `tests/ClaudeUsageBar.Tests/AccountStoreTests.cs`:

```csharp
using System.Security.Cryptography;
using System.Text;
using ClaudeUsageBar.Core;

namespace ClaudeUsageBar.Tests;

public sealed class AccountStoreTests : IDisposable
{
    static readonly DateTimeOffset SavedAt = new(2026, 10, 6, 10, 0, 0, TimeSpan.Zero);
    readonly TempDir temp = new();
    readonly AccountLogin a = Logins.Make("a", "a@example.com");

    string StorePath => temp["data/accounts.dat"];

    public void Dispose() => temp.Dispose();

    [Fact]
    public void MissingFile_IsAnEmptyList() => Assert.Empty(new AccountStore(StorePath).All);

    [Fact]
    public void Upsert_SurvivesARestart()
    {
        new AccountStore(StorePath).Upsert(new SavedAccount(a, SavedAt));

        var loaded = Assert.Single(new AccountStore(StorePath).All);
        Assert.Equal(a.Key, loaded.Key);
        Assert.Equal(SavedAt, loaded.SavedAt);
        Assert.True(loaded.Login.SameAs(a));
    }

    [Fact]
    public void File_IsEncrypted()
    {
        new AccountStore(StorePath).Upsert(new SavedAccount(a, SavedAt));

        var raw = Encoding.Latin1.GetString(File.ReadAllBytes(StorePath));
        Assert.DoesNotContain("a@example.com", raw);
        Assert.DoesNotContain("refresh-a-1", raw);
    }

    [Fact]
    public void Upsert_SameKey_ReplacesTheEntry()
    {
        var store = new AccountStore(StorePath);
        store.Upsert(new SavedAccount(a, SavedAt));

        store.Upsert(new SavedAccount(Logins.Make("a", "a@example.com", token: "2"), SavedAt.AddHours(1)));

        var saved = Assert.Single(new AccountStore(StorePath).All);
        Assert.Equal("access-a-2", Logins.AccessToken(saved.Login));
        Assert.Equal(SavedAt.AddHours(1), saved.SavedAt);
    }

    [Fact]
    public void Upsert_SamePersonInAnotherOrganization_IsASecondEntry()
    {
        var store = new AccountStore(StorePath);
        store.Upsert(new SavedAccount(a, SavedAt));

        store.Upsert(new SavedAccount(Logins.Make("a", "a@example.com", org: "org-2"), SavedAt));

        Assert.Equal(2, new AccountStore(StorePath).All.Count);
    }

    [Fact]
    public void FindAndRemove_WorkByKey()
    {
        var store = new AccountStore(StorePath);
        var b = Logins.Make("b", "b@example.com");
        store.Upsert(new SavedAccount(a, SavedAt));
        store.Upsert(new SavedAccount(b, SavedAt));

        store.Remove(a.Key);

        Assert.Null(store.Find(a.Key));
        Assert.NotNull(store.Find(b.Key));
        Assert.Equal(b.Key, Assert.Single(new AccountStore(StorePath).All).Key);
    }

    [Fact]
    public void UndecryptableFile_IsMovedAside_AndTheListStartsEmpty()
    {
        Directory.CreateDirectory(temp["data"]);
        File.WriteAllBytes(StorePath, [1, 2, 3, 4]); // e.g. written by another Windows user

        var store = new AccountStore(StorePath);

        Assert.Empty(store.All);
        Assert.Equal(new byte[] { 1, 2, 3, 4 }, File.ReadAllBytes(StorePath + ".bad"));
        store.Upsert(new SavedAccount(a, SavedAt));
        Assert.Single(new AccountStore(StorePath).All);
    }

    [Fact]
    public void DecryptableButDamagedList_IsMovedAside()
    {
        Directory.CreateDirectory(temp["data"]);
        File.WriteAllBytes(StorePath, ProtectedData.Protect("""{"version":1,"accounts":[{"savedAt":"x"}]}"""u8.ToArray(),
            "ClaudeUsageBar.accounts.v1"u8.ToArray(), DataProtectionScope.CurrentUser));

        Assert.Empty(new AccountStore(StorePath).All);
        Assert.True(File.Exists(StorePath + ".bad"));
    }

    [Fact]
    public void LockedFile_IsNotMistakenForADamagedOne()
    {
        new AccountStore(StorePath).Upsert(new SavedAccount(a, SavedAt));

        using (new FileStream(StorePath, FileMode.Open, FileAccess.Read, FileShare.None))
            Assert.Throws<IOException>(() => new AccountStore(StorePath).All);

        Assert.False(File.Exists(StorePath + ".bad"));
        Assert.Single(new AccountStore(StorePath).All);
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `dotnet test ClaudeUsageBar.sln --nologo --filter "FullyQualifiedName~AccountStoreTests"`
Expected: build FAILS with `error CS0246: The type or namespace name 'AccountStore' could not be found` (and `SavedAccount`).

- [ ] **Step 4: Implement `AccountStore`**

Create `src/ClaudeUsageBar/Core/AccountStore.cs`:

```csharp
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ClaudeUsageBar.Core;

/// A saved login and when it was last captured. E-mail, organization, plan and expiry come from the raw login.
public sealed record SavedAccount(AccountLogin Login, DateTimeOffset SavedAt)
{
    public AccountKey Key => Login.Key;
}

/// Saved accounts in accounts.dat: one JSON list, encrypted with DPAPI for the current Windows user.
public sealed class AccountStore(string path)
{
    static readonly byte[] Entropy = "ClaudeUsageBar.accounts.v1"u8.ToArray();

    List<SavedAccount>? accounts;

    /// Throws IOException while the file can't be opened (then nothing is cached and the next call tries again).
    public IReadOnlyList<SavedAccount> All => accounts ??= Load();

    public SavedAccount? Find(AccountKey key) => All.FirstOrDefault(a => a.Key == key);

    public void Upsert(SavedAccount account)
    {
        var list = All.ToList();
        int i = list.FindIndex(a => a.Key == account.Key);
        if (i >= 0) list[i] = account;
        else list.Add(account);
        Save(list);
    }

    public void Remove(AccountKey key) => Save(All.Where(a => a.Key != key).ToList());

    List<SavedAccount> Load()
    {
        byte[] data;
        try { data = File.ReadAllBytes(path); }
        catch (FileNotFoundException) { return []; }
        catch (DirectoryNotFoundException) { return []; }
        try
        {
            var json = ProtectedData.Unprotect(data, Entropy, DataProtectionScope.CurrentUser);
            if (JsonNode.Parse(json) is not JsonObject { } root || root["accounts"] is not JsonArray list)
                throw new InvalidDataException("no account list");
            return list.Select(Parse).ToList();
        }
        catch (Exception ex) when (ex is CryptographicException or JsonException or InvalidDataException)
        {
            // another Windows user's file or a damaged one: keep it aside and start over
            Log.Write($"accounts: {Path.GetFileName(path)} unreadable ({ex.GetType().Name}), moved to .bad");
            File.Move(path, path + ".bad", overwrite: true);
            return [];
        }
    }

    void Save(List<SavedAccount> list)
    {
        var root = new JsonObject { ["version"] = 1, ["accounts"] = new JsonArray(list.Select(Entry).ToArray()) };
        var data = ProtectedData.Protect(Encoding.UTF8.GetBytes(root.ToJsonString()), Entropy, DataProtectionScope.CurrentUser);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temp = path + ".tmp";
        File.WriteAllBytes(temp, data);
        File.Move(temp, path, overwrite: true);
        accounts = list;
    }

    static JsonNode Entry(SavedAccount a) => new JsonObject
    {
        ["savedAt"] = a.SavedAt.ToString("O", CultureInfo.InvariantCulture),
        ["claudeAiOauth"] = a.Login.Oauth.DeepClone(),
        ["oauthAccount"] = a.Login.Account.DeepClone(),
    };

    static SavedAccount Parse(JsonNode? entry)
    {
        if (entry is JsonObject o
            && o["claudeAiOauth"] is JsonObject oauth
            && o["oauthAccount"] is JsonObject account
            && o["savedAt"] is JsonValue saved && saved.TryGetValue<string>(out var text)
            && DateTimeOffset.TryParseExact(text, "O", CultureInfo.InvariantCulture, DateTimeStyles.None, out var at))
            return new SavedAccount(new AccountLogin(oauth, account), at);
        throw new InvalidDataException("unreadable account entry");
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `dotnet test ClaudeUsageBar.sln --nologo --filter "FullyQualifiedName~AccountStoreTests"`
Expected: PASS (9 tests). Then the full suite: all green.

- [ ] **Step 6: Commit**

```bash
git add src/ClaudeUsageBar/ClaudeUsageBar.csproj src/ClaudeUsageBar/Core/AccountStore.cs tests/ClaudeUsageBar.Tests/AccountStoreTests.cs
git commit -m "feat: saved accounts encrypted with DPAPI (AccountStore)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `UsageService.Reset()` and a CLI lock for token renewal

**Files:**
- Modify: `src/ClaudeUsageBar/Core/TokenRenewer.cs`
- Modify: `src/ClaudeUsageBar/Core/UsageService.cs`
- Modify: `src/ClaudeUsageBar/Program.cs` (one line: pass the lock to `CreateDefault`)
- Modify: `tests/ClaudeUsageBar.Tests/TestSupport.cs` (`FakeRenewer.Reset`, `FakeApi.RespondAsync`)
- Modify: `tests/ClaudeUsageBar.Tests/TokenRenewerTests.cs`
- Modify: `tests/ClaudeUsageBar.Tests/UsageServiceTests.cs`

**Interfaces:**
- Consumes: existing `UsageService`, `CliTokenRenewer`, `ITokenRenewer`.
- Produces:
  - `ITokenRenewer.Reset()`: forgets the last attempt.
  - `CliTokenRenewer(TimeProvider clock, Func<CancellationToken, Task<bool>> runCli, SemaphoreSlim? cliLock = null)`. Each CLI run happens while holding `cliLock`.
  - `static CliTokenRenewer CreateDefault(string workDir, SemaphoreSlim cliLock)`
  - `UsageService.Reset()`: sets `State = UsageState.Initial`, the 429 streak to 0, calls `renewer.Reset()`, raises `Changed`. A refresh that started before `Reset()` doesn't publish its result.

- [ ] **Step 1: Update the fakes**

In `tests/ClaudeUsageBar.Tests/TestSupport.cs`, add to `FakeRenewer`:

```csharp
    public int Resets { get; private set; }
    public void Reset() => Resets++;
```

Replace `FakeApi` with:

```csharp
sealed class FakeApi : IUsageApi
{
    public List<string> Tokens { get; } = [];
    public Func<string, UsageApiResult> Respond { get; set; } = _ => new(ApiStatus.Ok, Fixtures.Usage);
    /// When set, wins over Respond: lets a test hold a fetch open.
    public Func<string, Task<UsageApiResult>>? RespondAsync { get; set; }

    public Task<UsageApiResult> FetchAsync(string accessToken, CancellationToken ct)
    {
        Tokens.Add(accessToken);
        return RespondAsync?.Invoke(accessToken) ?? Task.FromResult(Respond(accessToken));
    }
}
```

- [ ] **Step 2: Write the failing tests**

In `tests/ClaudeUsageBar.Tests/TokenRenewerTests.cs`, replace the `Create` helper and add the tests:

```csharp
    CliTokenRenewer Create(bool cliSucceeds = true, SemaphoreSlim? cliLock = null) =>
        new(clock, _ => { runs++; return Task.FromResult(cliSucceeds); }, cliLock);

    [Fact]
    public async Task Reset_AllowsAnImmediateRenewal()
    {
        var renewer = Create();
        await renewer.TryRenewAsync(default);
        clock.Now = clock.Now.AddMinutes(5);

        renewer.Reset(); // switched to another account

        Assert.True(await renewer.TryRenewAsync(default));
        Assert.Equal(2, runs);
    }

    [Fact]
    public async Task Renewal_WaitsForTheCliLock()
    {
        var cliLock = new SemaphoreSlim(1, 1);
        var renewer = Create(cliLock: cliLock);
        await cliLock.WaitAsync(); // an account switch is writing the login files

        var renewal = renewer.TryRenewAsync(default);
        Assert.False(renewal.IsCompleted);
        Assert.Equal(0, runs);

        cliLock.Release();
        Assert.True(await renewal);
        Assert.Equal(1, runs);
        Assert.Equal(1, cliLock.CurrentCount);
    }
```

In `tests/ClaudeUsageBar.Tests/UsageServiceTests.cs`, add:

```csharp
    [Fact]
    public async Task Reset_ForgetsTheAccountsData_AndBackoff()
    {
        creds.Current = Valid();
        var service = Create();
        await service.RefreshAsync();
        api.Respond = _ => new(ApiStatus.RateLimited, Error: "HTTP 429");
        await service.RefreshAsync();
        UsageState? seen = null;
        service.Changed += s => seen = s;

        service.Reset();

        Assert.Same(UsageState.Initial, service.State);
        Assert.Same(UsageState.Initial, seen);
        Assert.Equal(UsageService.PollInterval, service.NextDelay());
        Assert.Equal(1, renewer.Resets);
    }

    [Fact]
    public async Task RefreshStartedBeforeReset_DoesNotShowTheOldAccount()
    {
        creds.Current = Valid();
        var response = new TaskCompletionSource<UsageApiResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        api.RespondAsync = _ => response.Task;
        var service = Create();
        var refresh = service.RefreshAsync(); // fetching for the account being left

        service.Reset();                      // switched meanwhile
        response.SetResult(new(ApiStatus.Ok, Fixtures.Usage));
        await refresh;

        Assert.Same(UsageState.Initial, service.State);
    }

    [Fact]
    public async Task RefreshStartedBeforeReset_DoesNotSlowDownTheNewAccount()
    {
        creds.Current = Valid();
        var response = new TaskCompletionSource<UsageApiResult>(TaskCreationOptions.RunContinuationsAsynchronously);
        api.RespondAsync = _ => response.Task;
        var service = Create();
        var refresh = service.RefreshAsync();

        service.Reset();
        response.SetResult(new(ApiStatus.RateLimited, Error: "HTTP 429"));
        await refresh;

        Assert.Equal(UsageService.PollInterval, service.NextDelay());
    }
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `dotnet test ClaudeUsageBar.sln --nologo --filter "FullyQualifiedName~TokenRenewerTests|FullyQualifiedName~UsageServiceTests"`
Expected: build FAILS: `'UsageService' does not contain a definition for 'Reset'`, `'CliTokenRenewer' does not contain a constructor that takes 3 arguments`, `'CliTokenRenewer' does not contain a definition for 'Reset'`.

- [ ] **Step 4: Implement the renewer changes**

In `src/ClaudeUsageBar/Core/TokenRenewer.cs`, replace the interface and the top of the class (up to and including `CreateDefault`) with:

```csharp
public interface ITokenRenewer
{
    /// Asks the official CLI to refresh its login; false when throttled, missing or failed.
    Task<bool> TryRenewAsync(CancellationToken ct);

    /// Forgets the last attempt: after an account switch the new login may renew right away.
    void Reset();
}

/// Renews the Claude Code login with one tiny `claude -p` call: the CLI refreshes its own token file.
/// `cliLock` is shared with the account switcher: the CLI must not write its refreshed tokens over a switch.
public sealed class CliTokenRenewer(TimeProvider clock, Func<CancellationToken, Task<bool>> runCli, SemaphoreSlim? cliLock = null) : ITokenRenewer
{
    public static readonly TimeSpan MinInterval = TimeSpan.FromMinutes(30);
    static readonly TimeSpan RunTimeout = TimeSpan.FromSeconds(90);
    static readonly string[] Arguments = ["-p", "ok", "--model", "haiku", "--safe-mode", "--no-session-persistence"];

    readonly SemaphoreSlim cliLock = cliLock ?? new(1, 1);
    DateTimeOffset? lastAttempt;

    public async Task<bool> TryRenewAsync(CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        if (lastAttempt is { } last && now - last < MinInterval) return false;
        lastAttempt = now;
        await cliLock.WaitAsync(ct);
        try { return await runCli(ct); }
        finally { cliLock.Release(); }
    }

    public void Reset() => lastAttempt = null;

    public static CliTokenRenewer CreateDefault(string workDir, SemaphoreSlim cliLock) =>
        new(TimeProvider.System, ct => RunClaudeAsync(workDir, ct), cliLock);
```

(`FindClaude` and `RunClaudeAsync` stay as they are.)

In `src/ClaudeUsageBar/Program.cs`, replace the `var service = …` statement with:

```csharp
        var cliLock = new SemaphoreSlim(1, 1); // one writer of the Claude Code login at a time: renewal or account switch
        var service = new UsageService(
            new FileCredentialStore(FileCredentialStore.DefaultPath),
            new HttpUsageApi(),
            CliTokenRenewer.CreateDefault(Path.Combine(dataDir, "work"), cliLock),
            TimeProvider.System);
```

- [ ] **Step 5: Implement `UsageService.Reset()`**

In `src/ClaudeUsageBar/Core/UsageService.cs`, add the field next to `rateLimitStreak`:

```csharp
    int generation; // bumped by Reset: a refresh that started earlier belongs to the previous account
```

Replace `RefreshAsync` with:

```csharp
    public async Task RefreshAsync(CancellationToken ct = default)
    {
        await gate.WaitAsync(ct);
        try
        {
            int started = generation;
            var next = await FetchAsync(ct);
            if (started != generation)
            {
                rateLimitStreak = 0; // whatever that refresh counted was about the account we left
                return;
            }
            State = next;
            Log.Write($"refresh: {State.Status} session={State.Snapshot?.Session?.UsedPercent} week={State.Snapshot?.Weekly?.UsedPercent} {State.LastError}");
            Changed?.Invoke(State);
        }
        finally { gate.Release(); }
    }

    /// After an account switch: back to Loading with no data and no backoff, so the previous account's numbers
    /// never show under the new one.
    public void Reset()
    {
        generation++;
        rateLimitStreak = 0;
        renewer.Reset();
        State = UsageState.Initial;
        Changed?.Invoke(State);
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `dotnet test ClaudeUsageBar.sln --nologo`
Expected: PASS, all tests (the existing renewer and service tests unchanged).

- [ ] **Step 7: Commit**

```bash
git add src/ClaudeUsageBar/Core/TokenRenewer.cs src/ClaudeUsageBar/Core/UsageService.cs src/ClaudeUsageBar/Program.cs tests/ClaudeUsageBar.Tests/TestSupport.cs tests/ClaudeUsageBar.Tests/TokenRenewerTests.cs tests/ClaudeUsageBar.Tests/UsageServiceTests.cs
git commit -m "feat: UsageService.Reset and a CLI lock around token renewal

Reset drops the previous account's data, backoff and renewal throttle; a refresh still in flight is discarded.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `AccountSwitcher`: sync, switch, add, remove

**Files:**
- Create: `src/ClaudeUsageBar/Core/AccountSwitcher.cs`
- Create: `tests/ClaudeUsageBar.Tests/AccountSwitcherTests.cs`

**Interfaces:**
- Consumes: `CliLogin` (`ReadCurrent`, `Write`, `ForConfigDir`), `AccountLogin`, `AccountKey` (Task 1); `AccountStore`, `SavedAccount` (Task 2); a `SemaphoreSlim` shared with `CliTokenRenewer` (Task 3).
- Produces:
  - `public enum AccountError { ClaudeNotFound, LoginFailed, WriteFailed }`
  - `public sealed class AccountException(AccountError error, string message, Exception? inner = null) : Exception` with `AccountError Error`.
  - `public sealed class AccountSwitcher(CliLogin cli, AccountStore store, SemaphoreSlim cliLock, string loginRoot, Func<string?, string, CancellationToken, Task<bool>> runLogin, TimeProvider clock)`, with:
    - `AccountLogin? Active`, `bool IsLoginRunning`, `IReadOnlyList<SavedAccount> Accounts`, `event Action? Switched`
    - `void Sync()`
    - `Task SwitchToAsync(AccountKey key, CancellationToken ct = default)`
    - `Task AddAccountAsync(string? email, CancellationToken ct = default)`
    - `void Remove(AccountKey key)`, which throws `InvalidOperationException` for the active account.
  - `runLogin(email, configDir, ct)` must leave a CLI login in `configDir` and return true; false means it failed or was cancelled. It may throw `AccountException(ClaudeNotFound)`.

- [ ] **Step 1: Write the failing tests**

Create `tests/ClaudeUsageBar.Tests/AccountSwitcherTests.cs`:

```csharp
using ClaudeUsageBar.Core;

namespace ClaudeUsageBar.Tests;

public sealed class AccountSwitcherTests : IDisposable
{
    static readonly DateTimeOffset Now = new(2026, 10, 6, 12, 0, 0, TimeSpan.Zero);

    readonly TempDir temp = new();
    readonly FakeClock clock = new(Now);
    readonly SemaphoreSlim cliLock = new(1, 1);
    readonly AccountStore store;
    readonly AccountLogin a = Logins.Make("a", "a@example.com");
    readonly AccountLogin b = Logins.Make("b", "b@example.com");
    readonly List<(string? Email, string Dir)> logins = [];
    Func<string, Task<bool>> login = _ => Task.FromResult(false); // what the fake `claude auth login` does in its dir
    int switched;

    public AccountSwitcherTests() => store = new AccountStore(temp["data/accounts.dat"]);

    public void Dispose() => temp.Dispose();

    string HomeClaude => temp["home/.claude"];
    string HomeConfig => temp["home/.claude.json"];
    string CredentialsPath => Path.Combine(HomeClaude, ".credentials.json");
    string DataDir => temp["data"];
    CliLogin Cli => new(HomeClaude, HomeConfig, temp["data/backup"]);
    AccountLogin? CliNow => Cli.ReadCurrent();

    AccountSwitcher Create()
    {
        var switcher = new AccountSwitcher(Cli, store, cliLock, DataDir, (email, dir, ct) =>
        {
            logins.Add((email, dir));
            return login(dir);
        }, clock);
        switcher.Switched += () => switched++;
        return switcher;
    }

    void SignInCli(AccountLogin account) => Logins.WriteCli(HomeClaude, HomeConfig, account);

    static Func<string, Task<bool>> LogsIn(AccountLogin account) => dir =>
    {
        Logins.WriteCli(dir, Path.Combine(dir, ".claude.json"), account);
        return Task.FromResult(true);
    };

    [Fact]
    public void Sync_SavesAnAccountSignedInByHand()
    {
        SignInCli(a);
        var switcher = Create();

        switcher.Sync();

        Assert.Equal(a.Key, switcher.Active?.Key);
        Assert.True(Assert.Single(store.All).Login.SameAs(a));
    }

    [Fact]
    public void Sync_UnchangedLogin_KeepsTheSavedCopy()
    {
        SignInCli(a);
        var switcher = Create();
        switcher.Sync();
        clock.Now = Now.AddMinutes(5);

        switcher.Sync();

        Assert.Equal(Now, Assert.Single(store.All).SavedAt);
    }

    [Fact]
    public void Sync_RotatedTokens_UpdateTheSavedCopy()
    {
        SignInCli(a);
        var switcher = Create();
        switcher.Sync();
        SignInCli(Logins.Make("a", "a@example.com", token: "2")); // the CLI refreshed its token

        switcher.Sync();

        Assert.Equal("access-a-2", Logins.AccessToken(Assert.Single(store.All).Login));
    }

    [Fact]
    public void Sync_SignedOut_SavesNothing()
    {
        var switcher = Create();

        switcher.Sync();

        Assert.Null(switcher.Active);
        Assert.Empty(store.All);
    }

    [Fact]
    public async Task SwitchTo_WritesTheTarget_AndKeepsTheLatestTokensOfTheAccountLeft()
    {
        store.Upsert(new SavedAccount(b, Now));
        SignInCli(a);
        var switcher = Create();
        switcher.Sync();
        SignInCli(Logins.Make("a", "a@example.com", token: "2")); // rotated after the last sync

        await switcher.SwitchToAsync(b.Key);

        Assert.True(CliNow!.SameAs(b));
        Assert.Equal(b.Key, switcher.Active?.Key);
        Assert.Equal("access-a-2", Logins.AccessToken(store.Find(a.Key)!.Login));
        Assert.Equal(1, switched);
    }

    [Fact]
    public async Task SwitchTo_TheActiveAccount_ChangesNothing()
    {
        SignInCli(a);
        var switcher = Create();
        var config = File.ReadAllText(HomeConfig);

        await switcher.SwitchToAsync(a.Key);

        Assert.Equal(config, File.ReadAllText(HomeConfig));
        Assert.Equal(0, switched);
    }

    [Fact]
    public async Task SwitchTo_WaitsWhileTheCliIsRenewingItsToken()
    {
        store.Upsert(new SavedAccount(b, Now));
        SignInCli(a);
        var switcher = Create();
        await cliLock.WaitAsync(); // a `claude -p` renewal is running

        var switching = switcher.SwitchToAsync(b.Key);
        Assert.False(switching.IsCompleted);
        Assert.True(CliNow!.SameAs(a));

        cliLock.Release();
        await switching;
        Assert.True(CliNow!.SameAs(b));
        Assert.Equal(1, cliLock.CurrentCount);
    }

    [Fact]
    public async Task SwitchTo_UnwritableConfig_FailsAndKeepsTheActiveAccount()
    {
        store.Upsert(new SavedAccount(b, Now));
        SignInCli(a);
        var switcher = Create();
        switcher.Sync();
        File.WriteAllText(HomeConfig, "{damaged");
        var credentials = File.ReadAllText(CredentialsPath);

        var ex = await Assert.ThrowsAsync<AccountException>(() => switcher.SwitchToAsync(b.Key));

        Assert.Equal(AccountError.WriteFailed, ex.Error);
        Assert.Equal(credentials, File.ReadAllText(CredentialsPath));
        Assert.Equal(0, switched);
        Assert.Equal(1, cliLock.CurrentCount);
    }

    [Fact]
    public async Task AddAccount_SignsInIsolated_SavesTheAccount_AndSwitchesToIt()
    {
        SignInCli(a);
        login = dir =>
        {
            Assert.True(CliNow!.SameAs(a)); // the user's own login stays untouched while signing in
            return LogsIn(b)(dir);
        };
        var switcher = Create();

        await switcher.AddAccountAsync(null);

        var (email, dir) = Assert.Single(logins);
        Assert.Null(email);
        Assert.StartsWith(Path.Combine(DataDir, "login-"), dir);
        Assert.False(Directory.Exists(dir));
        Assert.True(CliNow!.SameAs(b));
        Assert.NotNull(store.Find(a.Key));
        Assert.NotNull(store.Find(b.Key));
        Assert.Equal(1, switched);
        Assert.False(switcher.IsLoginRunning);
    }

    [Fact]
    public async Task AddAccount_LoginFailedOrClosed_ChangesNothing()
    {
        SignInCli(a);
        login = _ => Task.FromResult(false);
        var switcher = Create();

        var ex = await Assert.ThrowsAsync<AccountException>(() => switcher.AddAccountAsync(null));

        Assert.Equal(AccountError.LoginFailed, ex.Error);
        Assert.True(CliNow!.SameAs(a));
        Assert.False(Directory.Exists(Assert.Single(logins).Dir));
        Assert.Equal(0, switched);
        Assert.False(switcher.IsLoginRunning);
    }

    [Fact]
    public async Task AddAccount_ExitedWithoutALogin_IsAFailedLogin()
    {
        SignInCli(a);
        login = _ => Task.FromResult(true);

        var ex = await Assert.ThrowsAsync<AccountException>(() => Create().AddAccountAsync(null));

        Assert.Equal(AccountError.LoginFailed, ex.Error);
        Assert.True(CliNow!.SameAs(a));
    }

    [Fact]
    public async Task AddAccount_Cancelled_RemovesTheTempDir()
    {
        login = _ => Task.FromCanceled<bool>(new CancellationToken(canceled: true));
        var switcher = Create();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => switcher.AddAccountAsync(null));

        Assert.False(Directory.Exists(Assert.Single(logins).Dir));
        Assert.False(switcher.IsLoginRunning);
    }

    [Fact]
    public async Task AddAccount_FreshLoginOfTheActiveAccount_ReplacesItsDeadTokens()
    {
        SignInCli(a);
        var switcher = Create();
        switcher.Sync();
        login = LogsIn(Logins.Make("a", "a@example.com", token: "9"));

        await switcher.AddAccountAsync("a@example.com");

        Assert.Equal("a@example.com", Assert.Single(logins).Email);
        Assert.Equal("access-a-9", Logins.AccessToken(CliNow!));
        Assert.Equal("access-a-9", Logins.AccessToken(Assert.Single(store.All).Login));
        Assert.Equal(1, switched);
    }

    [Fact]
    public async Task AddAccount_FreshLoginOfASavedAccount_RefreshesItAndSwitches()
    {
        store.Upsert(new SavedAccount(Logins.Make("b", "b@example.com", refreshExpires: Now.AddDays(-1)), Now.AddDays(-31)));
        SignInCli(a);
        login = LogsIn(Logins.Make("b", "b@example.com", token: "9"));

        await Create().AddAccountAsync("b@example.com");

        Assert.Equal("access-b-9", Logins.AccessToken(store.Find(b.Key)!.Login));
        Assert.Equal("access-b-9", Logins.AccessToken(CliNow!));
        Assert.NotNull(store.Find(a.Key)); // captured on the way out
    }

    [Fact]
    public async Task AddAccount_OnlyOneLoginAtATime()
    {
        var finish = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        login = dir => { LogsIn(b)(dir); return finish.Task; };
        var switcher = Create();

        var first = switcher.AddAccountAsync(null);
        Assert.True(switcher.IsLoginRunning);
        await switcher.AddAccountAsync(null); // ignored: returns at once
        finish.SetResult(true);
        await first;

        Assert.Single(logins);
        Assert.False(switcher.IsLoginRunning);
    }

    [Fact]
    public async Task AddAccount_RemovesLoginDirsLeftByAnEarlierCrash()
    {
        var leftover = Path.Combine(DataDir, "login-0123");
        Directory.CreateDirectory(leftover);
        File.WriteAllText(Path.Combine(leftover, ".credentials.json"), "{}");

        await Assert.ThrowsAsync<AccountException>(() => Create().AddAccountAsync(null));

        Assert.False(Directory.Exists(leftover));
    }

    [Fact]
    public void Remove_InactiveAccount_ForgetsIt_WithoutTouchingTheCli()
    {
        store.Upsert(new SavedAccount(b, Now));
        SignInCli(a);
        var switcher = Create();
        var credentials = File.ReadAllText(CredentialsPath);
        var config = File.ReadAllText(HomeConfig);

        switcher.Remove(b.Key);

        Assert.Null(store.Find(b.Key));
        Assert.Equal(credentials, File.ReadAllText(CredentialsPath));
        Assert.Equal(config, File.ReadAllText(HomeConfig));
    }

    [Fact]
    public void Remove_ActiveAccount_IsRefused()
    {
        SignInCli(a);
        var switcher = Create();

        Assert.Throws<InvalidOperationException>(() => switcher.Remove(a.Key));

        Assert.NotNull(store.Find(a.Key));
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `dotnet test ClaudeUsageBar.sln --nologo --filter "FullyQualifiedName~AccountSwitcherTests"`
Expected: build FAILS with `error CS0246: The type or namespace name 'AccountSwitcher' could not be found` (and `AccountException`, `AccountError`).

- [ ] **Step 3: Implement `AccountSwitcher`**

Create `src/ClaudeUsageBar/Core/AccountSwitcher.cs`:

```csharp
namespace ClaudeUsageBar.Core;

public enum AccountError { ClaudeNotFound, LoginFailed, WriteFailed }

/// A user action on accounts that failed; the active login is unchanged.
public sealed class AccountException(AccountError error, string message, Exception? inner = null) : Exception(message, inner)
{
    public AccountError Error { get; } = error;
}

/// Saved accounts ↔ the Claude Code CLI login: captures the active login, switches to a saved one, adds new ones.
/// `cliLock` is shared with the token renewer: a `claude -p` refresh must never write the old account's tokens
/// over a login that was just switched to.
public sealed class AccountSwitcher(
    CliLogin cli,
    AccountStore store,
    SemaphoreSlim cliLock,
    string loginRoot,
    Func<string?, string, CancellationToken, Task<bool>> runLogin,
    TimeProvider clock)
{
    public AccountLogin? Active { get; private set; }
    public bool IsLoginRunning { get; private set; }
    public IReadOnlyList<SavedAccount> Accounts => store.All;

    /// The CLI now has another login (or a fresh one); everything shown for the previous one is stale.
    public event Action? Switched;

    /// Reads the active CLI login and saves it when it is new or changed: token rotation, `/login` by hand.
    public void Sync()
    {
        Active = cli.ReadCurrent();
        if (Active is null) return;
        if (store.Find(Active.Key) is { } saved && saved.Login.SameAs(Active)) return;
        store.Upsert(new SavedAccount(Active, clock.GetUtcNow()));
        Log.Write($"accounts: saved {Active}");
    }

    public async Task SwitchToAsync(AccountKey key, CancellationToken ct = default)
    {
        await cliLock.WaitAsync(ct);
        try
        {
            Sync(); // the account being left may have rotated its tokens since the last sync
            if (Active?.Key == key) return;
            var target = store.Find(key) ?? throw new InvalidOperationException($"No saved account {key}");
            Apply(target.Login);
        }
        finally { cliLock.Release(); }
    }

    /// Signs in with `claude auth login` in a throwaway CLAUDE_CONFIG_DIR, so the current login is never signed out,
    /// then saves the new login and switches to it. `email` pre-fills the login page (for "sign in again").
    public async Task AddAccountAsync(string? email, CancellationToken ct = default)
    {
        if (IsLoginRunning) return;
        IsLoginRunning = true;
        var dir = Path.Combine(loginRoot, $"login-{Guid.NewGuid():N}");
        try
        {
            RemoveLeftoverLoginDirs();
            Directory.CreateDirectory(dir);
            if (!await runLogin(email, dir, ct))
                throw new AccountException(AccountError.LoginFailed, "claude auth login failed or was closed");
            var login = CliLogin.ForConfigDir(dir).ReadCurrent()
                ?? throw new AccountException(AccountError.LoginFailed, "claude auth login left no login");
            await cliLock.WaitAsync(ct);
            try
            {
                Sync(); // after the login, not before: the account being left may have rotated its tokens meanwhile
                store.Upsert(new SavedAccount(login, clock.GetUtcNow()));
                Apply(login); // also when it is the active account: the fresh login replaces its dead tokens
            }
            finally { cliLock.Release(); }
        }
        finally
        {
            DeleteDir(dir); // it holds live tokens
            IsLoginRunning = false;
        }
    }

    /// Forgets a saved account. No server call: its login stays valid wherever else it is used.
    public void Remove(AccountKey key)
    {
        Sync();
        if (Active?.Key == key) throw new InvalidOperationException("The active account can't be removed");
        store.Remove(key);
        Log.Write($"accounts: removed {key}");
    }

    void Apply(AccountLogin login)
    {
        try { cli.Write(login); }
        catch (IOException ex) { throw new AccountException(AccountError.WriteFailed, ex.Message, ex); }
        Active = cli.ReadCurrent();
        Log.Write($"accounts: switched to {login}");
        Switched?.Invoke();
        if (Active?.Key != login.Key)
            throw new AccountException(AccountError.WriteFailed, $"CLI login reads back as {Active?.ToString() ?? "nothing"}");
    }

    // a login dir left by a crash or a kill still holds tokens; only one login runs at a time, so none is in use
    void RemoveLeftoverLoginDirs()
    {
        if (!Directory.Exists(loginRoot)) return;
        foreach (var dir in Directory.GetDirectories(loginRoot, "login-*")) DeleteDir(dir);
    }

    static void DeleteDir(string dir)
    {
        try { if (Directory.Exists(dir)) Directory.Delete(dir, recursive: true); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Write($"accounts: can't delete {Path.GetFileName(dir)}: {ex.Message}");
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `dotnet test ClaudeUsageBar.sln --nologo --filter "FullyQualifiedName~AccountSwitcherTests"`
Expected: PASS (17 tests). Then the full suite: all green.

- [ ] **Step 5: Commit**

```bash
git add src/ClaudeUsageBar/Core/AccountSwitcher.cs tests/ClaudeUsageBar.Tests/AccountSwitcherTests.cs
git commit -m "feat: AccountSwitcher - sync, switch, add (isolated login) and remove accounts

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Account texts and menu labels

**Files:**
- Modify: `src/ClaudeUsageBar/Core/Texts.cs`
- Modify: `src/ClaudeUsageBar/Localization/en.json`
- Modify: `src/ClaudeUsageBar/Localization/pl.json`
- Create: `src/ClaudeUsageBar/Core/AccountLabels.cs`
- Modify: `tests/ClaudeUsageBar.Tests/TextsTests.cs`
- Create: `tests/ClaudeUsageBar.Tests/AccountLabelsTests.cs`

**Interfaces:**
- Consumes: `SavedAccount` (Task 2), `AccountLogin.Email/PlanName/OrganizationName/RefreshTokenExpiresAt` (Task 1).
- Produces:
  - `Texts.Accounts` of type `AccountTexts`, with `Add`, `Remove`, `SignInAgain` (`{account}`), `RemoveConfirm` (`{account}`), `LoginHint`, `ClaudeNotFound`, `LoginFailed`, `WriteFailed`.
  - `static class AccountLabels` with:
    - `IReadOnlyList<SavedAccount> Ordered(IEnumerable<SavedAccount>)`
    - `string Label(SavedAccount, IReadOnlyList<SavedAccount> all)`
    - `bool NeedsSignIn(SavedAccount, DateTimeOffset now)`
    - `string MenuText(SavedAccount, IReadOnlyList<SavedAccount> all, bool needsSignIn, Texts)`
    - `string ForMenu(string)`, which escapes `&` for WinForms menus

- [ ] **Step 1: Write the failing tests**

In `tests/ClaudeUsageBar.Tests/TextsTests.cs`, add `"account"` to `KnownPlaceholders`:

```csharp
    static readonly HashSet<string> KnownPlaceholders =
        ["model", "m", "h", "d", "duration", "time", "weekday", "day", "month", "monthNumber", "countdown", "moment", "ago", "account"];
```

The existing `EveryLanguage_HasAllTexts_WithoutEmptyValues` covers the new section automatically, because it walks every `Core` text class.

Create `tests/ClaudeUsageBar.Tests/AccountLabelsTests.cs`:

```csharp
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `dotnet test ClaudeUsageBar.sln --nologo --filter "FullyQualifiedName~AccountLabelsTests|FullyQualifiedName~TextsTests"`
Expected: build FAILS with `error CS0103: The name 'AccountLabels' does not exist in the current context`.

- [ ] **Step 3: Add the texts**

In `src/ClaudeUsageBar/Core/Texts.cs`, add the property to `Texts` after `Menu`:

```csharp
    public required AccountTexts Accounts { get; init; }
```

and add the class at the end of the file:

```csharp
public sealed class AccountTexts
{
    public required string Add { get; init; }
    public required string Remove { get; init; }
    public required string SignInAgain { get; init; }
    public required string RemoveConfirm { get; init; }
    /// Printed by cmd.exe in the login window: must not contain & | < > ^ % or double quotes.
    public required string LoginHint { get; init; }
    public required string ClaudeNotFound { get; init; }
    public required string LoginFailed { get; init; }
    public required string WriteFailed { get; init; }
}
```

In `src/ClaudeUsageBar/Localization/en.json`, add after the `"menu"` object (mind the comma after its closing brace):

```json
  "accounts": {
    "add": "Add account…",
    "remove": "Remove account",
    "signInAgain": "{account} — sign in again",
    "removeConfirm": "Remove {account} from the list? It won't sign it out.",
    "loginHint": "Sign in with the account you want to add. If the browser is signed in to another account, copy the link into a private window.",
    "claudeNotFound": "Claude Code (claude.exe) was not found. Install it and try again.",
    "loginFailed": "Sign-in didn't finish. Nothing was changed.",
    "writeFailed": "Couldn't switch the account: Claude Code's login files couldn't be written. Nothing was changed."
  },
```

In `src/ClaudeUsageBar/Localization/pl.json`, same place:

```json
  "accounts": {
    "add": "Dodaj konto…",
    "remove": "Usuń konto",
    "signInAgain": "{account} — zaloguj ponownie",
    "removeConfirm": "Usunąć {account} z listy? Konto nie zostanie wylogowane.",
    "loginHint": "Zaloguj się na konto, które chcesz dodać. Jeśli przeglądarka jest zalogowana na inne konto, skopiuj link do okna prywatnego.",
    "claudeNotFound": "Nie znaleziono Claude Code (claude.exe). Zainstaluj go i spróbuj ponownie.",
    "loginFailed": "Logowanie nie zostało dokończone. Nic nie zmieniono.",
    "writeFailed": "Nie udało się przełączyć konta: nie można zapisać plików logowania Claude Code. Nic nie zmieniono."
  },
```

- [ ] **Step 4: Implement `AccountLabels`**

Create `src/ClaudeUsageBar/Core/AccountLabels.cs`:

```csharp
namespace ClaudeUsageBar.Core;

/// How saved accounts read in the menu.
public static class AccountLabels
{
    /// Alphabetical by e-mail, then organization.
    public static IReadOnlyList<SavedAccount> Ordered(IEnumerable<SavedAccount> accounts) => accounts
        .OrderBy(a => a.Login.Email, StringComparer.OrdinalIgnoreCase)
        .ThenBy(a => a.Login.OrganizationName ?? "", StringComparer.OrdinalIgnoreCase)
        .ToList();

    /// "jan@firma.pl · Max 5x"; the organization is added when another saved account would read the same.
    public static string Label(SavedAccount account, IReadOnlyList<SavedAccount> all)
    {
        var label = Basic(account.Login);
        bool ambiguous = all.Any(a => a.Key != account.Key && Basic(a.Login) == label);
        return ambiguous ? $"{label} · {account.Login.OrganizationName ?? account.Key.OrganizationUuid}" : label;
    }

    /// Past refreshTokenExpiresAt the saved tokens can't be renewed: only a new login helps.
    public static bool NeedsSignIn(SavedAccount account, DateTimeOffset now) =>
        account.Login.RefreshTokenExpiresAt is { } expires && expires <= now;

    public static string MenuText(SavedAccount account, IReadOnlyList<SavedAccount> all, bool needsSignIn, Texts texts) =>
        needsSignIn ? Texts.Fill(texts.Accounts.SignInAgain, ("account", Label(account, all))) : Label(account, all);

    /// WinForms menus treat '&' as a keyboard mnemonic: "R&D" would lose its ampersand.
    public static string ForMenu(string text) => text.Replace("&", "&&");

    static string Basic(AccountLogin login) =>
        login.PlanName.Length == 0 ? login.Email : $"{login.Email} · {login.PlanName}";
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `dotnet test ClaudeUsageBar.sln --nologo`
Expected: PASS, all tests (including `TextsTests` for both languages).

- [ ] **Step 6: Commit**

```bash
git add src/ClaudeUsageBar/Core/Texts.cs src/ClaudeUsageBar/Localization/en.json src/ClaudeUsageBar/Localization/pl.json src/ClaudeUsageBar/Core/AccountLabels.cs tests/ClaudeUsageBar.Tests/TextsTests.cs tests/ClaudeUsageBar.Tests/AccountLabelsTests.cs
git commit -m "feat: account menu labels and texts (English, Polish)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: `LoginRunner`: `claude auth login` in its own console window

**Files:**
- Create: `src/ClaudeUsageBar/Core/LoginRunner.cs`
- Modify: `src/ClaudeUsageBar/Core/TokenRenewer.cs` (extract `ClearClaudeEnvironment`)
- Create: `tests/ClaudeUsageBar.Tests/LoginRunnerTests.cs`

**Interfaces:**
- Consumes: `CliTokenRenewer.FindClaude()` (existing); `AccountException`, `AccountError` (Task 4); `Texts.Accounts.LoginHint` (Task 5).
- Produces:
  - `public static void CliTokenRenewer.ClearClaudeEnvironment(ProcessStartInfo psi)`
  - `public static class LoginRunner` with `const string WindowTitle = "ClaudeUsageBar: add account"`, `string CommandLine(string claudeExe, string? email, string hint)` (the cmd.exe arguments), and `Task<bool> RunAsync(string hint, string? email, string configDir, CancellationToken ct)`. `RunAsync` throws `AccountException(ClaudeNotFound)` or `AccountException(LoginFailed)`, and returns `exitCode == 0`. It kills the window when cancelled.

- [ ] **Step 1: Write the failing tests**

Create `tests/ClaudeUsageBar.Tests/LoginRunnerTests.cs`:

```csharp
using System.Diagnostics;
using ClaudeUsageBar.Core;

namespace ClaudeUsageBar.Tests;

public class LoginRunnerTests
{
    const string Exe = @"C:\Tools\claude.exe";
    const string CmdSpecial = "&|<>^%\"";

    [Fact]
    public void CommandLine_ShowsTitleAndHint_ThenRunsTheLogin() =>
        Assert.Equal(
            @"/d /s /c ""chcp 65001 >nul & title ClaudeUsageBar: add account & echo Sign in. & echo. & ""C:\Tools\claude.exe"" auth login""",
            LoginRunner.CommandLine(Exe, null, "Sign in."));

    [Fact]
    public void CommandLine_PrefillsAPlainEmail() =>
        Assert.EndsWith(@"auth login --email jan.kowalski+cc@firma-x.pl""",
            LoginRunner.CommandLine(Exe, "jan.kowalski+cc@firma-x.pl", "Hint"));

    [Theory]
    [InlineData("a&calc@x.pl")]
    [InlineData("a\"b@x.pl")]
    [InlineData("a%PATH%@x.pl")]
    [InlineData("a b@x.pl")]
    [InlineData("a|b@x.pl")]
    [InlineData("not-an-email")]
    public void CommandLine_DropsAnEmailCmdWouldInterpret(string email) =>
        Assert.DoesNotContain("--email", LoginRunner.CommandLine(Exe, email, "Hint"));

    [Fact]
    public void CommandLine_StripsCmdCharactersFromTheHint() =>
        Assert.Contains("& echo a  b  c  d & echo. &", LoginRunner.CommandLine(Exe, null, "a & b | c > d"));

    [Theory]
    [MemberData(nameof(TextsTests.Languages), MemberType = typeof(TextsTests))]
    public void EveryLanguage_LoginHint_IsSafeForCmd(string code)
    {
        var hint = Texts.Load(code).Accounts.LoginHint;
        Assert.DoesNotContain(hint, c => CmdSpecial.Contains(c));
    }

    [Fact]
    public void ClearClaudeEnvironment_RemovesClaudeAndAnthropicVariables()
    {
        var psi = new ProcessStartInfo("x");
        psi.Environment["CLAUDE_CODE_OAUTH_TOKEN"] = "t";
        psi.Environment["claude_config_dir"] = "c";
        psi.Environment["ANTHROPIC_API_KEY"] = "k";
        psi.Environment["PATH"] = "p";

        CliTokenRenewer.ClearClaudeEnvironment(psi);

        Assert.False(psi.Environment.ContainsKey("CLAUDE_CODE_OAUTH_TOKEN"));
        Assert.False(psi.Environment.ContainsKey("claude_config_dir"));
        Assert.False(psi.Environment.ContainsKey("ANTHROPIC_API_KEY"));
        Assert.Equal("p", psi.Environment["PATH"]);
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `dotnet test ClaudeUsageBar.sln --nologo --filter "FullyQualifiedName~LoginRunnerTests"`
Expected: build FAILS with `error CS0103: The name 'LoginRunner' does not exist` and `'CliTokenRenewer' does not contain a definition for 'ClearClaudeEnvironment'`.

- [ ] **Step 3: Extract `ClearClaudeEnvironment`**

In `src/ClaudeUsageBar/Core/TokenRenewer.cs`, in `RunClaudeAsync`, replace the comment and `foreach` that remove `CLAUDE*`/`ANTHROPIC*` keys with:

```csharp
        ClearClaudeEnvironment(psi);
```

and add this public method to `CliTokenRenewer` (after `FindClaude`):

```csharp
    /// Never inherit auth, config dir or proxy settings from a Claude session that happened to start us.
    public static void ClearClaudeEnvironment(ProcessStartInfo psi)
    {
        foreach (var key in psi.Environment.Keys.Where(k =>
                     k.StartsWith("CLAUDE", StringComparison.OrdinalIgnoreCase) ||
                     k.StartsWith("ANTHROPIC", StringComparison.OrdinalIgnoreCase)).ToList())
            psi.Environment.Remove(key);
    }
```

- [ ] **Step 4: Implement `LoginRunner`**

Create `src/ClaudeUsageBar/Core/LoginRunner.cs`:

```csharp
using System.ComponentModel;
using System.Diagnostics;
using System.Text.RegularExpressions;

namespace ClaudeUsageBar.Core;

/// Runs `claude auth login` for a new account in its own console window, isolated with CLAUDE_CONFIG_DIR=<dir>,
/// so the user's current login is never touched.
public static class LoginRunner
{
    public const string WindowTitle = "ClaudeUsageBar: add account";
    const string CmdSpecial = "&|<>^%\"";
    // anything cmd.exe would interpret is not passed; the user then types the address in the browser
    static readonly Regex PlainEmail = new(@"^[A-Za-z0-9._+\-]+@[A-Za-z0-9.\-]+$");

    /// cmd.exe arguments: UTF-8 console (for translated hints), window title, hint, then the login.
    /// cmd /c returns the exit code of its last command: claude's.
    public static string CommandLine(string claudeExe, string? email, string hint)
    {
        var login = $"\"{claudeExe}\" auth login";
        if (email is not null && PlainEmail.IsMatch(email)) login += $" --email {email}";
        var safeHint = new string(hint.Where(c => !CmdSpecial.Contains(c)).ToArray());
        return $"/d /s /c \"chcp 65001 >nul & title {WindowTitle} & echo {safeHint} & echo. & {login}\"";
    }

    /// True when the login finished; false when it failed or the window was closed.
    public static async Task<bool> RunAsync(string hint, string? email, string configDir, CancellationToken ct)
    {
        var exe = CliTokenRenewer.FindClaude() ?? throw new AccountException(AccountError.ClaudeNotFound, "claude.exe not found");
        var psi = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "cmd.exe"), CommandLine(exe, email, hint))
        {
            UseShellExecute = false,
            CreateNoWindow = false, // we have no console: cmd gets a window of its own
            WorkingDirectory = configDir,
        };
        CliTokenRenewer.ClearClaudeEnvironment(psi);
        psi.Environment["CLAUDE_CONFIG_DIR"] = configDir;

        Process? process;
        try { process = Process.Start(psi); }
        catch (Win32Exception ex) { throw new AccountException(AccountError.LoginFailed, $"cannot start cmd.exe: {ex.Message}", ex); }
        if (process is null) throw new AccountException(AccountError.LoginFailed, "cmd.exe did not start");

        using (process)
        {
            try { await process.WaitForExitAsync(ct); }
            catch (OperationCanceledException)
            {
                try { process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
                throw;
            }
            Log.Write($"login: claude auth login exited with {process.ExitCode}");
            return process.ExitCode == 0;
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `dotnet test ClaudeUsageBar.sln --nologo`
Expected: PASS, all tests (the existing `TokenRenewerTests` still pass after the extraction).

- [ ] **Step 6: Commit**

```bash
git add src/ClaudeUsageBar/Core/LoginRunner.cs src/ClaudeUsageBar/Core/TokenRenewer.cs tests/ClaudeUsageBar.Tests/LoginRunnerTests.cs
git commit -m "feat: run claude auth login for a new account in its own console window

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: UI: accounts in the menu, e-mail in the popup header, wiring

**Files:**
- Modify: `src/ClaudeUsageBar/UI/Primitives.cs` (add `Ellipsize`)
- Modify: `src/ClaudeUsageBar/UI/DetailsRenderer.cs` (`Draw` gets `string? account = null`)
- Modify: `src/ClaudeUsageBar/UI/DetailsPopup.cs` (`SetAccount`)
- Modify: `src/ClaudeUsageBar/App.cs`
- Modify: `src/ClaudeUsageBar/Program.cs`
- Create: `tests/ClaudeUsageBar.Tests/PrimitivesTests.cs`
- Modify: `tests/ClaudeUsageBar.Tests/DetailsRendererTests.cs`

**Interfaces:**
- Consumes: `AccountSwitcher` (Task 4); `UsageService.Reset()`, `CliTokenRenewer.CreateDefault(workDir, cliLock)` (Task 3); `AccountLabels`, `Texts.Accounts` (Task 5); `LoginRunner.RunAsync` (Task 6).
- Produces:
  - `public static string Primitives.Ellipsize(Graphics g, string text, Font font, float maxWidth)`
  - `DetailsRenderer.Draw(Graphics g, Size size, float s, UsageState state, DateTimeOffset now, Palette p, Texts texts, string? account = null)`
  - `DetailsPopup.SetAccount(string? email)`
  - `App(UsageService service, AccountSwitcher accounts, Texts texts)`

- [ ] **Step 1: Write the failing tests**

Create `tests/ClaudeUsageBar.Tests/PrimitivesTests.cs`:

```csharp
using ClaudeUsageBar.UI;

namespace ClaudeUsageBar.Tests;

public sealed class PrimitivesTests : IDisposable
{
    readonly Bitmap bmp = new(1, 1);
    readonly Graphics g;
    readonly Font font = new("Segoe UI", 11, GraphicsUnit.Pixel);

    public PrimitivesTests() => g = Graphics.FromImage(bmp);

    public void Dispose()
    {
        g.Dispose();
        bmp.Dispose();
        font.Dispose();
    }

    [Fact]
    public void Ellipsize_FittingText_IsUnchanged() =>
        Assert.Equal("a@b.pl", Primitives.Ellipsize(g, "a@b.pl", font, 200));

    [Fact]
    public void Ellipsize_LongText_IsCutWithAnEllipsisToFit()
    {
        const string text = "very.long.address.of.someone@a-company-with-a-long-name.example.com";

        var cut = Primitives.Ellipsize(g, text, font, 120);

        Assert.EndsWith("…", cut);
        Assert.StartsWith(cut[..^1], text);
        Assert.True(Primitives.Measure(g, cut, font) <= 120);
    }

    [Theory]
    [InlineData(2)]
    [InlineData(-30)] // heading wider than the popup leaves negative room
    public void Ellipsize_NoRoom_IsEmpty(float width) =>
        Assert.Equal("", Primitives.Ellipsize(g, "abc@x.pl", font, width));
}
```

Add to `tests/ClaudeUsageBar.Tests/DetailsRendererTests.cs`:

```csharp
    [Fact]
    public void Draw_WithAccount_ShowsItRightAlignedInTheHeader()
    {
        static bool HeaderRightIsBlank(string? account)
        {
            var state = new UsageState(ServiceStatus.Loading, null, "Max 20x", null, null);
            var size = new Size(DetailsRenderer.LogicalWidth, DetailsRenderer.LogicalHeight(state));
            using var bmp = new Bitmap(size.Width, size.Height);
            using (var g = Graphics.FromImage(bmp))
                DetailsRenderer.Draw(g, size, 1f, state, Now, Theme.Dark, Lang.En, account);
            for (int x = 230; x < 284; x++)
                for (int y = 16; y < 32; y++)
                    if (bmp.GetPixel(x, y).ToArgb() != Theme.Dark.Surface.ToArgb()) return false;
            return true;
        }

        Assert.True(HeaderRightIsBlank(null));
        Assert.False(HeaderRightIsBlank("jan.kowalski@firma.pl"));
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `dotnet test ClaudeUsageBar.sln --nologo --filter "FullyQualifiedName~PrimitivesTests|FullyQualifiedName~DetailsRendererTests"`
Expected: build FAILS: `'Primitives' does not contain a definition for 'Ellipsize'` and `No overload for method 'Draw' takes 8 arguments`.

- [ ] **Step 3: Implement `Ellipsize` and the header e-mail**

In `src/ClaudeUsageBar/UI/Primitives.cs`, add after `Measure`:

```csharp
    /// `text` cut with "…" to fit `maxWidth`; empty when not even one letter fits.
    public static string Ellipsize(Graphics g, string text, Font font, float maxWidth)
    {
        if (Measure(g, text, font) <= maxWidth) return text;
        for (int n = text.Length - 1; n > 0; n--)
        {
            var cut = text[..n] + "…";
            if (Measure(g, cut, font) <= maxWidth) return cut;
        }
        return "";
    }
```

In `src/ClaudeUsageBar/UI/DetailsRenderer.cs`, change the `Draw` signature to:

```csharp
    public static void Draw(Graphics g, Size size, float s, UsageState state, DateTimeOffset now, Palette p, Texts texts, string? account = null)
```

and replace the line `Primitives.Text(g, heading, title, p.Text, x + 22 * s, 28 * s);` with:

```csharp
        float headingEnd = Primitives.Text(g, heading, title, p.Text, x + 22 * s, 28 * s);
        if (!string.IsNullOrEmpty(account))
        {
            // the signed-in account, right-aligned and muted; cut short rather than overlap the plan
            var shown = Primitives.Ellipsize(g, account, small, right - headingEnd - 12 * s);
            Primitives.Text(g, shown, small, p.Muted, right - Primitives.Measure(g, shown, small), 28 * s);
        }
```

In `src/ClaudeUsageBar/UI/DetailsPopup.cs`, add a field after `UsageState state = UsageState.Initial;`:

```csharp
    string? account;
```

add after `SetState`:

```csharp
    /// E-mail of the active Claude Code account, shown in the header.
    public void SetAccount(string? email)
    {
        if (email == account) return;
        account = email;
        if (Visible) Invalidate();
    }
```

and change `OnPaint` to pass it:

```csharp
    protected override void OnPaint(PaintEventArgs e) =>
        DetailsRenderer.Draw(e.Graphics, ClientSize, S, state, DateTimeOffset.Now, Theme.Current, texts, account);
```

- [ ] **Step 4: Run the renderer tests to verify they pass**

Run: `dotnet test ClaudeUsageBar.sln --nologo --filter "FullyQualifiedName~PrimitivesTests|FullyQualifiedName~DetailsRendererTests"`
Expected: PASS.

- [ ] **Step 5: Wire the menu in `App`**

Replace `src/ClaudeUsageBar/App.cs` up to (but not including) `/// Hidden top-level window` with:

```csharp
using ClaudeUsageBar.Core;
using ClaudeUsageBar.UI;
using Microsoft.Win32;

namespace ClaudeUsageBar;

/// Wires the service, the accounts, the taskbar readout, the popup, the menu and the timers together.
public sealed class App : ApplicationContext
{
    const string Caption = "ClaudeUsageBar";

    readonly UsageService service;
    readonly AccountSwitcher accounts;
    readonly Texts texts;
    readonly TaskbarWindow bar;
    readonly DetailsPopup popup;
    readonly ContextMenuStrip menu = new();
    readonly List<ToolStripItem> accountItems = [];
    readonly BroadcastWindow broadcast = new();
    readonly CancellationTokenSource exiting = new();
    readonly System.Windows.Forms.Timer dockTimer = new() { Interval = 2_000 };
    readonly System.Windows.Forms.Timer tickTimer = new() { Interval = 30_000 };
    readonly System.Windows.Forms.Timer refreshTimer = new();

    public App(UsageService service, AccountSwitcher accounts, Texts texts)
    {
        this.service = service;
        this.accounts = accounts;
        this.texts = texts;
        bar = new TaskbarWindow(service.State, texts);
        popup = new DetailsPopup(texts);
        service.Changed += state =>
        {
            bar.SetState(state);
            popup.SetState(state);
        };
        accounts.Switched += () =>
        {
            service.Reset(); // the previous account's numbers must never show under the new one
            _ = RefreshNowAsync();
        };

        bar.LeftClick += TogglePopup;
        bar.RightClick += () => menu.Show(Cursor.Position);
        popup.RefreshRequested += () => _ = RefreshNowAsync();
        BuildMenu();

        dockTimer.Tick += (_, _) => { if (bar.IsAttached) bar.Reposition(); else bar.Attach(); };
        tickTimer.Tick += (_, _) => { bar.Render(); if (popup.Visible) popup.Invalidate(); };
        refreshTimer.Tick += (_, _) => _ = RefreshNowAsync();
        broadcast.TaskbarCreated += bar.Attach;
        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;

        bar.Attach();
        dockTimer.Start();
        tickTimer.Start();
        _ = RefreshNowAsync();
    }

    void BuildMenu()
    {
        var autostart = new ToolStripMenuItem(texts.Menu.StartWithWindows);
        autostart.Click += (_, _) => ToggleAutostart();
        menu.Items.Add(new ToolStripMenuItem(texts.Menu.RefreshNow, null, (_, _) => _ = RefreshNowAsync()));
        menu.Items.Add(autostart);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem(texts.Menu.Exit, null, (_, _) => ExitThread()));
        menu.Opening += (_, _) =>
        {
            autostart.Checked = Autostart.IsEnabled;
            RebuildAccountItems();
        };
    }

    /// Accounts sit at the top of the menu, so switching takes two clicks.
    void RebuildAccountItems()
    {
        foreach (var item in accountItems)
        {
            menu.Items.Remove(item);
            item.Dispose();
        }
        accountItems.Clear();
        SyncAccounts();

        IReadOnlyList<SavedAccount> all;
        try { all = AccountLabels.Ordered(accounts.Accounts); }
        catch (IOException ex) { Log.Write($"accounts: can't read the list: {ex.Message}"); all = []; }
        var now = DateTimeOffset.UtcNow;
        var activeKey = accounts.Active?.Key;

        foreach (var account in all)
        {
            bool active = account.Key == activeKey;
            // the active account also needs a new login when its tokens turned out to be revoked
            bool needsSignIn = AccountLabels.NeedsSignIn(account, now) || (active && service.State.Status == ServiceStatus.NeedsLogin);
            var item = new ToolStripMenuItem(AccountLabels.ForMenu(AccountLabels.MenuText(account, all, needsSignIn, texts))) { Checked = active };
            if (needsSignIn)
                item.Click += (_, _) => RunAccountAction(() => accounts.AddAccountAsync(account.Login.Email, exiting.Token));
            else if (!active)
                item.Click += (_, _) => RunAccountAction(() => accounts.SwitchToAsync(account.Key, exiting.Token));
            accountItems.Add(item);
        }

        accountItems.Add(new ToolStripMenuItem(texts.Accounts.Add, null, (_, _) => RunAccountAction(() => accounts.AddAccountAsync(null, exiting.Token)))
        {
            Enabled = !accounts.IsLoginRunning,
        });

        var removable = all.Where(a => a.Key != activeKey).ToList();
        if (removable.Count > 0)
        {
            var remove = new ToolStripMenuItem(texts.Accounts.Remove);
            foreach (var account in removable)
                remove.DropDownItems.Add(new ToolStripMenuItem(AccountLabels.ForMenu(AccountLabels.Label(account, all)), null, (_, _) => ConfirmRemove(account, all)));
            accountItems.Add(remove);
        }

        accountItems.Add(new ToolStripSeparator());
        for (int i = 0; i < accountItems.Count; i++) menu.Items.Insert(i, accountItems[i]);
    }

    void ConfirmRemove(SavedAccount account, IReadOnlyList<SavedAccount> all)
    {
        var question = Texts.Fill(texts.Accounts.RemoveConfirm, ("account", AccountLabels.Label(account, all)));
        if (MessageBox.Show(question, Caption, MessageBoxButtons.YesNo, MessageBoxIcon.Question) != DialogResult.Yes) return;
        try { accounts.Remove(account.Key); }
        catch (Exception ex) { Log.Write($"accounts: remove failed: {ex.Message}"); }
    }

    /// Runs an account action from the menu; a failure is explained in a message box (nothing was changed).
    async void RunAccountAction(Func<Task> action)
    {
        try { await action(); }
        catch (OperationCanceledException) { } // the app is exiting
        catch (AccountException ex)
        {
            Log.Write($"accounts: {ex.Error}: {ex.Message}");
            ShowError(ex.Error switch
            {
                AccountError.ClaudeNotFound => texts.Accounts.ClaudeNotFound,
                AccountError.LoginFailed => texts.Accounts.LoginFailed,
                _ => texts.Accounts.WriteFailed,
            });
        }
        catch (Exception ex)
        {
            Log.Write($"accounts: {ex}");
            ShowError(texts.Accounts.WriteFailed);
        }
    }

    static void ShowError(string text) => MessageBox.Show(text, Caption, MessageBoxButtons.OK, MessageBoxIcon.Warning);

    /// Saves the active login if it is new or its tokens rotated, and shows its e-mail in the popup.
    void SyncAccounts()
    {
        try { accounts.Sync(); }
        catch (Exception ex) { Log.Write($"accounts: sync failed: {ex.Message}"); }
        popup.SetAccount(accounts.Active?.Email);
    }

    async Task RefreshNowAsync()
    {
        refreshTimer.Stop();
        SyncAccounts();
        try { await service.RefreshAsync(); }
        catch (Exception ex) { Log.Write($"refresh failed: {ex}"); }
        refreshTimer.Interval = (int)Math.Clamp(service.NextDelay().TotalMilliseconds, 1_000, int.MaxValue);
        refreshTimer.Start();
    }

    void TogglePopup()
    {
        if (popup.Visible) { popup.Hide(); return; }
        // clicking the readout first deactivates (and hides) an open popup; don't reopen it right away
        if (Environment.TickCount64 - popup.HiddenAtTicks < 300) return;
        popup.ShowAbove(bar.ScreenBounds);
    }

    void ToggleAutostart()
    {
        try
        {
            if (Autostart.IsEnabled) Autostart.Disable();
            else if (Environment.ProcessPath is { } exe) Autostart.Enable(exe, texts.AutostartDescription);
        }
        catch (Exception ex) { Log.Write($"autostart toggle failed: {ex.Message}"); }
    }

    void OnPowerModeChanged(object? sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Resume) _ = RefreshNowAsync();
    }

    void OnUserPreferenceChanged(object? sender, UserPreferenceChangedEventArgs e) => bar.Render(); // light/dark switch

    protected override void ExitThreadCore()
    {
        exiting.Cancel(); // closes a running add-account login window
        exiting.Dispose();
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
        dockTimer.Dispose();
        tickTimer.Dispose();
        refreshTimer.Dispose();
        bar.Dispose();
        popup.Dispose();
        menu.Dispose();
        broadcast.DestroyHandle();
        base.ExitThreadCore();
    }
}

```

(`BroadcastWindow` below stays unchanged.)

- [ ] **Step 6: Wire `Program`**

In `src/ClaudeUsageBar/Program.cs`, replace `Application.Run(new App(service, texts));` with:

```csharp
        var accounts = new AccountSwitcher(
            CliLogin.Default(Path.Combine(dataDir, "backup")),
            new AccountStore(Path.Combine(dataDir, "accounts.dat")),
            cliLock,
            dataDir,
            (email, dir, ct) => LoginRunner.RunAsync(texts.Accounts.LoginHint, email, dir, ct),
            TimeProvider.System);
        Application.Run(new App(service, accounts, texts));
```

- [ ] **Step 7: Build and run the full suite**

Run: `dotnet test ClaudeUsageBar.sln --nologo`
Expected: PASS, all tests, with no new build warnings in `App.cs`/`Program.cs`.

- [ ] **Step 8: Smoke-run the app (read-only check)**

Exit the running ClaudeUsageBar first (right click → Exit). The single-instance mutex blocks a second copy. Then run `dotnet run --project src/ClaudeUsageBar`, right-click the readout and check:
- the current account is at the top with a check mark, labelled `e-mail · plan`
- "Add account…" is present, and "Remove account" is absent while only one account is saved
- left click: the popup header shows the e-mail right-aligned and muted

Don't click anything that switches yet; Task 8 covers that with the user. Close with Exit.

- [ ] **Step 9: Commit**

```bash
git add src/ClaudeUsageBar/UI/Primitives.cs src/ClaudeUsageBar/UI/DetailsRenderer.cs src/ClaudeUsageBar/UI/DetailsPopup.cs src/ClaudeUsageBar/App.cs src/ClaudeUsageBar/Program.cs tests/ClaudeUsageBar.Tests/PrimitivesTests.cs tests/ClaudeUsageBar.Tests/DetailsRendererTests.cs
git commit -m "feat: switch, add and remove accounts from the taskbar menu

The popup header shows the active account's e-mail.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: README and manual check on the real login

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the finished feature (Tasks 1–7).
- Produces: user documentation; the user's manual verification.

- [ ] **Step 1: Update the README**

In `README.md`, replace the line `- Right click: Refresh now · Start with Windows · Exit.` with:

```markdown
- Right click: your Claude Code accounts (click one to switch) · Add account… · Remove account ·
  Refresh now · Start with Windows · Exit.
```

Add this section after the paragraph about the rate-limited endpoint (before `## Download`):

```markdown
## Accounts

The menu lists every Claude Code account the app has seen; the active one is ticked. Clicking another account
switches Claude Code to it at once, with no browser: `claude auth status` shows the new account, new `claude`
processes use it, and running sessions use it from their next request. The bar shows the new account's limits
within seconds.

- **Add account…** opens a console window with `claude auth login` in a separate, temporary Claude Code config,
  so the current login is never signed out. If the browser is signed in to another claude.ai account, copy the
  link into a private window. The new account becomes active.
- An account whose saved login has expired (about 30 days unused) reads "sign in again"; clicking it runs the
  same login.
- **Remove account** only forgets an inactive account; it is not signed out on the server.
- An account you sign in to by hand (`/login` in Claude Code) is picked up automatically.

Switching writes Claude Code's login files: only `claudeAiOauth` in `~\.claude\.credentials.json` and
`oauthAccount` in `~\.claude.json` (plus the account caches Claude Code itself drops on logout). Settings,
plugins, MCP servers and history stay shared. A copy of both files from before the last switch is kept in
`%LOCALAPPDATA%\ClaudeUsageBar\backup\`.
```

Replace the `## Files` list with:

```markdown
- App: `app\ClaudeUsageBar.exe`
- Log and first-run marker: `%LOCALAPPDATA%\ClaudeUsageBar\`
- Saved accounts: `%LOCALAPPDATA%\ClaudeUsageBar\accounts.dat` (encrypted for your Windows user with DPAPI)
- Claude Code login files from before the last switch: `%LOCALAPPDATA%\ClaudeUsageBar\backup\`
- Autostart: `ClaudeUsageBar.lnk` in the Startup folder
```

- [ ] **Step 2: Commit the docs**

```bash
git add README.md
git commit -m "docs: account switching

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 3: Manual check with the user (real `~/.claude`)**

This step changes the user's real Claude Code login. **The Claude Code session running this plan moves to the new account too.** Hand these steps to the user and wait for their results. Don't do them yourself.

1. Exit the installed ClaudeUsageBar (right click → Exit), then run `dotnet run --project src/ClaudeUsageBar -c Release`.
2. `claude auth status`: note the account (A).
3. Right click → **Add account…** → sign in to account B in a private window. Expected: the window closes, the menu ticks B, and within seconds the bar shows B's numbers (it shows "Loading" first, never A's numbers). `claude auth status` shows B, and `claude -p ok` answers.
4. Right click → click A. Expected: `claude auth status` shows A, and `claude -p ok` works. A Claude Code session that was running keeps working on its next request.
5. Right click → **Remove account ▸** → B → confirm. B leaves the list. `claude auth status` is still A.
6. Log check: `Select-String -Path "$env:LOCALAPPDATA\ClaudeUsageBar\log.txt" -Pattern 'sk-ant|refresh-|@'` must show only masked e-mails (`x***@domain`) and no tokens.
   If this check runs from a shell that the Claude desktop app started, `%LOCALAPPDATA%` may be a stale MSIX-virtualized copy. In that case read the log from a normal terminal (or through WMI), not from that shell.
7. Confirm `%LOCALAPPDATA%\ClaudeUsageBar` has no `login-*` folder left behind.

- [ ] **Step 4: Fix whatever the manual check finds**

For each problem the user reports, write a failing test that reproduces it in the owning task's test file, fix it, re-run `dotnet test ClaudeUsageBar.sln --nologo`, and commit with a `fix:` message.
