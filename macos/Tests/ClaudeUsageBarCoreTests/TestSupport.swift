import Foundation
@testable import ClaudeUsageBarCore

/// Paths in the monorepo, found from this file: macos/Tests/ClaudeUsageBarCoreTests/TestSupport.swift.
enum Repo {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let localization = root.appending(path: "shared/localization")
    static let fixtures = root.appending(path: "shared/fixtures")
}

enum Fixtures {
    /// Real /api/oauth/usage response captured on 2026-10-01 13:41 (no secrets inside).
    static var usage: String {
        try! String(contentsOf: Repo.fixtures.appending(path: "usage-2026-10-01.json"), encoding: .utf8)
    }
}

func iso(_ text: String) -> Date { UsageParser.date(text)! }

enum Lang {
    static let en = try! Texts.load("en", from: Repo.localization)
    static let pl = try! Texts.load("pl", from: Repo.localization)
    static func get(_ code: String) -> Texts { code == "pl" ? pl : en }
}

/// Dates in a fixed time zone, so formatting tests don't depend on the machine running them.
enum Warsaw {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Warsaw")!
        return calendar
    }()

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, plus seconds: Double = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
            .addingTimeInterval(seconds)
    }
}
