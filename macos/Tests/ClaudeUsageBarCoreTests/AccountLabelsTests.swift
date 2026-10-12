import Foundation
import Testing
@testable import ClaudeUsageBarCore

struct AccountLabelsTests {
    let now = iso("2026-10-06T12:00:00Z")

    func saved(_ login: AccountLogin) -> SavedAccount { SavedAccount(login: login, savedAt: now) }

    @Test func label_isEmailAndPlan() {
        let a = saved(Logins.make("a", "jan@firma.pl", tier: "default_claude_max_5x"))
        #expect(AccountLabels.label(a, among: [a]) == "jan@firma.pl · Max 5x")
    }

    @Test func label_sameEmailAndPlanInTwoOrganizations_addsTheOrganization() {
        let personal = saved(Logins.make("a", "jan@firma.pl", orgName: "Personal"))
        let work = saved(Logins.make("a", "jan@firma.pl", org: "org-2", orgName: "R&D"))

        #expect(AccountLabels.label(personal, among: [personal, work]) == "jan@firma.pl · Max 5x · Personal")
        #expect(AccountLabels.label(work, among: [personal, work]) == "jan@firma.pl · Max 5x · R&D")
    }

    @Test func ordered_isAlphabeticalByEmail() {
        let z = saved(Logins.make("z", "zofia@x.pl"))
        let a = saved(Logins.make("a", "Adam@x.pl"))
        #expect(AccountLabels.ordered([z, a]).map(\.login.email) == ["Adam@x.pl", "zofia@x.pl"])
    }

    @Test(arguments: [(-1, true), (0, true), (1, false)])
    func needsSignIn_onceTheRefreshTokenExpired(hoursFromNow: Double, expected: Bool) {
        let account = saved(Logins.make("a", "a@x.pl", refreshExpires: now.addingTimeInterval(hoursFromNow * 3600)))
        #expect(AccountLabels.needsSignIn(account, now: now) == expected)
    }

    @Test func needsSignIn_unknownExpiry_isFalse() {
        let login = Logins.make("a", "a@x.pl")
        var oauth = login.secure["claudeAiOauth"]!.object!
        oauth.removeValue(forKey: "refreshTokenExpiresAt")

        #expect(!AccountLabels.needsSignIn(saved(AccountLogin(secure: ["claudeAiOauth": .object(oauth)], account: login.account)), now: now))
    }

    @Test(arguments: [("en", false, "a@x.pl · Max 5x"), ("en", true, "a@x.pl · Max 5x — sign in again"), ("pl", true, "a@x.pl · Max 5x — zaloguj ponownie")])
    func menuText_marksAccountsThatNeedANewLogin(lang: String, needsSignIn: Bool, expected: String) {
        let a = saved(Logins.make("a", "a@x.pl"))
        #expect(AccountLabels.menuText(a, among: [a], needsSignIn: needsSignIn, Lang.get(lang)) == expected)
    }
}
