import Foundation
import Testing
@testable import ClaudeUsageBarCore

struct DisplayTextTests {
    let now = iso("2026-10-01T14:00:00+02:00")

    func state(_ status: ServiceStatus, lastSuccess: Date? = nil, snapshot: UsageSnapshot? = nil, plan: String = "") -> UsageState {
        UsageState(status: status, snapshot: snapshot, planName: plan, lastSuccess: lastSuccess, lastError: nil)
    }

    @Test func footer_saysHowOldTheDataIs() {
        #expect(DisplayText.footer(state(.ok, lastSuccess: now.addingTimeInterval(-120)), now: now, Lang.en) == "Updated 2m ago")
        #expect(DisplayText.footer(state(.error, lastSuccess: now.addingTimeInterval(-20 * 60)), now: now, Lang.en) == "Refresh failed · updated 20m ago")
        #expect(DisplayText.footer(state(.error), now: now, Lang.en) == "Couldn't load data")
        #expect(DisplayText.footer(state(.needsLogin), now: now, Lang.en) == "Sign in: run claude in a terminal")
        #expect(DisplayText.footer(state(.loading), now: now, Lang.en) == "Loading…")
        #expect(DisplayText.footer(state(.ok, lastSuccess: now), now: now, Lang.pl) == "Odświeżono przed chwilą")
    }

    @Test func resetLine_hasCountdownAndMoment() {
        let reset = Warsaw.date(2026, 10, 1, 18, 0)
        #expect(DisplayText.resetLine(reset, now: Warsaw.date(2026, 10, 1, 14, 11), Lang.en, calendar: Warsaw.calendar) == "Resets in 3h 49m · today 18:00")
    }

    @Test func empty_explainsWhyThereIsNoData() {
        #expect(DisplayText.empty(state(.needsLogin), Lang.en) == "No data: Claude Code login expired")
        #expect(DisplayText.empty(state(.error), Lang.en) == "No data yet · retrying in a few minutes")
        #expect(DisplayText.empty(state(.loading), Lang.en) == "Loading data…")
    }

    @Test func heading_namesThePlanOnceKnown() {
        #expect(DisplayText.heading(state(.loading)) == "Claude")
        #expect(DisplayText.heading(state(.ok, plan: "Max 20x")) == "Claude Max 20x")
    }

    @Test func isStale_after15MinutesOrWithoutData() {
        #expect(DisplayText.isStale(state(.loading), now: now))
        #expect(!DisplayText.isStale(state(.ok, lastSuccess: now.addingTimeInterval(-15 * 60)), now: now))
        #expect(DisplayText.isStale(state(.ok, lastSuccess: now.addingTimeInterval(-15 * 60 - 1)), now: now))
    }

    @Test func accessibility_readsBothLimits() throws {
        let snapshot = try UsageParser.parse(Fixtures.usage, fetchedAt: now)
        let text = DisplayText.accessibility(state(.ok, lastSuccess: now, snapshot: snapshot), now: Warsaw.date(2026, 10, 1, 14, 11), Lang.en, calendar: Warsaw.calendar)
        #expect(text.hasPrefix("Current session 26%, Resets in 3h 49m · today 18:00; This week 22%, Resets in 6d 17h"))
        #expect(DisplayText.accessibility(state(.needsLogin), now: now, Lang.en) == "Claude: sign in")
        #expect(DisplayText.accessibility(state(.loading), now: now, Lang.en) == "Claude: Loading…")
    }
}
