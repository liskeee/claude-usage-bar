import Foundation
import Testing
@testable import ClaudeUsageBarCore

struct AccountLoginTests {
    @Test func keepsOnlyTheAccountScopedKeychainKeys() {
        let login = AccountLogin(
            secure: ["claudeAiOauth": .object([:]), "organizationUuid": .string("o"), "trustedDeviceToken": .string("t"), "mcpOAuth": .object([:])],
            account: [:])
        #expect(Set(login.secure.keys) == ["claudeAiOauth", "organizationUuid", "trustedDeviceToken"])
    }

    @Test func readsWhoItIsAndWhichPlan() {
        let login = Logins.make("a", "jan@firma.pl", org: "org-9", orgName: "Firma", tier: "default_claude_max_20x")

        #expect(login.key == AccountKey(accountUuid: "acc-a", organizationUuid: "org-9"))
        #expect(login.email == "jan@firma.pl")
        #expect(login.organizationName == "Firma")
        #expect(login.refreshToken == "refresh-a-1")
        #expect(login.refreshTokenExpiresAt == Logins.defaultRefreshExpiry)
        #expect(login.planName == "Max 20x")
    }

    @Test func description_hidesTokensAndTheEmail() {
        let text = String(describing: Logins.make("a", "jan@firma.pl"))
        #expect(text == "j***@firma.pl acc-a/org-1")
    }
}
