import Foundation

/// Where the app keeps its files: Application Support (accounts, backup, login dirs), Logs.
public struct AppPaths: Sendable {
    public let home: URL
    public let support: URL
    public let logs: URL

    public init(home: URL) {
        self.home = home
        support = home.appending(path: "Library/Application Support/ClaudeUsageBar")
        logs = home.appending(path: "Library/Logs/ClaudeUsageBar")
    }

    public static func standard() -> AppPaths { AppPaths(home: FileManager.default.homeDirectoryForCurrentUser) }

    public var accountsFile: URL { support.appending(path: "accounts.dat") }
    public var backupDir: URL { support.appending(path: "backup") }
    public var renewDir: URL { support.appending(path: "renew") }
    public var firstRunMarker: URL { support.appending(path: "first-run") }
    /// Claude Code's global config for its default config dir.
    public var claudeGlobalConfig: URL { home.appending(path: ".claude.json") }
}
