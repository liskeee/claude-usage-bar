import Foundation
import Testing
@testable import ClaudeUsageBarCore

struct UsageParserTests {
    let fetchedAt = iso("2026-10-01T13:41:47+02:00")

    @Test func realResponse_readsSessionWeeklyAndScopedLimits() throws {
        let snap = try UsageParser.parse(Fixtures.usage, fetchedAt: fetchedAt)

        #expect(snap.limits.count == 3)
        #expect(snap.session == LimitInfo(.session, 26, resetsAt: iso("2026-10-01T18:00:00.345899+02:00")))
        #expect(snap.weekly == LimitInfo(.weekly, 22, resetsAt: iso("2026-10-08T08:00:00.345927+02:00")))
        #expect(snap.limits[2] == LimitInfo(.weeklyScoped, 3, resetsAt: iso("2026-10-08T08:00:00.346176+02:00"), model: "Fable"))
        #expect(snap.fetchedAt == fetchedAt)
    }

    @Test func microsecondTimestamps_keepTheirFraction() {
        let withFraction = UsageParser.date("2026-10-01T18:00:00.345899+02:00")!
        let whole = UsageParser.date("2026-10-01T16:00:00Z")!
        #expect(abs(withFraction.timeIntervalSince(whole) - 0.345899) < 0.000_01)
    }

    @Test func withoutLimitsArray_fallsBackToFiveHourAndSevenDay() throws {
        let json = """
            {"five_hour":{"utilization":41.0,"resets_at":"2026-10-01T18:00:00+02:00"},
             "seven_day":{"utilization":12.5,"resets_at":"2026-10-08T08:00:00+02:00"}}
            """
        let snap = try UsageParser.parse(json, fetchedAt: fetchedAt)

        #expect(snap.limits.count == 2)
        #expect(snap.session?.usedPercent == 41.0)
        #expect(snap.weekly?.usedPercent == 12.5)
        #expect(snap.weekly?.resetsAt == iso("2026-10-08T08:00:00+02:00"))
    }

    @Test func skipsUnknownKindsAndEntriesWithoutPercent() throws {
        let json = """
            {"limits":[
              {"kind":"session","percent":5,"resets_at":null},
              {"kind":"monthly_mystery","percent":50,"resets_at":"2026-11-01T00:00:00Z"},
              {"kind":"weekly_all","percent":null,"resets_at":"2026-10-08T08:00:00Z"}]}
            """
        let snap = try UsageParser.parse(json, fetchedAt: fetchedAt)

        #expect(snap.limits == [LimitInfo(.session, 5, resetsAt: nil)])
        #expect(snap.weekly == nil)
    }

    @Test func scopedLimitWithoutModelName_hasNoModel() throws {
        let json = #"{"limits":[{"kind":"weekly_scoped","percent":7,"resets_at":null,"scope":null}]}"#
        #expect(try UsageParser.parse(json, fetchedAt: fetchedAt).limits == [LimitInfo(.weeklyScoped, 7, resetsAt: nil)])
    }

    @Test func notJSON_throws() {
        #expect(throws: (any Error).self) { try UsageParser.parse("<html>maintenance</html>", fetchedAt: fetchedAt) }
    }
}
