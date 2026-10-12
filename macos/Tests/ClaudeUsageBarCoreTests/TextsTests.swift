import Foundation
import Testing
@testable import ClaudeUsageBarCore

struct TextsTests {
    // every placeholder the code fills in; a typo in a translation shows up as an unknown one
    static let knownPlaceholders: Set<String> =
        ["model", "m", "h", "d", "duration", "time", "weekday", "day", "month", "monthNumber", "countdown", "moment", "ago", "account"]
    static let languages = Texts.available(in: Repo.localization)

    @Test func englishAndPolish_areAvailable() {
        #expect(Set(Self.languages).isSuperset(of: ["en", "pl"]))
    }

    @Test(arguments: TextsTests.languages)
    func everyLanguage_hasEveryMacText_withoutEmptyValues(code: String) throws {
        let texts = try Texts.load(code, from: Repo.localization) // throws when a text the Mac reads is missing

        for (path, value) in strings(texts) {
            #expect(!value.trimmingCharacters(in: .whitespaces).isEmpty, "\(code): \(path) is empty")
        }
        #expect(texts.time.weekdays.count == 7)
        #expect(texts.time.months.count == 12)
    }

    @Test(arguments: TextsTests.languages)
    func everyLanguage_usesOnlyKnownPlaceholders(code: String) throws {
        for (path, value) in strings(try Texts.load(code, from: Repo.localization)) {
            for match in value.matches(of: #/\{(\w+)\}/#) {
                #expect(Self.knownPlaceholders.contains(String(match.1)), "\(code): \(path) uses unknown {\(match.1)}")
            }
        }
    }

    @Test(arguments: [(["pl-PL"], "pl"), (["pl"], "pl"), (["en-US"], "en"), (["de-DE", "pl-PL"], "en"), ([], "en")] as [([String], String)])
    func languageCode_followsTheFirstPreferredLanguage(preferred: [String], expected: String) {
        #expect(Texts.languageCode(preferred: preferred, available: ["en", "pl"]) == expected)
    }

    @Test func fill_replacesNamedPlaceholders() {
        #expect(Texts.fill("Resets {countdown} · {moment}", ("countdown", "in 2h"), ("moment", "today 18:00")) == "Resets in 2h · today 18:00")
    }

    /// Every string in the decoded texts with its path; Mirror walks the nested structs.
    func strings(_ node: Any, path: String = "") -> [(String, String)] {
        Mirror(reflecting: node).children.flatMap { child -> [(String, String)] in
            let name = path + (child.label ?? "?")
            switch child.value {
            case let text as String: return [(name, text)]
            case let list as [String]: return list.enumerated().map { ("\(name)[\($0.offset)]", $0.element) }
            default: return strings(child.value, path: name + ".")
            }
        }
    }
}
