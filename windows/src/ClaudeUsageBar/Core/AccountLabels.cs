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
