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

final class FakeTime: TimeSource, Sendable {
    private let current: OSAllocatedUnfairLock<Date>
    init(_ date: Date) { current = OSAllocatedUnfairLock(initialState: date) }
    func now() -> Date { current.withLock { $0 } }
    func set(_ date: Date) { current.withLock { $0 = date } }
    func advance(_ seconds: TimeInterval) { current.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

/// A fresh directory under the temporary folder, deleted when the test's suite instance goes away.
final class TempDir: Sendable {
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory.appending(path: "cub-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    subscript(_ relative: String) -> URL { root.appending(path: relative) }
}

@MainActor final class FakeCredentials: CredentialSource {
    var current: Credentials?
    var error: (any Error)?
    func read() async throws -> Credentials? {
        if let error { throw error }
        return current
    }
}

@MainActor final class FakeRenewer: TokenRenewing {
    var calls = 0
    var resets = 0
    var onRenew: () -> Bool = { false }
    func tryRenew() async -> Bool { calls += 1; return onRenew() }
    func reset() { resets += 1 }
}

@MainActor final class FakeAPI: UsageAPI {
    var tokens: [String] = []
    var respond: (String) -> UsageAPIResult = { _ in .ok(Fixtures.usage) }
    /// When set, wins over `respond`: lets a test hold a fetch open.
    var respondAsync: ((String) async -> UsageAPIResult)?

    func fetch(accessToken: String) async -> UsageAPIResult {
        tokens.append(accessToken)
        if let respondAsync { return await respondAsync(accessToken) }
        return respond(accessToken)
    }
}

/// A value a test hands over later, to hold an async call open.
@MainActor final class Pending<T: Sendable> {
    private var value: T?
    private var waiter: CheckedContinuation<T, Never>?

    func wait() async -> T {
        if let value { return value }
        return await withCheckedContinuation { waiter = $0 }
    }

    func resolve(_ result: T) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: result)
        } else {
            value = result
        }
    }
}

/// Logins shaped like Claude Code 2.1's Keychain item and ~/.claude.json; every token is fake.
enum Logins {
    static let defaultRefreshExpiry = iso("2026-11-01T00:00:00Z")

    static func make(_ id: String, _ email: String, token: String = "1", org: String = "org-1", orgName: String? = nil,
                     tier: String = "default_claude_max_5x", refreshExpires: Date? = nil,
                     extraSecure: [String: JSONValue] = [:]) -> AccountLogin {
        var secure: [String: JSONValue] = [
            "claudeAiOauth": .object([
                "accessToken": .string("access-\(id)-\(token)"),
                "refreshToken": .string("refresh-\(id)-\(token)"),
                "expiresAt": .int(1790271138070),
                "refreshTokenExpiresAt": .int(Int64((refreshExpires ?? defaultRefreshExpiry).timeIntervalSince1970 * 1000)),
                "scopes": .array([.string("user:inference"), .string("user:profile")]),
                "subscriptionType": .string("max"),
                "rateLimitTier": .string(tier),
            ]),
            "organizationUuid": .string(org),
        ]
        secure.merge(extraSecure) { _, extra in extra }
        return AccountLogin(secure: secure, account: [
            "accountUuid": .string("acc-\(id)"),
            "emailAddress": .string(email),
            "organizationUuid": .string(org),
            "organizationName": .string(orgName ?? "\(email)'s Organization"),
            "displayName": .string(id),
        ])
    }

    static func accessToken(_ login: AccountLogin?) -> String? { login?.secure["claudeAiOauth"]?["accessToken"]?.string }
}

extension Logins {
    /// Writes `login` the way Claude Code stores it, next to content that must survive a switch.
    static func writeCli(_ fake: FakeSecurity, service: String = KeychainNames.claudeService, account: String = "tester",
                         config: URL, _ login: AccountLogin) {
        var item = login.secure
        item["mcpOAuth"] = .object(["srv|abc": .object(["serverName": .string("srv"), "accessToken": .string("mcp-token")])])
        fake[service, account] = try! JSONValue.object(item).serialized(pretty: false)
        let oauthAccount = String(decoding: try! JSONValue.object(login.account).serialized(pretty: false), as: UTF8.self)
        try! FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! """
            {
              "numStartups": 5,
              "projects": { "/Users/łukasz/zażółć gęślą": { "allowedTools": [] } },
              "someFutureSetting": { "nested": [1, 2.50, "x"] },
              "cachedGrowthBookFeatures": { "flag": true },
              "oauthAccount": \(oauthAccount),
              "modelAccessCache": { "opus": true },
              "cachedUsageUtilization": 0.42
            }
            """.write(to: config, atomically: true, encoding: .utf8)
    }
}
