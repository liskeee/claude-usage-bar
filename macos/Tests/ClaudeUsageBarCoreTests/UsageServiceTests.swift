import Foundation
import Testing
@testable import ClaudeUsageBarCore

@MainActor struct UsageServiceTests {
    let now = iso("2026-10-01T14:00:00+02:00")
    let creds = FakeCredentials()
    let api = FakeAPI()
    let renewer = FakeRenewer()
    let time: FakeTime

    init() { time = FakeTime(now) }

    func valid(_ token: String = "token-a") -> Credentials {
        Credentials(accessToken: token, expiresAt: now.addingTimeInterval(7200), subscriptionType: "max", rateLimitTier: "default_claude_max_20x")
    }

    func expired(_ token: String = "token-old") -> Credentials {
        Credentials(accessToken: token, expiresAt: now.addingTimeInterval(-3600), subscriptionType: "max", rateLimitTier: "default_claude_max_20x")
    }

    func make() -> UsageService { UsageService(credentials: creds, api: api, renewer: renewer, time: time) }

    @Test func validToken_fetchesUsage_withoutRenewing() async {
        creds.current = valid()
        let service = make()

        await service.refresh()

        #expect(service.state.status == .ok)
        #expect(service.state.snapshot?.session?.usedPercent == 26)
        #expect(service.state.planName == "Max 20x")
        #expect(service.state.lastSuccess == now)
        #expect(renewer.calls == 0)
        #expect(api.tokens == ["token-a"])
    }

    @Test func expiredToken_renewsThenFetchesWithTheNewToken() async {
        creds.current = expired()
        renewer.onRenew = { [creds, self] in creds.current = self.valid("token-new"); return true }
        let service = make()

        await service.refresh()

        #expect(service.state.status == .ok)
        #expect(renewer.calls == 1)
        #expect(api.tokens == ["token-new"])
    }

    @Test func expiredToken_renewFails_needsLogin_withoutCallingTheAPI() async {
        creds.current = expired()
        let service = make()

        await service.refresh()

        #expect(service.state.status == .needsLogin)
        #expect(api.tokens.isEmpty)
    }

    @Test func noLogin_triesToRenew_thenNeedsLogin() async {
        let service = make()

        await service.refresh()

        #expect(service.state.status == .needsLogin)
        #expect(renewer.calls == 1)
    }

    @Test func unauthorized_renewsAndRetriesOnce() async {
        creds.current = valid("token-revoked")
        api.respond = { $0 == "token-revoked" ? .unauthorized : .ok(Fixtures.usage) }
        renewer.onRenew = { [creds, self] in creds.current = self.valid("token-new"); return true }
        let service = make()

        await service.refresh()

        #expect(service.state.status == .ok)
        #expect(api.tokens == ["token-revoked", "token-new"])
    }

    @Test func unauthorizedAgainAfterRenew_needsLogin() async {
        creds.current = valid()
        api.respond = { _ in .unauthorized }
        renewer.onRenew = { true }
        let service = make()

        await service.refresh()

        #expect(service.state.status == .needsLogin)
        #expect(api.tokens.count == 2)
    }

    @Test(arguments: [UsageAPIResult.failed("HTTP 503"), .rateLimited])
    func failedFetch_whileDataIsFresh_staysOk(failure: UsageAPIResult) async {
        creds.current = valid()
        let service = make()
        await service.refresh()
        time.advance(2 * 60) // e.g. a manual "Refresh" right after the automatic one
        api.respond = { _ in failure }

        await service.refresh()

        #expect(service.state.status == .ok)
        #expect(service.state.snapshot?.session?.usedPercent == 26)
        #expect(service.state.lastSuccess == now)
        #expect(service.state.lastError == failure.error)
    }

    @Test func failedFetch_whenDataIsStale_isAnError() async {
        creds.current = valid()
        let service = make()
        await service.refresh()
        time.advance(16 * 60)
        api.respond = { _ in .failed("HTTP 503") }

        await service.refresh()

        #expect(service.state.status == .error)
        #expect(service.state.snapshot?.session?.usedPercent == 26)
        #expect(service.state.lastSuccess == now)
    }

    @Test func lockedKeychain_isATransientError_notASignIn() async {
        creds.current = valid()
        let service = make()
        await service.refresh()
        time.advance(16 * 60)
        creds.error = KeychainError.locked

        await service.refresh()

        #expect(service.state.status == .error)
        #expect(service.state.snapshot?.session?.usedPercent == 26)
        #expect(service.state.lastError == "Keychain locked")
        #expect(renewer.calls == 0)
    }

    @Test func successAfterFailure_clearsTheError() async {
        creds.current = valid()
        let service = make()
        api.respond = { _ in .failed("HTTP 503") }
        await service.refresh()
        api.respond = { _ in .ok(Fixtures.usage) }

        await service.refresh()

        #expect(service.state.lastError == nil)
    }

    @Test func rateLimited_keepsTheLastSnapshot_andBacksOffExponentially() async {
        creds.current = valid()
        let service = make()
        await service.refresh()
        api.respond = { _ in .rateLimited }

        var delays: [TimeInterval] = []
        for _ in 0..<4 {
            await service.refresh()
            delays.append(service.nextDelay())
        }

        #expect(service.state.snapshot?.session?.usedPercent == 26)
        let minutes: [TimeInterval] = [10, 20, 30, 30]
        #expect(delays == minutes.map { $0 * 60 })
    }

    @Test func successAfterRateLimit_returnsToThePollInterval() async {
        creds.current = valid()
        api.respond = { _ in .rateLimited }
        let service = make()
        await service.refresh()
        api.respond = { _ in .ok(Fixtures.usage) }

        await service.refresh()

        #expect(service.state.status == .ok)
        #expect(service.nextDelay() == UsageService.pollInterval)
    }

    @Test func rateLimited_ignoresTheSessionResetShortcut() async {
        creds.current = valid()
        let service = make()
        await service.refresh()
        time.set(iso("2026-10-01T17:58:00+02:00"))
        creds.current?.expiresAt = time.now().addingTimeInterval(7200)
        api.respond = { _ in .rateLimited }

        await service.refresh()

        #expect(service.nextDelay() == 10 * 60)
    }

    @Test func unreadableResponse_isAnError() async {
        creds.current = valid()
        api.respond = { _ in .ok("<html>maintenance</html>") }
        let service = make()

        await service.refresh()

        #expect(service.state.status == .error)
        #expect(service.state.snapshot == nil)
        #expect(service.state.lastError == "Unreadable API response")
    }

    @Test func onChange_getsTheNewState() async {
        creds.current = valid()
        let service = make()
        var seen: UsageState?
        service.onChange = { seen = $0 }

        await service.refresh()

        #expect(seen == service.state)
    }

    @Test func nextDelay_isThePollInterval_whenTheResetIsFar() async {
        creds.current = valid()
        let service = make()
        await service.refresh() // session resets at 18:00, now 14:00

        #expect(service.nextDelay() == UsageService.pollInterval)
    }

    @Test func nextDelay_wakesShortlyAfterTheSessionReset() async {
        creds.current = valid()
        let service = make()
        await service.refresh()
        time.set(iso("2026-10-01T17:58:00+02:00"))

        // fixture: the session resets at 18:00:00.345899 → 2 min 0.35 s + 15 s
        #expect((135...136).contains(service.nextDelay()))
    }

    @Test func reset_forgetsTheAccountsData_andBackoff() async {
        creds.current = valid()
        let service = make()
        await service.refresh()
        api.respond = { _ in .rateLimited }
        await service.refresh()
        var seen: UsageState?
        service.onChange = { seen = $0 }

        service.reset()

        #expect(service.state == .initial)
        #expect(seen == .initial)
        #expect(service.nextDelay() == UsageService.pollInterval)
        #expect(renewer.resets == 1)
    }

    @Test func refreshStartedBeforeReset_doesNotShowTheOldAccount() async {
        creds.current = valid()
        let response = Pending<UsageAPIResult>()
        api.respondAsync = { _ in await response.wait() }
        let service = make()
        let refresh = Task { await service.refresh() } // fetching for the account being left
        while api.tokens.isEmpty { await Task.yield() }

        service.reset() // switched meanwhile
        response.resolve(.ok(Fixtures.usage))
        await refresh.value

        #expect(service.state == .initial)
    }

    @Test func refreshStartedBeforeReset_doesNotSlowDownTheNewAccount() async {
        creds.current = valid()
        let response = Pending<UsageAPIResult>()
        api.respondAsync = { _ in await response.wait() }
        let service = make()
        let refresh = Task { await service.refresh() }
        while api.tokens.isEmpty { await Task.yield() }

        service.reset()
        response.resolve(.rateLimited)
        await refresh.value

        #expect(service.nextDelay() == UsageService.pollInterval)
    }
}
