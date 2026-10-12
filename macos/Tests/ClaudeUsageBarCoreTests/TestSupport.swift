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

import os

/// Answers every process call with `respond` and remembers the requests.
final class RecordingRunner: ProcessRunner, Sendable {
    private let recorded = OSAllocatedUnfairLock<[ProcessRequest]>(initialState: [])
    private let respond: @Sendable (ProcessRequest) -> ProcessResult

    init(_ respond: @escaping @Sendable (ProcessRequest) -> ProcessResult) { self.respond = respond }

    var requests: [ProcessRequest] { recorded.withLock { $0 } }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        recorded.withLock { $0.append(request) }
        return respond(request)
    }
}

/// An in-memory Keychain behind a fake /usr/bin/security: understands exactly the commands SecurityCLI sends.
final class FakeSecurity: ProcessRunner, Sendable {
    private struct State: Sendable {
        var items: [String: Data] = [:]
        var locked = false
        var commands: [[String]] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var isLocked: Bool {
        get { state.withLock { $0.locked } }
        set { state.withLock { $0.locked = newValue } }
    }

    subscript(service: String, account: String) -> Data? {
        get { state.withLock { $0.items["\(service)|\(account)"] } }
        set { state.withLock { $0.items["\(service)|\(account)"] = newValue } }
    }

    /// Services that currently have an item, sorted.
    var services: [String] { state.withLock { $0.items.keys.map { String($0.split(separator: "|")[0]) }.sorted() } }
    var commands: [[String]] { state.withLock { $0.commands } }

    func run(_ request: ProcessRequest) async throws -> ProcessResult {
        precondition(request.executable == SecurityCLI.tool, "only security is faked")
        let args = request.arguments == ["-i"] ? Self.words(String(decoding: request.stdin ?? Data(), as: UTF8.self)) : request.arguments
        return state.withLock { s in
            s.commands.append(args)
            if s.locked { return ProcessResult(exitCode: 36) }
            let key = "\(Self.value(after: "-s", in: args) ?? "")|\(Self.value(after: "-a", in: args) ?? "")"
            switch args.first {
            case "find-generic-password":
                guard let data = s.items[key] else { return ProcessResult(exitCode: 44) }
                return ProcessResult(exitCode: 0, stdout: data + Data("\n".utf8))
            case "add-generic-password":
                guard let hex = Self.value(after: "-X", in: args), let data = Data(hex: hex) else { return ProcessResult(exitCode: 1) }
                s.items[key] = data
                return ProcessResult(exitCode: 0)
            case "delete-generic-password":
                return ProcessResult(exitCode: s.items.removeValue(forKey: key) == nil ? 44 : 0)
            default:
                return ProcessResult(exitCode: 1)
            }
        }
    }

    /// Splits one `security -i` command line; double quotes group words.
    static func words(_ line: String) -> [String] {
        var words: [String] = [], current = "", quoted = false, inWord = false
        for character in line {
            if character == "\"" {
                quoted.toggle()
                inWord = true
            } else if (character == " " || character == "\n") && !quoted {
                if inWord { words.append(current); current = ""; inWord = false }
            } else {
                current.append(character)
                inWord = true
            }
        }
        if inWord { words.append(current) }
        return words
    }

    static func value(after flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}
