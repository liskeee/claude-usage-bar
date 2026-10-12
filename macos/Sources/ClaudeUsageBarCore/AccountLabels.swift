import Foundation

/// How saved accounts read in the menu.
public enum AccountLabels {
    /// Alphabetical by e-mail, then organization.
    public static func ordered(_ accounts: [SavedAccount]) -> [SavedAccount] {
        accounts.sorted {
            ($0.login.email.lowercased(), ($0.login.organizationName ?? "").lowercased())
                < ($1.login.email.lowercased(), ($1.login.organizationName ?? "").lowercased())
        }
    }

    /// "jan@firma.pl · Max 5x"; the organization is added when another saved account would read the same.
    public static func label(_ account: SavedAccount, among all: [SavedAccount]) -> String {
        let label = basic(account.login)
        let ambiguous = all.contains { $0.key != account.key && basic($0.login) == label }
        return ambiguous ? "\(label) · \(account.login.organizationName ?? account.key.organizationUuid)" : label
    }

    /// Past refreshTokenExpiresAt the saved tokens can't be renewed: only a new login helps.
    public static func needsSignIn(_ account: SavedAccount, now: Date) -> Bool {
        guard let expires = account.login.refreshTokenExpiresAt else { return false }
        return expires <= now
    }

    public static func menuText(_ account: SavedAccount, among all: [SavedAccount], needsSignIn: Bool, _ texts: Texts) -> String {
        needsSignIn ? Texts.fill(texts.accounts.signInAgain, ("account", label(account, among: all))) : label(account, among: all)
    }

    static func basic(_ login: AccountLogin) -> String {
        login.planName.isEmpty ? login.email : "\(login.email) · \(login.planName)"
    }
}
