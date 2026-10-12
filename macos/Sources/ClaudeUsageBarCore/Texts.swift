import Foundation

/// UI strings for one language, from shared/localization/<code>.json (copied into the app bundle).
/// Templates use named placeholders such as {time}; see `fill`.
public struct Texts: Decodable, Sendable {
    public let limits: Limits
    public let bar: Bar
    public let time: Time
    public let popup: Popup
    public let menu: Menu
    public let accounts: Accounts
    public let macos: Mac

    public struct Limits: Decodable, Sendable {
        public let session, weekly, scoped, unknownModel: String
    }

    public struct Bar: Decodable, Sendable {
        public let session, week, signIn: String
    }

    public struct Time: Decodable, Sendable {
        public let lessThanMinute, minutes, hoursMinutes, daysHours, inAMoment, `in`, justNow, ago, today, tomorrow, otherDay: String
        public let weekdays, months: [String]
    }

    public struct Popup: Decodable, Sendable {
        public let resetLine, updated, refreshFailed, loadFailed, signIn, loading, emptyLoading, emptyError, emptyNeedsLogin, refresh: String
    }

    /// The shared menu text the Mac uses; `startWithWindows` and `exit` are Windows-only.
    public struct Menu: Decodable, Sendable {
        public let refreshNow: String
    }

    /// Shared account texts; the shared `claudeNotFound` names claude.exe, so the Mac one lives in `macos`.
    public struct Accounts: Decodable, Sendable {
        public let add, remove, signInAgain, removeConfirm, loginHint, loginFailed, writeFailed: String
    }

    /// Texts only the Mac app has.
    public struct Mac: Decodable, Sendable {
        public let menu: MacMenu
        public let accounts: MacAccounts
        public let dialogs: Dialogs

        public struct MacMenu: Decodable, Sendable { public let startAtLogin, quit: String }
        public struct MacAccounts: Decodable, Sendable { public let claudeNotFound: String }
        public struct Dialogs: Decodable, Sendable { public let remove, cancel, ok: String }
    }

    public static let fallback = "en"

    /// Two-letter codes of the translations in `directory`.
    public static func available(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(".json".count)) }.sorted()
    }

    /// Throws when the file is missing or lacks a text.
    public static func load(_ code: String, from directory: URL) throws -> Texts {
        try JSONDecoder().decode(Texts.self, from: Data(contentsOf: directory.appending(path: "\(code).json")))
    }

    /// The first preferred system language if it is translated, English otherwise.
    public static func languageCode(preferred: [String], available: [String]) -> String {
        guard let first = preferred.first else { return fallback }
        let code = String(first.prefix { $0 != "-" && $0 != "_" }).lowercased()
        return available.contains(code) ? code : fallback
    }

    public static func fill(_ template: String, _ values: (String, String)...) -> String {
        values.reduce(template) { text, pair in text.replacingOccurrences(of: "{\(pair.0)}", with: pair.1) }
    }
}
