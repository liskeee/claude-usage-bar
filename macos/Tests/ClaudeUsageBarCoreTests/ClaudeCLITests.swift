import Foundation
import Testing
@testable import ClaudeUsageBarCore

struct ClaudeCLITests {
    let home = URL(fileURLWithPath: "/Users/jan")

    @Test func find_withMinimalPath_findsClaudeInLocalBin() {
        // what an app started at login gets
        let found = ClaudeCLI.find(path: "/usr/bin:/bin:/usr/sbin:/sbin", home: home) { $0 == "/Users/jan/.local/bin/claude" }
        #expect(found?.path == "/Users/jan/.local/bin/claude")
    }

    @Test func find_prefersPath_thenTheInstallerLocations() {
        let everywhere = ClaudeCLI.find(path: "/custom/bin", home: home) { _ in true }
        #expect(everywhere?.path == "/custom/bin/claude")
        #expect(ClaudeCLI.searchDirectories(path: nil, home: home).map(\.path) == ["/Users/jan/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"])
        #expect(ClaudeCLI.find(path: nil, home: home) { _ in false } == nil)
    }

    @Test func cleanEnvironment_dropsClaudeAndAnthropicVariables() {
        let env = ["CLAUDE_CONFIG_DIR": "/x", "ClaudeCode_Thing": "1", "ANTHROPIC_API_KEY": "sk", "anthropic_base_url": "u", "HOME": "/Users/jan", "PATH": "/bin"]
        #expect(ClaudeCLI.cleanEnvironment(env) == ["HOME": "/Users/jan", "PATH": "/bin"])
    }

    @Test func childEnvironment_putsTheInstallerLocationsOnPath() {
        let env = ClaudeCLI.childEnvironment(["PATH": "/usr/bin:/bin", "ANTHROPIC_API_KEY": "sk"], home: home)
        #expect(env["PATH"] == "/usr/bin:/bin:/Users/jan/.local/bin:/opt/homebrew/bin:/usr/local/bin")
        #expect(env["ANTHROPIC_API_KEY"] == nil)
    }
}
