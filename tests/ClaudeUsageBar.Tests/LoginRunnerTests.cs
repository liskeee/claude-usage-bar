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
