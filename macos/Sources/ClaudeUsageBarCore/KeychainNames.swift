import CryptoKit
import Foundation

public enum KeychainNames {
    /// Claude Code's login item for its default config dir.
    public static let claudeService = "Claude Code-credentials"
    /// This app's own item, holding the key that encrypts accounts.dat.
    public static let appService = "ClaudeUsageBar"
    public static let accountsKeyAccount = "accounts-key"

    /// With CLAUDE_CONFIG_DIR set, Claude Code appends the first 8 hex digits of sha256(the dir, NFC-normalised).
    public static func claudeService(configDir: String?) -> String {
        guard let configDir, !configDir.isEmpty else { return claudeService }
        let digest = SHA256.hash(data: Data(configDir.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(claudeService)-\(hex.prefix(8))"
    }

    /// The Keychain account Claude Code uses: $USER when it is a plain name, otherwise its fallback.
    public static func account(user: String?) -> String {
        guard let user, user.wholeMatch(of: #/[a-zA-Z0-9._-]+/#) != nil else { return "claude-code-user" }
        return user
    }

    public static var currentUser: String {
        let user = ProcessInfo.processInfo.environment["USER"]
        return account(user: user?.isEmpty == false ? user : NSUserName())
    }
}
