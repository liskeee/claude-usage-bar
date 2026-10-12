import Foundation
import Testing
@testable import ClaudeUsageBarCore

struct KeychainNamesTests {
    @Test func defaultConfig_usesThePlainService() {
        #expect(KeychainNames.claudeService(configDir: nil) == "Claude Code-credentials")
    }

    // expected suffixes: printf '%s' <dir> | shasum -a 256 | cut -c1-8
    @Test func configDir_addsTheFirst8HexDigitsOfItsSha256() {
        #expect(KeychainNames.claudeService(configDir: "/tmp/cub-login") == "Claude Code-credentials-ea821fc5")
        #expect(KeychainNames.claudeService(configDir: "/Users/x/Library/Application Support/ClaudeUsageBar/login-abc")
            == "Claude Code-credentials-803d2c15")
    }

    @Test func configDir_isNFCNormalisedFirst() {
        let decomposed = "/tmp/zażółć".decomposedStringWithCanonicalMapping
        #expect(KeychainNames.claudeService(configDir: decomposed) == "Claude Code-credentials-34cc2634")
        #expect(KeychainNames.claudeService(configDir: "/tmp/zażółć") == "Claude Code-credentials-34cc2634")
    }

    @Test(arguments: [("lukaszlis", "lukaszlis"), ("a.b_c-d", "a.b_c-d"), ("jan kowalski", "claude-code-user"), ("", "claude-code-user")])
    func account_isTheUserOrClaudeCodesFallback(user: String, expected: String) {
        #expect(KeychainNames.account(user: user) == expected)
    }
}
