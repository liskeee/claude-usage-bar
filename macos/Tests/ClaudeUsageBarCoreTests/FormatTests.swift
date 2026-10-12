import Foundation
import Testing
@testable import ClaudeUsageBarCore

struct FormatTests {
    @Test(arguments: [(0, .ok), (49.9, .ok), (50, .warn), (80, .warn), (80.1, .critical), (100, .critical)] as [(Double, Severity)])
    func severity_usesSpecThresholds(used: Double, expected: Severity) {
        #expect(Format.severity(used) == expected)
    }

    @Test(arguments: [(26.0, "26%"), (37.5, "38%"), (36.5, "37%"), (0.4, "0%")] as [(Double, String)])
    func percent_roundsHalfAwayFromZero(used: Double, expected: String) {
        #expect(Format.percent(used) == expected)
    }

    @Test(arguments: [
        ("en", -5, "<1m"), ("en", 30, "<1m"), ("en", 52 * 60, "52m"), ("en", 3 * 3600 + 49 * 60 + 28, "3h 49m"),
        ("en", 6 * 86400 + 17 * 3600 + 49 * 60, "6d 17h"), ("pl", 3 * 3600 + 49 * 60 + 28, "3h 49m"),
    ] as [(String, TimeInterval, String)])
    func countdownShort_isCompact(lang: String, seconds: TimeInterval, expected: String) {
        #expect(Format.countdownShort(seconds, Lang.get(lang)) == expected)
    }

    @Test(arguments: [
        ("en", 30, "in a moment"), ("en", 52 * 60, "in 52m"), ("en", 6 * 86400 + 17 * 3600 + 49 * 60, "in 6d 17h"),
        ("pl", 30, "za chwilę"), ("pl", 3 * 3600 + 49 * 60 + 28, "za 3h 49m"),
    ] as [(String, TimeInterval, String)])
    func countdownLong_isReadable(lang: String, seconds: TimeInterval, expected: String) {
        #expect(Format.countdownLong(seconds, Lang.get(lang)) == expected)
    }

    @Test(arguments: [
        ("en", -3, "just now"), ("en", 2 * 60, "2m ago"), ("en", 59 * 60 + 59, "59m ago"), ("en", 26 * 3600, "1d 2h ago"),
        ("pl", 20, "przed chwilą"), ("pl", 3600 + 5 * 60, "1h 5m temu"),
    ] as [(String, TimeInterval, String)])
    func ago_saysHowLongAgo(lang: String, seconds: TimeInterval, expected: String) {
        #expect(Format.ago(seconds, Lang.get(lang)) == expected)
    }

    @Test(arguments: [
        ("en", 1, 18, 0, "today 18:00"), ("en", 2, 8, 0, "tomorrow 08:00"), ("en", 8, 8, 0, "Thu 8 Oct, 08:00"),
        ("en", 4, 23, 5, "Sun 4 Oct, 23:05"), ("pl", 1, 18, 0, "dziś 18:00"), ("pl", 2, 8, 0, "jutro 08:00"),
        ("pl", 8, 8, 0, "czw. 8.10, 08:00"), ("pl", 4, 23, 5, "niedz. 4.10, 23:05"),
    ] as [(String, Int, Int, Int, String)])
    func resetMoment_usesRelativeDayOrWeekday(lang: String, day: Int, hour: Int, minute: Int, expected: String) {
        let now = Warsaw.date(2026, 10, 1, 14, 10) // Thursday
        let reset = Warsaw.date(2026, 10, day, hour, minute)
        #expect(Format.resetMoment(reset, now: now, Lang.get(lang), calendar: Warsaw.calendar) == expected)
    }

    @Test func resetMoment_roundsToTheNearestMinute() {
        let now = Warsaw.date(2026, 10, 1, 14, 10)
        #expect(Format.resetMoment(Warsaw.date(2026, 10, 1, 17, 59, plus: 59.9), now: now, Lang.en, calendar: Warsaw.calendar) == "today 18:00")
        #expect(Format.resetMoment(Warsaw.date(2026, 10, 1, 23, 59, plus: 59.9), now: now, Lang.en, calendar: Warsaw.calendar) == "tomorrow 00:00")
    }

    @Test(arguments: [
        ("en", LimitKind.session, nil, "Current session"), ("en", .weekly, nil, "This week"),
        ("en", .weeklyScoped, "Fable", "Fable this week"), ("en", .weeklyScoped, nil, "Model this week"),
        ("pl", .session, nil, "Sesja (5 h)"), ("pl", .weekly, nil, "Tydzień"), ("pl", .weeklyScoped, "Fable", "Fable · tydzień"),
    ] as [(String, LimitKind, String?, String)])
    func limitLabel_isTranslated(lang: String, kind: LimitKind, model: String?, expected: String) {
        #expect(Format.limitLabel(LimitInfo(kind, 10, resetsAt: nil, model: model), Lang.get(lang)) == expected)
    }

    @Test(arguments: [
        ("max", "default_claude_max_20x", "Max 20x"), ("max", "default_claude_max_5x", "Max 5x"), ("pro", nil, "Pro"), (nil, nil, ""),
    ] as [(String?, String?, String)])
    func planName_prefersRateLimitTier(subscription: String?, tier: String?, expected: String) {
        #expect(Format.planName(subscriptionType: subscription, rateLimitTier: tier) == expected)
    }

    @Test(arguments: [("lukasz@gmail.com", "l***@gmail.com"), ("a@b.pl", "a***@b.pl"), ("no-at-sign", "***"), ("", "***")])
    func maskEmail_keepsFirstLetterAndDomain(email: String, expected: String) {
        #expect(Format.maskEmail(email) == expected)
    }
}
