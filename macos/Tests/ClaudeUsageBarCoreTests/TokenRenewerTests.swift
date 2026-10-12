import Foundation
import Testing
@testable import ClaudeUsageBarCore

@MainActor struct TokenRenewerTests {
    let time = FakeTime(iso("2026-10-01T12:00:00Z"))
    let lock = AsyncLock()

    @MainActor final class Counter { var runs = 0 }

    func renewer(_ counter: Counter, succeeds: Bool = true) -> CliTokenRenewer {
        CliTokenRenewer(time: time, cliLock: lock) { counter.runs += 1; return succeeds }
    }

    @Test func tryRenew_runsTheCli_atMostOnceIn30Minutes() async {
        let counter = Counter()
        let renewer = renewer(counter)

        #expect(await renewer.tryRenew())
        time.advance(29 * 60)
        #expect(!(await renewer.tryRenew()))
        time.advance(2 * 60)
        #expect(await renewer.tryRenew())
        #expect(counter.runs == 2)
    }

    @Test func reset_allowsAnImmediateRenewal() async {
        let counter = Counter()
        let renewer = renewer(counter, succeeds: false)

        #expect(!(await renewer.tryRenew()))
        renewer.reset()
        _ = await renewer.tryRenew()
        #expect(counter.runs == 2)
    }

    @Test func tryRenew_waitsForTheCliLock() async {
        let counter = Counter()
        let renewer = renewer(counter)
        await lock.lock() // an account switch is writing the login

        let renewing = Task { await renewer.tryRenew() }
        for _ in 0..<10 { await Task.yield() }
        #expect(counter.runs == 0)

        lock.unlock()
        #expect(await renewing.value)
        #expect(!lock.isLocked)
    }

    @Test func arguments_areATinyHaikuCallThatSavesNothing() {
        #expect(CliTokenRenewer.arguments == ["-p", "ok", "--model", "haiku", "--safe-mode", "--no-session-persistence"])
    }
}
