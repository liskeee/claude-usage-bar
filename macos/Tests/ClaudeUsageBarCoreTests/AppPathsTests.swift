import Foundation
import Testing
@testable import ClaudeUsageBarCore

struct AppPathsTests {
    @Test func everythingLivesUnderTheUsersLibraryOrHome() {
        let paths = AppPaths(home: URL(fileURLWithPath: "/Users/jan"))
        #expect(paths.support.path == "/Users/jan/Library/Application Support/ClaudeUsageBar")
        #expect(paths.logs.path == "/Users/jan/Library/Logs/ClaudeUsageBar")
        #expect(paths.accountsFile.path == "/Users/jan/Library/Application Support/ClaudeUsageBar/accounts.dat")
        #expect(paths.backupDir.path == "/Users/jan/Library/Application Support/ClaudeUsageBar/backup")
        #expect(paths.renewDir.path == "/Users/jan/Library/Application Support/ClaudeUsageBar/renew")
        #expect(paths.firstRunMarker.path == "/Users/jan/Library/Application Support/ClaudeUsageBar/first-run")
        #expect(paths.claudeGlobalConfig.path == "/Users/jan/.claude.json")
    }
}
