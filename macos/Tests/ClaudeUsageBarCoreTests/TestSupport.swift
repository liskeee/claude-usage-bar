import Foundation
@testable import ClaudeUsageBarCore

/// Paths in the monorepo, found from this file: macos/Tests/ClaudeUsageBarCoreTests/TestSupport.swift.
enum Repo {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let localization = root.appending(path: "shared/localization")
    static let fixtures = root.appending(path: "shared/fixtures")
}

enum Fixtures {
    /// Real /api/oauth/usage response captured on 2026-10-01 13:41 (no secrets inside).
    static var usage: String {
        try! String(contentsOf: Repo.fixtures.appending(path: "usage-2026-10-01.json"), encoding: .utf8)
    }
}

func iso(_ text: String) -> Date { UsageParser.date(text)! }
