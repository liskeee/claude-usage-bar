import Foundation
import Testing
@testable import ClaudeUsageBarCore

@MainActor struct CredentialStoreTests {
    let fake = FakeSecurity()
    var store: KeychainCredentialStore { KeychainCredentialStore(keychain: SecurityCLI(runner: fake), account: "tester") }

    func item(_ json: String) { fake[KeychainNames.claudeService, "tester"] = Data(json.utf8) }

    @Test func read_takesTokenExpiryAndPlanFromClaudeAiOauth() async throws {
        item(#"{"claudeAiOauth":{"accessToken":"tok","expiresAt":1790271138070,"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"},"mcpOAuth":{}}"#)

        let creds = try await store.read()

        #expect(creds == Credentials(accessToken: "tok", expiresAt: Date(timeIntervalSince1970: 1790271138.070),
                                     subscriptionType: "max", rateLimitTier: "default_claude_max_20x"))
        #expect(!String(describing: creds!).contains("tok"))
    }

    @Test(arguments: [nil, "not json", #"{"mcpOAuth":{}}"#, #"{"claudeAiOauth":{"accessToken":""}}"#] as [String?])
    func read_withoutAUsableLogin_isNil(json: String?) async throws {
        if let json { item(json) }
        #expect(try await store.read() == nil)
    }

    @Test func read_missingExpiry_countsAsExpired() async throws {
        item(#"{"claudeAiOauth":{"accessToken":"tok"}}"#)
        #expect(try await store.read()?.expiresAt == .distantPast)
    }

    @Test func read_lockedKeychain_throws() async {
        fake.isLocked = true
        await #expect(throws: KeychainError.locked) { _ = try await store.read() }
    }
}
