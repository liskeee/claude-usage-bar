# macOS Port and Monorepo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ClaudeUsageBar for macOS (menu bar readout, details popover, Claude Code account switching) in a monorepo next to the unchanged Windows app.

**Architecture:** The Windows app moves to `windows/`, and translations and the API fixture move to `shared/`. The macOS app is a Swift package in `macos/` with two targets. `ClaudeUsageBarCore` holds the logic: no AppKit, unit-tested, and a file-by-file port of `windows/src/ClaudeUsageBar/Core/`. `ClaudeUsageBar` is the AppKit/SwiftUI shell. Every Keychain access goes through `/usr/bin/security`, the way Claude Code does it, so the app is never asked for the keychain password. One GitHub workflow builds and releases both apps.

**Tech Stack:** Swift 6 (strict concurrency), Swift Package Manager, Swift Testing, AppKit (`NSStatusItem`, `NSMenu`, `NSPopover`), SwiftUI (popover content), CryptoKit (AES-GCM), ServiceManagement (`SMAppService`), Foundation `Process`. Windows: unchanged .NET 9 / WinForms. CI: GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-12-macos-port-design.md`

## Global Constraints

- `swift-tools-version: 6.0`, Swift 6 language mode, `platforms: [.macOS(.v14)]`, no third-party dependencies.
- Bundle id `io.github.liskeee.ClaudeUsageBar`; `LSUIElement` true; `LSMinimumSystemVersion` 14.0.
- Keychain only through `/usr/bin/security`. Never use Security.framework.
- Claude Code's item: service `Claude Code-credentials`. For `CLAUDE_CONFIG_DIR=<dir>` the service is `Claude Code-credentials-` plus the first 8 hex chars of sha256(NFC(`<dir>`)). The account is `$USER` if it matches `^[a-zA-Z0-9._-]+$`, else `claude-code-user`.
- `security` exit codes: 44 = item not found, 36 = keychain locked. Writes use `security -i` on stdin when the command is ≤ 4032 characters, argv above that.
- Account-scoped Keychain keys: `claudeAiOauth`, `organizationUuid`, `trustedDeviceToken`, `enterpriseGateway`, `designOauth`. Every other key (`mcpOAuth`, …) is never touched.
- Account caches removed from `~/.claude.json` on a switch: `subscriptionNoticeCount`, `hasAvailableSubscription`, `additionalModelOptionsCache`, `additionalModelOptionsAnsweredAt`, `additionalModelCostsCache`, `modelAccessCache`, `orgModelDefaultCache`, `cachedArtifactRoster`, `artifactRosterDenied`, `lastSeenOrgDefaultUpdatedAt`, `clientDataCache`, `clientDataCacheSlots`, `autoCompactWindowsCache`, `cachedUsageUtilization`.
- Usage endpoint `GET https://api.anthropic.com/api/oauth/usage`. Headers: `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: ClaudeUsageBar/<version> (macOS)`. Timeout 15 s.
- Timing:
  - poll every 5 min;
  - on HTTP 429 back off 10 → 20 → 30 min;
  - data is stale after 15 min;
  - refresh 15 s after a session reset;
  - token expiry skew 1 min;
  - renew at most once per 30 min, renew timeout 90 s.
- Severity: < 50 ok (green), 50–80 warn (amber), > 80 critical (red).
- Logs never contain tokens: only masked e-mails (`l***@gmail.com`) and uuid prefixes.
- Files:
  - `~/Library/Application Support/ClaudeUsageBar/` holds `accounts.dat`, `backup/`, `login-*`, `renew/` and `first-run`;
  - the log is `~/Library/Logs/ClaudeUsageBar/app.log`;
  - the Keychain item is `ClaudeUsageBar` / `accounts-key`.
- Windows: paths only. No C# code changes.
- Tests never touch the real Keychain, the real `~/.claude.json` or the network.
- Every commit message ends with a blank line and `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- All `swift` commands run in `macos/` (`cd macos` first).

## Review Focus

These five inputs and failure modes follow from the spec but are easy to miss. Each one has a test in the task that owns the code.

1. **Started at login with a minimal PATH** (`/usr/bin:/bin:/usr/sbin:/sbin`): `claude` must still be found in `~/.local/bin`, or renewal and "Add account" silently break. Test: Task 6, `find_withMinimalPath_findsClaudeInLocalBin`.
2. **Keychain locked** (`security` exit 36, e.g. right after wake with "lock after sleep"): this is a transient error. The last data stays, and the state must not flip to "sign in" or trigger a renewal. Test: Task 7, `lockedKeychain_isATransientError_notASignIn`.
3. **`security -w` prints a secret as hex** when it isn't printable text: it must be decoded, not parsed as garbage. Writes of Claude Code's item must be compact JSON (no newlines), so `security` keeps printing them as text. Tests: Task 4, `read_hexOutput_isDecoded`; Task 10, `write_itemIsCompactJSON`.
4. **`~/.claude.json` rewritten by a running Claude Code session during a switch, or unparseable:** retry, keep the other writer's change, and finally fail with the Keychain item restored. Tests: Task 10, `write_configChangedOnce_retriesAndKeepsTheOtherChange` and `write_configAlwaysBusy_failsAndRestoresTheItem`.
5. **The add-account Terminal window is closed before the login finishes:** report a failure, then remove the temporary dir and the temporary Keychain item, even if the login already wrote one. Tests: Task 13, `run_windowClosed_returnsFalse`; Task 12, `addAccount_loginFailedOrClosed_changesNothing`.

## File Map

| Path | Responsibility |
|---|---|
| `windows/**` | The Windows app, moved unchanged (`git mv`). Only `.csproj` paths change. |
| `shared/localization/{en,pl}.json` | Translations for both apps. The `macos` block is Mac-only. |
| `shared/fixtures/usage-2026-10-01.json` | Real API response used by both test suites. |
| `macos/Package.swift` | Targets `ClaudeUsageBarCore`, `ClaudeUsageBar` and `ClaudeUsageBarCoreTests`. |
| `macos/Sources/ClaudeUsageBarCore/JSONValue.swift` | Lossless JSON value (int vs double, bool), parse and serialize. |
| `…/UsageSnapshot.swift`, `…/UsageParser.swift` | Usage model and API response parsing. |
| `…/Texts.swift`, `…/Format.swift` | Translations and number/time formatting. |
| `…/ProcessRunner.swift` | The single seam for external programs. |
| `…/SecurityCLI.swift`, `…/KeychainNames.swift` | `/usr/bin/security` wrapper and item names. |
| `…/TimeSource.swift`, `…/AppPaths.swift`, `…/Log.swift` | Clock, file locations, log file. |
| `…/CredentialStore.swift`, `…/UsageAPI.swift` | Active token from the Keychain, HTTP usage call. |
| `…/AsyncLock.swift`, `…/ClaudeCLI.swift`, `…/TokenRenewer.swift` | CLI lock, finding `claude`, `claude -p` renewal. |
| `…/UsageService.swift` | Refresh state machine. |
| `…/DisplayText.swift` | Popover, footer and accessibility wording. |
| `…/AccountLogin.swift`, `…/AccountLabels.swift` | Account model and menu labels. |
| `…/CliLogin.swift` | The only writer of Claude Code's login (Keychain item plus `~/.claude.json`). |
| `…/AccountStore.swift` | Encrypted `accounts.dat` and its key. |
| `…/AccountSwitcher.swift` | Sync, switch, add and remove accounts. |
| `…/LoginRunner.swift` | `claude auth login` in a Terminal window. |
| `macos/Sources/ClaudeUsageBar/*.swift` | `main.swift`, `AppDelegate.swift`, `AppController.swift`, `Theme.swift`, `Spark.swift`, `BarView.swift`, `StatusItemController.swift`, `MenuItems.swift`, `DetailsView.swift`, `LoginItem.swift`. |
| `macos/Resources/Info.plist` | Bundle template; `__VERSION__` is filled in by `package.sh`. |
| `macos/tools/package.sh` | Universal build, `.app` assembly, icon, ad-hoc signature, zip. |
| `macos/Tests/ClaudeUsageBarCoreTests/*.swift` | One test file per Core file, plus `TestSupport.swift`. |
| `.github/workflows/build.yml` | Jobs `version`, `build-windows`, `build-macos`, `release`. |
| `README.md`, `windows/README.md`, `macos/README.md` | Overview and per-platform docs. |

**Code block convention:** "Create `path`:" or "Replace `path` with:" is always followed by the complete file content.

---

### Task 1: Monorepo — move the Windows app, share translations and the fixture

**Files:**
- Move: `ClaudeUsageBar.sln`, `src/`, `tests/`, `tools/` → `windows/`
- Move: `windows/src/ClaudeUsageBar/Localization/{en,pl}.json` → `shared/localization/`
- Move: `windows/tests/ClaudeUsageBar.Tests/Fixtures/usage-2026-10-01.json` → `shared/fixtures/`
- Modify: `windows/src/ClaudeUsageBar/ClaudeUsageBar.csproj`, `windows/tests/ClaudeUsageBar.Tests/ClaudeUsageBar.Tests.csproj`, `.github/workflows/build.yml`, `.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: `shared/localization/*.json` (read by both apps), `shared/fixtures/usage-2026-10-01.json` (read by both test suites), the `windows/` folder (Task 17 rewrites the workflow around it).

The C# code doesn't change. .NET can't build WinForms on macOS, so the Windows build is verified by CI on the pull request (Task 18). Locally we check that every path the project files reference exists.

- [ ] **Step 1: Move the files with history**

```bash
mkdir -p windows shared/localization shared/fixtures
git mv ClaudeUsageBar.sln src tests tools windows/
git mv windows/src/ClaudeUsageBar/Localization/en.json windows/src/ClaudeUsageBar/Localization/pl.json shared/localization/
git mv windows/tests/ClaudeUsageBar.Tests/Fixtures/usage-2026-10-01.json shared/fixtures/
git status --short | head -20
```

Expected: `R` (rename) lines only, e.g. `R  src/ClaudeUsageBar/App.cs -> windows/src/ClaudeUsageBar/App.cs`.

- [ ] **Step 2: Point the app project at the shared translations**

In `windows/src/ClaudeUsageBar/ClaudeUsageBar.csproj` replace

```xml
    <!-- one file per language, named by its two-letter ISO code -->
    <EmbeddedResource Include="Localization\*.json" LogicalName="Localization.%(Filename).json" />
```

with

```xml
    <!-- one file per language, named by its two-letter ISO code; shared with the macOS app -->
    <EmbeddedResource Include="..\..\..\shared\localization\*.json" LogicalName="Localization.%(Filename).json" />
```

- [ ] **Step 3: Point the test project at the shared fixture**

In `windows/tests/ClaudeUsageBar.Tests/ClaudeUsageBar.Tests.csproj` replace

```xml
    <None Include="Fixtures\**" CopyToOutputDirectory="PreserveNewest" />
```

with

```xml
    <!-- shared with the macOS tests; copied to the same Fixtures\ output folder as before -->
    <None Include="..\..\..\shared\fixtures\**" LinkBase="Fixtures" CopyToOutputDirectory="PreserveNewest" />
```

- [ ] **Step 4: Keep the current workflow working from `windows/` until Task 17 replaces it**

In `.github/workflows/build.yml`, in the `build` job, add after `runs-on: windows-latest`:

```yaml
    defaults:
      run:
        working-directory: windows
```

and change the package step and the artifact paths:

```yaml
      - name: Package
        run: ./tools/package.ps1 -Version ${{ steps.version.outputs.version }} -Out ../dist
```

(`upload-artifact`'s `path: dist/*.zip` / `dist/SHA256SUMS.txt` is relative to the repository root, where `../dist` now lands, so it stays as it is.)

- [ ] **Step 5: Ignore Swift build output**

Append to `.gitignore`:

```
.build/
.swiftpm/
```

- [ ] **Step 6: Verify every referenced path exists**

```bash
ls windows/../shared/localization/en.json windows/../shared/localization/pl.json windows/../shared/fixtures/usage-2026-10-01.json
ls windows/src/ClaudeUsageBar/../../../shared/localization/*.json windows/tests/ClaudeUsageBar.Tests/../../../shared/fixtures/*.json
python3 -I -c "import json,sys; [json.load(open(p)) for p in sys.argv[1:]]; print('json ok')" shared/localization/en.json shared/localization/pl.json shared/fixtures/usage-2026-10-01.json
grep -n 'shared' windows/src/ClaudeUsageBar/ClaudeUsageBar.csproj windows/tests/ClaudeUsageBar.Tests/ClaudeUsageBar.Tests.csproj
```

Expected: all `ls` paths print, `json ok`, and one `shared` line per project file.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: move the Windows app to windows/, share translations and fixtures" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Swift package, lossless JSON, usage parser

**Files:**
- Create: `macos/Package.swift`
- Create: `macos/Sources/ClaudeUsageBarCore/JSONValue.swift`, `UsageSnapshot.swift`, `UsageParser.swift`
- Test: `macos/Tests/ClaudeUsageBarCoreTests/TestSupport.swift`, `JSONValueTests.swift`, `UsageParserTests.swift`

**Interfaces:**
- Consumes: `shared/fixtures/usage-2026-10-01.json` (Task 1).
- Produces:
  - `JSONValue` (`.null/.bool/.int(Int64)/.double/.string/.array/.object([String: JSONValue])`, `static parse(_ data: Data) throws -> JSONValue`, `serialized(pretty: Bool = true) throws -> Data`, `subscript(key: String) -> JSONValue?`, `.object`, `.string`, `.number: Double?`, `JSONValue.Unsupported`);
  - internal `Data(hex:)`;
  - `LimitKind`, `LimitInfo(_ kind:_ usedPercent:resetsAt:model:)`, `UsageSnapshot(limits:fetchedAt:)` with `.session` and `.weekly`;
  - `UsageParser.parse(_ json: String, fetchedAt: Date) throws -> UsageSnapshot`, `UsageParser.date(_ text: String) -> Date?`;
  - test helpers `Repo`, `Fixtures`, `iso(_:)`.

- [ ] **Step 1: Create the package**

Create `macos/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeUsageBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ClaudeUsageBarCore"),
        .testTarget(name: "ClaudeUsageBarCoreTests", dependencies: ["ClaudeUsageBarCore"]),
    ]
)
```

- [ ] **Step 2: Write the failing tests**

Create `macos/Tests/ClaudeUsageBarCoreTests/TestSupport.swift`:

```swift
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
```

Create `macos/Tests/ClaudeUsageBarCoreTests/JSONValueTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeUsageBarCore

struct JSONValueTests {
    @Test func roundTrip_keepsIntegersDoublesBooleansAndNonASCII() throws {
        let source = #"{"ms":1790271138070,"half":2.50,"flag":true,"one":1,"zero":0,"path":"/Users/łukasz/zażółć","list":[1,2.5,"x",null,false]}"#
        let value = try JSONValue.parse(Data(source.utf8))

        #expect(value["ms"] == .int(1790271138070))
        #expect(value["half"] == .double(2.5))
        #expect(value["flag"] == .bool(true))
        #expect(value["one"] == .int(1))
        #expect(value["zero"] == .int(0))
        #expect(value["path"]?.string == "/Users/łukasz/zażółć")
        #expect(try JSONValue.parse(try value.serialized()) == value)
        let text = String(decoding: try value.serialized(), as: UTF8.self)
        #expect(text.contains("1790271138070"))
        #expect(!text.contains("1790271138070.0"))
        #expect(text.contains("/Users/łukasz/zażółć")) // no \/ and no \u escapes
    }

    @Test func loneSurrogate_isRejected() {
        #expect(throws: (any Error).self) { try JSONValue.parse(Data(#"{"x":"a\ud83db"}"#.utf8)) }
    }

    @Test func serialized_sortsKeys_andCompactHasNoNewlines() throws {
        let value = try JSONValue.parse(Data(#"{"b":1,"a":{"d":2,"c":3}}"#.utf8))
        let pretty = String(decoding: try value.serialized(), as: UTF8.self)
        let compact = String(decoding: try value.serialized(pretty: false), as: UTF8.self)

        #expect(pretty.range(of: "\"a\"")!.lowerBound < pretty.range(of: "\"b\"")!.lowerBound)
        #expect(compact == #"{"a":{"c":3,"d":2},"b":1}"#)
    }

    @Test func numberAndAccessors() throws {
        let value = try JSONValue.parse(Data(#"{"i":3,"d":0.5,"s":"x","n":null}"#.utf8))
        #expect(value["i"]?.number == 3)
        #expect(value["d"]?.number == 0.5)
        #expect(value["s"]?.number == nil)
        #expect(value["n"] == .null)
        #expect(value["missing"] == nil)
        #expect(JSONValue.string("x")["anything"] == nil)
    }

    @Test func hex_decodesBytes() {
        #expect(Data(hex: "00ff10") == Data([0x00, 0xff, 0x10]))
        #expect(Data(hex: "zz") == nil)
    }
}
```

Create `macos/Tests/ClaudeUsageBarCoreTests/UsageParserTests.swift`:

```swift
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd macos && swift test`
Expected: build FAILS with `cannot find 'JSONValue' in scope` / `cannot find 'UsageParser' in scope`.

- [ ] **Step 4: Implement**

Create `macos/Sources/ClaudeUsageBarCore/JSONValue.swift`:

```swift
import Foundation

/// Any JSON value, kept whole so fields this app doesn't know are written back unchanged.
/// Integers stay integers (Claude Code stores millisecond timestamps); object key order is not kept.
public enum JSONValue: Encodable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public struct Unsupported: Error {}

    /// Throws for anything that isn't valid JSON, including a lone UTF-16 surrogate in a string.
    public static func parse(_ data: Data) throws -> JSONValue {
        try JSONValue(foundation: JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
    }

    init(foundation value: Any) throws {
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.int64Value)
            }
        case let text as String:
            self = .string(text)
        case let items as [Any]:
            self = .array(try items.map(JSONValue.init(foundation:)))
        case let members as [String: Any]:
            self = .object(try members.mapValues(JSONValue.init(foundation:)))
        default:
            throw Unsupported()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Sorted keys, so the same value always gives the same bytes. Compact (`pretty: false`) for Keychain items:
    /// `security -w` prints a secret containing a newline as hex.
    public func serialized(pretty: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public subscript(key: String) -> JSONValue? { object?[key] }

    public var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var number: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        default: return nil
        }
    }
}

extension Data {
    /// "00ff10" → [0x00, 0xff, 0x10]; nil for anything that isn't pairs of hex digits.
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
```

Create `macos/Sources/ClaudeUsageBarCore/UsageSnapshot.swift`:

```swift
import Foundation

public enum LimitKind: Sendable, Equatable { case session, weekly, weeklyScoped }

/// One usage limit exactly as claude.ai → Settings → Usage shows it (percent = used).
/// `model` is set for per-model weekly limits (e.g. "Fable"); the label is localized by the UI.
public struct LimitInfo: Sendable, Equatable {
    public var kind: LimitKind
    public var usedPercent: Double
    public var resetsAt: Date?
    public var model: String?

    public init(_ kind: LimitKind, _ usedPercent: Double, resetsAt: Date?, model: String? = nil) {
        self.kind = kind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.model = model
    }
}

public struct UsageSnapshot: Sendable, Equatable {
    public var limits: [LimitInfo]
    public var fetchedAt: Date

    public init(limits: [LimitInfo], fetchedAt: Date) {
        self.limits = limits
        self.fetchedAt = fetchedAt
    }

    public var session: LimitInfo? { limits.first { $0.kind == .session } }
    public var weekly: LimitInfo? { limits.first { $0.kind == .weekly } }
}
```

Create `macos/Sources/ClaudeUsageBarCore/UsageParser.swift`:

```swift
import Foundation

/// Maps the /api/oauth/usage response to a snapshot; prefers `limits[]`, falls back to `five_hour` / `seven_day`.
public enum UsageParser {
    public static func parse(_ json: String, fetchedAt: Date) throws -> UsageSnapshot {
        let root = try JSONValue.parse(Data(json.utf8))
        guard root.object != nil else { throw JSONValue.Unsupported() }
        var limits: [LimitInfo] = []
        if case .array(let items)? = root["limits"] {
            limits = items.compactMap(fromLimitsItem)
        }
        if limits.isEmpty {
            addLegacy(root["five_hour"], .session, to: &limits)
            addLegacy(root["seven_day"], .weekly, to: &limits)
        }
        return UsageSnapshot(limits: limits, fetchedAt: fetchedAt)
    }

    static func fromLimitsItem(_ item: JSONValue) -> LimitInfo? {
        guard let percent = item["percent"]?.number else { return nil }
        let resets = item["resets_at"]?.string.flatMap(date)
        switch item["kind"]?.string {
        case "session": return LimitInfo(.session, percent, resetsAt: resets)
        case "weekly_all": return LimitInfo(.weekly, percent, resetsAt: resets)
        case "weekly_scoped":
            return LimitInfo(.weeklyScoped, percent, resetsAt: resets, model: item["scope"]?["model"]?["display_name"]?.string)
        default: return nil
        }
    }

    static func addLegacy(_ value: JSONValue?, _ kind: LimitKind, to limits: inout [LimitInfo]) {
        guard let value, let used = value["utilization"]?.number else { return }
        limits.append(LimitInfo(kind, used, resetsAt: value["resets_at"]?.string.flatMap(date)))
    }

    /// "2026-10-01T18:00:00.345899+02:00": whole seconds go through ISO8601DateFormatter and the fraction
    /// (any number of digits) is added on top.
    public static func date(_ text: String) -> Date? {
        var whole = text
        var fraction = 0.0
        if let dot = whole.firstIndex(of: "."),
           let end = whole[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            fraction = Double("0" + whole[dot..<end]) ?? 0
            whole.removeSubrange(dot..<end)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: whole)?.addingTimeInterval(fraction)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd macos && swift test`
Expected: PASS. All `JSONValueTests` and `UsageParserTests` pass.

- [ ] **Step 6: Commit**

```bash
git add macos/Package.swift macos/Sources macos/Tests
git commit -m "feat(macos): Swift package, lossless JSON value, usage parser" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Translations and formatting

**Files:**
- Modify: `shared/localization/en.json`, `shared/localization/pl.json` (add the `macos` block)
- Create: `macos/Sources/ClaudeUsageBarCore/Texts.swift`, `Format.swift`
- Test: `macos/Tests/ClaudeUsageBarCoreTests/TextsTests.swift`, `FormatTests.swift`; modify `TestSupport.swift`

**Interfaces:**
- Consumes: `LimitInfo`, `UsageParser.date` (Task 2).
- Produces:
  - `Texts` (fields `limits`, `bar`, `time`, `popup`, `menu.refreshNow`, `accounts`, `macos.menu.{startAtLogin, quit}`, `macos.accounts.claudeNotFound`, `macos.dialogs.{remove, cancel, ok}`; `static available(in:)`, `static load(_:from:) throws`, `static languageCode(preferred:available:)`, `static fill(_:_:...)`);
  - `Severity`;
  - `Format.severity/percent/countdownShort/countdownLong/ago/resetMoment(_:now:_:calendar:)/limitLabel/planName(subscriptionType:rateLimitTier:)/maskEmail`;
  - test helpers `Lang`, `Warsaw`.

- [ ] **Step 1: Add the Mac-only texts**

In `shared/localization/en.json` replace the last lines

```json
  "autostartDescription": "Claude usage limits in the taskbar"
}
```

with

```json
  "autostartDescription": "Claude usage limits in the taskbar",
  "macos": {
    "menu": { "startAtLogin": "Start at login", "quit": "Quit ClaudeUsageBar" },
    "accounts": { "claudeNotFound": "Claude Code (claude) was not found. Install it and try again." },
    "dialogs": { "remove": "Remove", "cancel": "Cancel", "ok": "OK" }
  }
}
```

In `shared/localization/pl.json` replace

```json
  "autostartDescription": "Limity Claude na pasku zadań"
}
```

with

```json
  "autostartDescription": "Limity Claude na pasku zadań",
  "macos": {
    "menu": { "startAtLogin": "Uruchamiaj przy logowaniu", "quit": "Zakończ ClaudeUsageBar" },
    "accounts": { "claudeNotFound": "Nie znaleziono Claude Code (claude). Zainstaluj go i spróbuj ponownie." },
    "dialogs": { "remove": "Usuń", "cancel": "Anuluj", "ok": "OK" }
  }
}
```

The Windows `Texts` ignores the `macos` member (System.Text.Json skips unknown members) and `TextsTests` there walks the deserialized object, so Windows is unaffected.

- [ ] **Step 2: Write the failing tests**

Append to `macos/Tests/ClaudeUsageBarCoreTests/TestSupport.swift`:

```swift

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
```

Create `macos/Tests/ClaudeUsageBarCoreTests/TextsTests.swift`:

```swift
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
```

Create `macos/Tests/ClaudeUsageBarCoreTests/FormatTests.swift`:

```swift
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
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd macos && swift test`
Expected: build FAILS with `cannot find 'Texts' in scope` / `cannot find 'Format' in scope`.

- [ ] **Step 4: Implement**

Create `macos/Sources/ClaudeUsageBarCore/Texts.swift`:

```swift
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
```

Create `macos/Sources/ClaudeUsageBarCore/Format.swift`:

```swift
import Foundation

public enum Severity: Sendable { case ok, warn, critical }

/// Text and number formatting shared by the menu bar readout and the popover; wording comes from Texts.
public enum Format {
    // green < 50, amber 50–80, red > 80
    public static func severity(_ used: Double) -> Severity {
        used < 50 ? .ok : used <= 80 ? .warn : .critical
    }

    public static func percent(_ used: Double) -> String {
        "\(Int(used.rounded(.toNearestOrAwayFromZero)))%"
    }

    /// Menu bar countdown, e.g. "52m", "3h 49m", "6d 17h".
    public static func countdownShort(_ t: TimeInterval, _ texts: Texts) -> String {
        let time = texts.time
        if t < 60 { return time.lessThanMinute }
        if t < 3600 { return Texts.fill(time.minutes, ("m", "\(Int(t / 60))")) }
        if t < 86400 {
            return Texts.fill(time.hoursMinutes, ("h", "\(Int(t / 3600))"), ("m", "\(Int(t.truncatingRemainder(dividingBy: 3600) / 60))"))
        }
        return Texts.fill(time.daysHours, ("d", "\(Int(t / 86400))"), ("h", "\(Int(t.truncatingRemainder(dividingBy: 86400) / 3600))"))
    }

    /// Popover countdown, e.g. "in 3h 49m".
    public static func countdownLong(_ t: TimeInterval, _ texts: Texts) -> String {
        t < 60 ? texts.time.inAMoment : Texts.fill(texts.time.in, ("duration", countdownShort(t, texts)))
    }

    /// Age of the data, e.g. "just now", "2m ago".
    public static func ago(_ t: TimeInterval, _ texts: Texts) -> String {
        t < 60 ? texts.time.justNow : Texts.fill(texts.time.ago, ("duration", countdownShort(t, texts)))
    }

    /// e.g. "today 18:00", "tomorrow 08:00", "Thu 8 Oct, 08:00", in `calendar`'s time zone.
    public static func resetMoment(_ reset: Date, now: Date, _ texts: Texts, calendar: Calendar = .current) -> String {
        // the API reports e.g. 17:59:59.9 for an 18:00 reset
        let rounded = Date(timeIntervalSinceReferenceDate: (reset.timeIntervalSinceReferenceDate / 60).rounded() * 60)
        let parts = calendar.dateComponents([.hour, .minute, .day, .month, .weekday], from: rounded)
        let clock = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        let time = texts.time
        if calendar.isDate(rounded, inSameDayAs: now) { return Texts.fill(time.today, ("time", clock)) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(rounded, inSameDayAs: tomorrow) {
            return Texts.fill(time.tomorrow, ("time", clock))
        }
        let weekday = parts.weekday ?? 1, month = parts.month ?? 1
        return Texts.fill(time.otherDay,
            ("weekday", time.weekdays[weekday - 1]), ("day", "\(parts.day ?? 1)"),
            ("month", time.months[month - 1]), ("monthNumber", "\(month)"), ("time", clock))
    }

    public static func limitLabel(_ limit: LimitInfo, _ texts: Texts) -> String {
        switch limit.kind {
        case .session: texts.limits.session
        case .weekly: texts.limits.weekly
        case .weeklyScoped: Texts.fill(texts.limits.scoped, ("model", limit.model ?? texts.limits.unknownModel))
        }
    }

    /// "default_claude_max_20x" → "Max 20x"; otherwise the capitalised subscription type.
    public static func planName(subscriptionType: String?, rateLimitTier: String?) -> String {
        if let tier = rateLimitTier, let match = tier.firstMatch(of: #/max_(\d+)x/#) { return "Max \(match.1)x" }
        guard let type = subscriptionType, !type.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        return type.prefix(1).uppercased() + type.dropFirst()
    }

    /// "lukasz@gmail.com" → "l***@gmail.com": enough to tell accounts apart in the log.
    public static func maskEmail(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@"), at > email.startIndex, let first = email.first else { return "***" }
        return "\(first)***\(email[at...])"
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd macos && swift test`
Expected: PASS. `TextsTests` and `FormatTests` pass, along with the earlier suites.

- [ ] **Step 6: Commit**

```bash
git add shared/localization macos/Sources macos/Tests
git commit -m "feat(macos): translations from shared/, number and time formatting" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 4: Process runner, `security` wrapper, Keychain names

**Files:**
- Create: `macos/Sources/ClaudeUsageBarCore/ProcessRunner.swift`, `SecurityCLI.swift`, `KeychainNames.swift`
- Test: `macos/Tests/ClaudeUsageBarCoreTests/ProcessRunnerTests.swift`, `SecurityCLITests.swift`, `KeychainNamesTests.swift`; modify `TestSupport.swift` (adds `RecordingRunner`, `FakeSecurity`)

**Interfaces:**
- Consumes: `Data(hex:)`, `Data.hexString` (Task 2).
- Produces:
  - `ProcessRequest(executable:arguments:stdin:environment:workingDirectory:timeout:captureOutput:)` and `ProcessResult(exitCode:stdout:stderr:timedOut:)`;
  - `protocol ProcessRunner: Sendable { func run(_:) async throws -> ProcessResult }` and `SystemProcessRunner()`;
  - `KeychainError.locked/.failed(Int32)`;
  - `SecurityCLI(runner:)` with `read(service:account:) async throws -> Data?`, `write(service:account:data:) async throws`, `delete(service:account:) async throws`, plus `SecurityCLI.tool` and `SecurityCLI.stdinLimit`;
  - `KeychainNames.claudeService`, `.claudeService(configDir:)`, `.appService`, `.accountsKeyAccount`, `.account(user:)`, `.currentUser`;
  - test fakes `RecordingRunner` and `FakeSecurity` (an in-memory Keychain behind fake `security` commands).

- [ ] **Step 1: Write the failing tests**

Append to `macos/Tests/ClaudeUsageBarCoreTests/TestSupport.swift`:

```swift

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
```

Create `macos/Tests/ClaudeUsageBarCoreTests/ProcessRunnerTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeUsageBarCore

struct ProcessRunnerTests {
    let runner = SystemProcessRunner()

    @Test func run_capturesOutputAndExitCode() async throws {
        let result = try await runner.run(ProcessRequest(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo out; echo err >&2; exit 3"]))
        #expect(result.exitCode == 3)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "out\n")
        #expect(String(decoding: result.stderr, as: UTF8.self) == "err\n")
        #expect(!result.timedOut)
    }

    @Test func run_passesStdinEnvironmentAndDirectory() async throws {
        let request = ProcessRequest(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "cat; echo \" $X\"; pwd"],
            stdin: Data("hello".utf8), environment: ["X": "42", "PATH": "/usr/bin:/bin"], workingDirectory: URL(fileURLWithPath: "/private/tmp"))
        let result = try await runner.run(request)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "hello 42\n/private/tmp\n")
    }

    @Test func run_timeout_terminatesTheProgram() async throws {
        let started = Date()
        let result = try await runner.run(ProcessRequest(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.3))
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func run_withoutCapture_returnsEmptyOutput() async throws {
        let result = try await runner.run(ProcessRequest(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["x"], captureOutput: false))
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
    }
}
```

Create `macos/Tests/ClaudeUsageBarCoreTests/SecurityCLITests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeUsageBarCore

struct SecurityCLITests {
    @Test func read_asksForThePasswordOfServiceAndAccount() async throws {
        let runner = RecordingRunner { _ in ProcessResult(exitCode: 0, stdout: Data("{\"a\":1}\n".utf8)) }

        let data = try await SecurityCLI(runner: runner).read(service: "svc", account: "me")

        #expect(data == Data("{\"a\":1}".utf8))
        #expect(runner.requests.map(\.arguments) == [["find-generic-password", "-a", "me", "-w", "-s", "svc"]])
        #expect(runner.requests.first?.executable == URL(fileURLWithPath: "/usr/bin/security"))
    }

    @Test func read_hexOutput_isDecoded() async throws {
        let runner = RecordingRunner { _ in ProcessResult(exitCode: 0, stdout: Data("00ff10\n".utf8)) }
        #expect(try await SecurityCLI(runner: runner).read(service: "svc", account: "me") == Data([0x00, 0xff, 0x10]))
    }

    @Test func read_missingItem_isNil() async throws {
        let runner = RecordingRunner { _ in ProcessResult(exitCode: 44) }
        #expect(try await SecurityCLI(runner: runner).read(service: "svc", account: "me") == nil)
    }

    @Test(arguments: [(36, KeychainError.locked), (1, .failed(1))] as [(Int32, KeychainError)])
    func read_otherExitCodes_throw(code: Int32, expected: KeychainError) async {
        let runner = RecordingRunner { _ in ProcessResult(exitCode: code) }
        await #expect(throws: expected) { _ = try await SecurityCLI(runner: runner).read(service: "svc", account: "me") }
    }

    @Test func write_sendsTheCommandOnStdin() async throws {
        let runner = RecordingRunner { _ in ProcessResult(exitCode: 0) }

        try await SecurityCLI(runner: runner).write(service: "svc", account: "me", data: Data("{}".utf8))

        #expect(runner.requests.first?.arguments == ["-i"])
        #expect(runner.requests.first?.stdin == Data("add-generic-password -U -a \"me\" -s \"svc\" -X \"7b7d\"\n".utf8))
    }

    @Test func write_longCommand_goesThroughArguments() async throws {
        let runner = RecordingRunner { _ in ProcessResult(exitCode: 0) }
        let overhead = "add-generic-password -U -a \"me\" -s \"svc\" -X \"\"\n".utf8.count
        let fits = (SecurityCLI.stdinLimit - overhead) / 2

        try await SecurityCLI(runner: runner).write(service: "svc", account: "me", data: Data(repeating: 0x41, count: fits))
        try await SecurityCLI(runner: runner).write(service: "svc", account: "me", data: Data(repeating: 0x41, count: fits + 1))

        #expect(runner.requests[0].arguments == ["-i"])
        #expect(runner.requests[1].arguments.prefix(6) == ["add-generic-password", "-U", "-a", "me", "-s", "svc"])
        #expect(runner.requests[1].stdin == nil)
    }

    @Test func write_lockedKeychain_throws() async {
        let runner = RecordingRunner { _ in ProcessResult(exitCode: 36) }
        await #expect(throws: KeychainError.locked) { try await SecurityCLI(runner: runner).write(service: "s", account: "a", data: Data()) }
    }

    @Test func delete_missingItem_isFine_otherFailuresThrow() async throws {
        try await SecurityCLI(runner: RecordingRunner { _ in ProcessResult(exitCode: 44) }).delete(service: "s", account: "a")
        await #expect(throws: KeychainError.failed(1)) {
            try await SecurityCLI(runner: RecordingRunner { _ in ProcessResult(exitCode: 1) }).delete(service: "s", account: "a")
        }
    }

    @Test func fakeSecurity_understandsWhatSecurityCLISends() async throws {
        let fake = FakeSecurity()
        let keychain = SecurityCLI(runner: fake)
        let big = Data(repeating: 0x42, count: 5000)

        try await keychain.write(service: "Claude Code-credentials", account: "me", data: Data("{\"x\":1}".utf8))
        try await keychain.write(service: "other", account: "me", data: big)

        #expect(try await keychain.read(service: "Claude Code-credentials", account: "me") == Data("{\"x\":1}".utf8))
        #expect(fake["other", "me"] == big)
        try await keychain.delete(service: "other", account: "me")
        #expect(fake.services == ["Claude Code-credentials"])
    }
}
```

Create `macos/Tests/ClaudeUsageBarCoreTests/KeychainNamesTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeUsageBarCore

struct KeychainNamesTests {
    @Test func defaultConfig_usesThePlainService() {
        #expect(KeychainNames.claudeService(configDir: nil) == "Claude Code-credentials")
    }

    // expected suffixes: printf '%s' <dir> | shasum -a 256 | cut -c1-8
    @Test func configDir_addsTheFirst8HexDigitsOfItsSha256() {
        #expect(KeychainNames.claudeService(configDir: "/tmp/cub-login") == "Claude Code-credentials-ea821fc5")
        #expect(KeychainNames.claudeService(configDir: "/Users/x/Library/Application Support/ClaudeUsageBar/login-abc")
            == "Claude Code-credentials-803d2c15")
    }

    @Test func configDir_isNFCNormalisedFirst() {
        let decomposed = "/tmp/zażółć".decomposedStringWithCanonicalMapping
        #expect(KeychainNames.claudeService(configDir: decomposed) == "Claude Code-credentials-34cc2634")
        #expect(KeychainNames.claudeService(configDir: "/tmp/zażółć") == "Claude Code-credentials-34cc2634")
    }

    @Test(arguments: [("lukaszlis", "lukaszlis"), ("a.b_c-d", "a.b_c-d"), ("jan kowalski", "claude-code-user"), ("", "claude-code-user")])
    func account_isTheUserOrClaudeCodesFallback(user: String, expected: String) {
        #expect(KeychainNames.account(user: user) == expected)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macos && swift test`
Expected: build FAILS with `cannot find type 'ProcessRunner' in scope`.

- [ ] **Step 3: Implement**

Create `macos/Sources/ClaudeUsageBarCore/ProcessRunner.swift`:

```swift
import Foundation
import os

public struct ProcessRequest: Sendable, Equatable {
    public var executable: URL
    public var arguments: [String]
    public var stdin: Data?
    /// nil: inherit the app's environment.
    public var environment: [String: String]?
    public var workingDirectory: URL?
    public var timeout: TimeInterval
    /// false sends output to /dev/null: for programs whose children may keep a pipe open (claude).
    public var captureOutput: Bool

    public init(executable: URL, arguments: [String], stdin: Data? = nil, environment: [String: String]? = nil,
                workingDirectory: URL? = nil, timeout: TimeInterval = 10, captureOutput: Bool = true) {
        self.executable = executable
        self.arguments = arguments
        self.stdin = stdin
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.captureOutput = captureOutput
    }
}

public struct ProcessResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: Data = Data(), stderr: Data = Data(), timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// Every external program (security, claude, open) runs through this, so tests can replace it.
public protocol ProcessRunner: Sendable {
    func run(_ request: ProcessRequest) async throws -> ProcessResult
}

public struct SystemProcessRunner: ProcessRunner {
    public init() {}

    public func run(_ request: ProcessRequest) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result(catching: { try Self.runBlocking(request) }))
            }
        }
    }

    static func runBlocking(_ request: ProcessRequest) throws -> ProcessResult {
        let process = Process()
        process.executableURL = request.executable
        process.arguments = request.arguments
        if let environment = request.environment { process.environment = environment }
        if let directory = request.workingDirectory { process.currentDirectoryURL = directory }
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = request.captureOutput ? output : FileHandle.nullDevice
        process.standardError = request.captureOutput ? errors : FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()

        // read both pipes while the program runs: a full pipe would block it
        let collected = OSAllocatedUnfairLock(initialState: (out: Data(), err: Data()))
        let readers = DispatchGroup()
        if request.captureOutput {
            for (handle, isOutput) in [(output.fileHandleForReading, true), (errors.fileHandleForReading, false)] {
                readers.enter()
                DispatchQueue.global(qos: .utility).async {
                    let data = handle.readDataToEndOfFile()
                    collected.withLock { if isOutput { $0.out = data } else { $0.err = data } }
                    readers.leave()
                }
            }
        }
        if let stdin = request.stdin { try? input.fileHandleForWriting.write(contentsOf: stdin) }
        try? input.fileHandleForWriting.close()

        let timedOut = finished.wait(timeout: .now() + request.timeout) == .timedOut
        if timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                finished.wait()
            }
        }
        readers.wait()
        let (out, err) = collected.withLock { ($0.out, $0.err) }
        return ProcessResult(exitCode: process.terminationStatus, stdout: out, stderr: err, timedOut: timedOut)
    }
}
```

Create `macos/Sources/ClaudeUsageBarCore/SecurityCLI.swift`:

```swift
import Foundation

public enum KeychainError: Error, Equatable {
    case locked
    case failed(Int32)
}

/// The only code that touches the Keychain, always through /usr/bin/security, the way Claude Code does: items it
/// creates trust that tool, so nobody is asked for the keychain password, whatever this app's own signature is.
public struct SecurityCLI: Sendable {
    public static let tool = URL(fileURLWithPath: "/usr/bin/security")
    /// `security -i` reads one command line; Claude Code passes longer commands as arguments.
    public static let stdinLimit = 4032
    static let notFound: Int32 = 44
    static let lockedKeychain: Int32 = 36

    let runner: any ProcessRunner

    public init(runner: any ProcessRunner) { self.runner = runner }

    /// nil when there is no such item.
    public func read(service: String, account: String) async throws -> Data? {
        let result = try await runner.run(ProcessRequest(executable: Self.tool, arguments: ["find-generic-password", "-a", account, "-w", "-s", service]))
        switch result.exitCode {
        case 0: return Self.password(fromOutput: result.stdout)
        case Self.notFound: return nil
        default: throw Self.error(result.exitCode)
        }
    }

    /// Creates or replaces the item. The secret goes in on stdin so it never shows in `ps`, unless it is too long.
    public func write(service: String, account: String, data: Data) async throws {
        let hex = data.hexString
        let command = "add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\"\n"
        let request = command.utf8.count <= Self.stdinLimit
            ? ProcessRequest(executable: Self.tool, arguments: ["-i"], stdin: Data(command.utf8))
            : ProcessRequest(executable: Self.tool, arguments: ["add-generic-password", "-U", "-a", account, "-s", service, "-X", hex])
        let result = try await runner.run(request)
        if result.exitCode != 0 { throw Self.error(result.exitCode) }
    }

    /// Deleting an item that isn't there is fine.
    public func delete(service: String, account: String) async throws {
        let result = try await runner.run(ProcessRequest(executable: Self.tool, arguments: ["delete-generic-password", "-a", account, "-s", service]))
        if result.exitCode != 0 && result.exitCode != Self.notFound { throw Self.error(result.exitCode) }
    }

    static func error(_ code: Int32) -> KeychainError { code == lockedKeychain ? .locked : .failed(code) }

    /// `security -w` prints the secret and a newline; a secret that isn't printable text comes out as hex.
    /// Our secrets are JSON (starts with "{") or base64 (has non-hex characters), so they are never mistaken for hex.
    static func password(fromOutput output: Data) -> Data {
        var text = String(decoding: output, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        if !text.isEmpty, text.allSatisfy(\.isHexDigit), let bytes = Data(hex: text) { return bytes }
        return Data(text.utf8)
    }
}
```

Create `macos/Sources/ClaudeUsageBarCore/KeychainNames.swift`:

```swift
import CryptoKit
import Foundation

public enum KeychainNames {
    /// Claude Code's login item for its default config dir.
    public static let claudeService = "Claude Code-credentials"
    /// This app's own item, holding the key that encrypts accounts.dat.
    public static let appService = "ClaudeUsageBar"
    public static let accountsKeyAccount = "accounts-key"

    /// With CLAUDE_CONFIG_DIR set, Claude Code appends the first 8 hex digits of sha256(the dir, NFC-normalised).
    public static func claudeService(configDir: String?) -> String {
        guard let configDir, !configDir.isEmpty else { return claudeService }
        let digest = SHA256.hash(data: Data(configDir.precomposedStringWithCanonicalMapping.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(claudeService)-\(hex.prefix(8))"
    }

    /// The Keychain account Claude Code uses: $USER when it is a plain name, otherwise its fallback.
    public static func account(user: String?) -> String {
        guard let user, user.wholeMatch(of: #/[a-zA-Z0-9._-]+/#) != nil else { return "claude-code-user" }
        return user
    }

    public static var currentUser: String {
        let user = ProcessInfo.processInfo.environment["USER"]
        return account(user: user?.isEmpty == false ? user : NSUserName())
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd macos && swift test`
Expected: PASS. `ProcessRunnerTests`, `SecurityCLITests` and `KeychainNamesTests` pass, along with the earlier suites.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources macos/Tests
git commit -m "feat(macos): process runner and Keychain access through /usr/bin/security" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Clock, paths, log, credentials, usage API

**Files:**
- Create: `macos/Sources/ClaudeUsageBarCore/TimeSource.swift`, `AppPaths.swift`, `Log.swift`, `CredentialStore.swift`, `UsageAPI.swift`
- Test: `macos/Tests/ClaudeUsageBarCoreTests/LogTests.swift`, `CredentialStoreTests.swift`, `UsageAPITests.swift`, `AppPathsTests.swift`; modify `TestSupport.swift` (adds `FakeTime`, `TempDir`)

**Interfaces:**
- Consumes: `JSONValue`, `SecurityCLI`, `KeychainError`, `KeychainNames`, `FakeSecurity` (Tasks 2 and 4).
- Produces:
  - `protocol TimeSource: Sendable { func now() -> Date }` and `SystemTime()`;
  - `AppPaths(home:)` with `.standard()`, `.home`, `.support`, `.logs`, `.accountsFile`, `.backupDir`, `.renewDir`, `.firstRunMarker`, `.claudeGlobalConfig`;
  - `Log.configure(directory:)` and `Log.write(_:)`;
  - `Credentials(accessToken:expiresAt:subscriptionType:rateLimitTier:)`;
  - `@MainActor protocol CredentialSource { func read() async throws -> Credentials? }` and `KeychainCredentialStore(keychain:service:account:)`;
  - `UsageAPIResult` (`.ok(String)`, `.unauthorized`, `.rateLimited`, `.failed(String)`, `.error: String?`);
  - `@MainActor protocol UsageAPI { func fetch(accessToken:) async -> UsageAPIResult }` and `HTTPUsageAPI(version:session:)`, with `static request(accessToken:version:)` and `static result(status:body:)`;
  - test helpers `FakeTime`, `TempDir`.

- [ ] **Step 1: Write the failing tests**

Append to `macos/Tests/ClaudeUsageBarCoreTests/TestSupport.swift`:

```swift

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
```

Create `macos/Tests/ClaudeUsageBarCoreTests/AppPathsTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeUsageBarCore

struct AppPathsTests {
    @Test func everythingLivesUnderTheUsersLibraryOrHome() {
        let paths = AppPaths(home: URL(fileURLWithPath: "/Users/jan"))
        #expect(paths.support.path == "/Users/jan/Library/Application Support/ClaudeUsageBar")
        #expect(paths.logs.path == "/Users/jan/Library/Logs/ClaudeUsageBar")
        #expect(paths.accountsFile.path == "/Users/jan/Library/Application Support/ClaudeUsageBar/accounts.dat")
        #expect(paths.backupDir.path == "/Users/jan/Library/Application Support/ClaudeUsageBar/backup")
        #expect(paths.renewDir.path == "/Users/jan/Library/Application Support/ClaudeUsageBar/renew")
        #expect(paths.firstRunMarker.path == "/Users/jan/Library/Application Support/ClaudeUsageBar/first-run")
        #expect(paths.claudeGlobalConfig.path == "/Users/jan/.claude.json")
    }
}
```

Create `macos/Tests/ClaudeUsageBarCoreTests/LogTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeUsageBarCore

// Log is process-wide: these tests don't run in parallel with each other
@Suite(.serialized) struct LogTests {
    let temp = TempDir()

    @Test func write_appendsTimestampedLines() throws {
        Log.configure(directory: temp["logs"])
        Log.write("first")
        Log.write("second")

        let text = try String(contentsOf: temp["logs/app.log"], encoding: .utf8)
        #expect(text.contains(" first\n"))
        #expect(text.contains(" second\n"))
    }

    @Test func configure_keepsOnlyTheLastMegabyte() throws {
        try FileManager.default.createDirectory(at: temp["logs"], withIntermediateDirectories: true)
        try Data(repeating: UInt8(ascii: "x"), count: 1_500_000).write(to: temp["logs/app.log"])

        Log.configure(directory: temp["logs"])

        let size = try FileManager.default.attributesOfItem(atPath: temp["logs/app.log"].path)[.size] as? Int
        #expect(size == 1_000_000)
    }
}
```

Create `macos/Tests/ClaudeUsageBarCoreTests/CredentialStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeUsageBarCore

@MainActor struct CredentialStoreTests {
    let fake = FakeSecurity()
    var store: KeychainCredentialStore { KeychainCredentialStore(keychain: SecurityCLI(runner: fake), account: "tester") }

    func item(_ json: String) { fake[KeychainNames.claudeService, "tester"] = Data(json.utf8) }

    @Test func read_takesTokenExpiryAndPlanFromClaudeAiOauth() async throws {
        item(#"{"claudeAiOauth":{"accessToken":"tok","expiresAt":1790271138070,"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"},"mcpOAuth":{}}"#)

        let creds = try await store.read()

        #expect(creds == Credentials(accessToken: "tok", expiresAt: Date(timeIntervalSince1970: 1790271138.070),
                                     subscriptionType: "max", rateLimitTier: "default_claude_max_20x"))
        #expect(!String(describing: creds!).contains("tok"))
    }

    @Test(arguments: [nil, "not json", #"{"mcpOAuth":{}}"#, #"{"claudeAiOauth":{"accessToken":""}}"#] as [String?])
    func read_withoutAUsableLogin_isNil(json: String?) async throws {
        if let json { item(json) }
        #expect(try await store.read() == nil)
    }

    @Test func read_missingExpiry_countsAsExpired() async throws {
        item(#"{"claudeAiOauth":{"accessToken":"tok"}}"#)
        #expect(try await store.read()?.expiresAt == .distantPast)
    }

    @Test func read_lockedKeychain_throws() async {
        fake.isLocked = true
        await #expect(throws: KeychainError.locked) { _ = try await store.read() }
    }
}
```

Create `macos/Tests/ClaudeUsageBarCoreTests/UsageAPITests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeUsageBarCore

struct UsageAPITests {
    @Test func request_isTheClaudeCodeUsageCall() {
        let request = HTTPUsageAPI.request(accessToken: "tok", version: "1.2.3")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "ClaudeUsageBar/1.2.3 (macOS)")
        #expect(request.timeoutInterval == 15)
    }

    @Test(arguments: [
        (200, UsageAPIResult.ok("{}")), (401, .unauthorized), (429, .rateLimited), (503, .failed("HTTP 503")), (0, .failed("HTTP 0")),
    ] as [(Int, UsageAPIResult)])
    func result_mapsTheStatus(status: Int, expected: UsageAPIResult) {
        #expect(HTTPUsageAPI.result(status: status, body: Data("{}".utf8)) == expected)
    }

    @Test func error_isWhatTheFooterShows() {
        #expect(UsageAPIResult.unauthorized.error == "HTTP 401")
        #expect(UsageAPIResult.rateLimited.error == "HTTP 429")
        #expect(UsageAPIResult.failed("offline").error == "offline")
        #expect(UsageAPIResult.ok("{}").error == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macos && swift test`
Expected: build FAILS with `cannot find type 'TimeSource' in scope`.

- [ ] **Step 3: Implement**

Create `macos/Sources/ClaudeUsageBarCore/TimeSource.swift`:

```swift
import Foundation

public protocol TimeSource: Sendable {
    func now() -> Date
}

public struct SystemTime: TimeSource {
    public init() {}
    public func now() -> Date { Date() }
}
```

Create `macos/Sources/ClaudeUsageBarCore/AppPaths.swift`:

```swift
import Foundation

/// Where the app keeps its files: Application Support (accounts, backup, login dirs), Logs.
public struct AppPaths: Sendable {
    public let home: URL
    public let support: URL
    public let logs: URL

    public init(home: URL) {
        self.home = home
        support = home.appending(path: "Library/Application Support/ClaudeUsageBar")
        logs = home.appending(path: "Library/Logs/ClaudeUsageBar")
    }

    public static func standard() -> AppPaths { AppPaths(home: FileManager.default.homeDirectoryForCurrentUser) }

    public var accountsFile: URL { support.appending(path: "accounts.dat") }
    public var backupDir: URL { support.appending(path: "backup") }
    public var renewDir: URL { support.appending(path: "renew") }
    public var firstRunMarker: URL { support.appending(path: "first-run") }
    /// Claude Code's global config for its default config dir.
    public var claudeGlobalConfig: URL { home.appending(path: ".claude.json") }
}
```

Create `macos/Sources/ClaudeUsageBarCore/Log.swift`:

```swift
import Foundation
import os

/// ~/Library/Logs/ClaudeUsageBar/app.log, one timestamped line per event.
/// Never tokens: only masked e-mails and uuid prefixes.
public enum Log {
    static let maxSize = 1_000_000
    private static let file = OSAllocatedUnfairLock<URL?>(initialState: nil)

    /// Starts logging into `directory`, keeping only the last 1 MB of earlier runs.
    public static func configure(directory: URL) {
        let url = directory.appending(path: "app.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: url), data.count > maxSize {
            try? data.suffix(maxSize).write(to: url, options: .atomic)
        }
        file.withLock { $0 = url }
    }

    public static func write(_ message: String) {
        let line = Data("\(Date().formatted(.iso8601)) \(message)\n".utf8)
        file.withLock { url in
            guard let url else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
                try? handle.close()
            } else {
                try? line.write(to: url)
            }
        }
    }
}
```

Create `macos/Sources/ClaudeUsageBarCore/CredentialStore.swift`:

```swift
import Foundation

public struct Credentials: Sendable, Equatable, CustomStringConvertible {
    public var accessToken: String
    public var expiresAt: Date
    public var subscriptionType: String?
    public var rateLimitTier: String?

    public init(accessToken: String, expiresAt: Date, subscriptionType: String?, rateLimitTier: String?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }

    // never let the token reach logs through string interpolation
    public var description: String { "Credentials(expiresAt: \(expiresAt), plan: \(rateLimitTier ?? subscriptionType ?? "-"))" }
}

@MainActor public protocol CredentialSource {
    /// nil when there is no claude.ai login; throws when the Keychain can't be read (e.g. locked).
    func read() async throws -> Credentials?
}

/// The active Claude Code login, from its Keychain item. Read-only: Claude Code owns the item.
public struct KeychainCredentialStore: CredentialSource {
    let keychain: SecurityCLI
    let service: String
    let account: String

    public init(keychain: SecurityCLI, service: String = KeychainNames.claudeService, account: String = KeychainNames.currentUser) {
        self.keychain = keychain
        self.service = service
        self.account = account
    }

    public func read() async throws -> Credentials? {
        guard let data = try await keychain.read(service: service, account: account),
              let oauth = (try? JSONValue.parse(data))?["claudeAiOauth"],
              let token = oauth["accessToken"]?.string, !token.isEmpty else { return nil }
        let expires = oauth["expiresAt"]?.number.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
        return Credentials(accessToken: token, expiresAt: expires,
                           subscriptionType: oauth["subscriptionType"]?.string, rateLimitTier: oauth["rateLimitTier"]?.string)
    }
}
```

Create `macos/Sources/ClaudeUsageBarCore/UsageAPI.swift`:

```swift
import Foundation

public enum UsageAPIResult: Sendable, Equatable {
    case ok(String)
    case unauthorized
    case rateLimited
    case failed(String)

    /// What the log and the popover footer say about a failure.
    public var error: String? {
        switch self {
        case .ok: nil
        case .unauthorized: "HTTP 401"
        case .rateLimited: "HTTP 429"
        case .failed(let message): message
        }
    }
}

@MainActor public protocol UsageAPI {
    func fetch(accessToken: String) async -> UsageAPIResult
}

/// The same endpoint Claude Code's /usage uses.
public struct HTTPUsageAPI: UsageAPI {
    nonisolated public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    let version: String
    let session: URLSession

    public init(version: String, session: URLSession = .shared) {
        self.version = version
        self.session = session
    }

    nonisolated public static func request(accessToken: String, version: String) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("ClaudeUsageBar/\(version) (macOS)", forHTTPHeaderField: "User-Agent")
        return request
    }

    nonisolated public static func result(status: Int, body: Data) -> UsageAPIResult {
        switch status {
        case 401: .unauthorized
        case 429: .rateLimited
        case 200..<300: .ok(String(decoding: body, as: UTF8.self))
        default: .failed("HTTP \(status)")
        }
    }

    public func fetch(accessToken: String) async -> UsageAPIResult {
        do {
            let (body, response) = try await session.data(for: Self.request(accessToken: accessToken, version: version))
            return Self.result(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd macos && swift test`
Expected: PASS. All suites so far pass.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources macos/Tests
git commit -m "feat(macos): log, paths, Keychain credentials and the usage API" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: CLI lock, finding `claude`, token renewal

**Files:**
- Create: `macos/Sources/ClaudeUsageBarCore/AsyncLock.swift`, `ClaudeCLI.swift`, `TokenRenewer.swift`
- Test: `macos/Tests/ClaudeUsageBarCoreTests/AsyncLockTests.swift`, `ClaudeCLITests.swift`, `TokenRenewerTests.swift`

**Interfaces:**
- Consumes: `TimeSource`, `ProcessRunner`, `ProcessRequest`, `Log` (Tasks 4 and 5).
- Produces:
  - `@MainActor final class AsyncLock` with `lock() async`, `unlock()` and `isLocked`;
  - `ClaudeCLI.searchDirectories(path:home:)`, `.find(path:home:isExecutable:)`, `.findDefault()`, `.cleanEnvironment(_:)`, `.childEnvironment(_:home:)`;
  - `@MainActor protocol TokenRenewing: AnyObject { func tryRenew() async -> Bool; func reset() }`;
  - `CliTokenRenewer(time:cliLock:runCli:)`, `CliTokenRenewer.standard(runner:workDir:cliLock:time:)`, plus the constants `minInterval`, `runTimeout` and `arguments`.

- [ ] **Step 1: Write the failing tests**

Create `macos/Tests/ClaudeUsageBarCoreTests/AsyncLockTests.swift`:

```swift
import Testing
@testable import ClaudeUsageBarCore

@MainActor struct AsyncLockTests {
    @MainActor final class Order { var values: [Int] = [] }

    @Test func waitersRunOneAtATime_inOrder() async {
        let lock = AsyncLock()
        let order = Order()
        await lock.lock()

        let first = Task { await lock.lock(); order.values.append(1); lock.unlock() }
        let second = Task { await lock.lock(); order.values.append(2); lock.unlock() }
        for _ in 0..<10 { await Task.yield() }
        #expect(order.values.isEmpty)

        lock.unlock()
        await first.value
        await second.value
        #expect(order.values == [1, 2])
        #expect(!lock.isLocked)
    }
}
```

Create `macos/Tests/ClaudeUsageBarCoreTests/ClaudeCLITests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeUsageBarCore

struct ClaudeCLITests {
    let home = URL(fileURLWithPath: "/Users/jan")

    @Test func find_withMinimalPath_findsClaudeInLocalBin() {
        // what an app started at login gets
        let found = ClaudeCLI.find(path: "/usr/bin:/bin:/usr/sbin:/sbin", home: home) { $0 == "/Users/jan/.local/bin/claude" }
        #expect(found?.path == "/Users/jan/.local/bin/claude")
    }

    @Test func find_prefersPath_thenTheInstallerLocations() {
        let everywhere = ClaudeCLI.find(path: "/custom/bin", home: home) { _ in true }
        #expect(everywhere?.path == "/custom/bin/claude")
        #expect(ClaudeCLI.searchDirectories(path: nil, home: home).map(\.path) == ["/Users/jan/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"])
        #expect(ClaudeCLI.find(path: nil, home: home) { _ in false } == nil)
    }

    @Test func cleanEnvironment_dropsClaudeAndAnthropicVariables() {
        let env = ["CLAUDE_CONFIG_DIR": "/x", "ClaudeCode_Thing": "1", "ANTHROPIC_API_KEY": "sk", "anthropic_base_url": "u", "HOME": "/Users/jan", "PATH": "/bin"]
        #expect(ClaudeCLI.cleanEnvironment(env) == ["HOME": "/Users/jan", "PATH": "/bin"])
    }

    @Test func childEnvironment_putsTheInstallerLocationsOnPath() {
        let env = ClaudeCLI.childEnvironment(["PATH": "/usr/bin:/bin", "ANTHROPIC_API_KEY": "sk"], home: home)
        #expect(env["PATH"] == "/usr/bin:/bin:/Users/jan/.local/bin:/opt/homebrew/bin:/usr/local/bin")
        #expect(env["ANTHROPIC_API_KEY"] == nil)
    }
}
```

Create `macos/Tests/ClaudeUsageBarCoreTests/TokenRenewerTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macos && swift test`
Expected: build FAILS with `cannot find 'AsyncLock' in scope`.

- [ ] **Step 3: Implement**

Create `macos/Sources/ClaudeUsageBarCore/AsyncLock.swift`:

```swift
/// A lock for async code on the main actor; waiters get it in order. Shared by the token renewer and the account
/// switcher, so a `claude -p` refresh never writes the old account's tokens over a switch.
@MainActor public final class AsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public var isLocked: Bool { locked }

    public func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Hands the lock straight to the next waiter, if any.
    public func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
```

Create `macos/Sources/ClaudeUsageBarCore/ClaudeCLI.swift`:

```swift
import Foundation

/// Finding and starting the Claude Code CLI.
public enum ClaudeCLI {
    /// PATH first, then where the installers put it: an app started at login gets a minimal PATH.
    public static func searchDirectories(path: String?, home: URL) -> [URL] {
        let fromPath = (path ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        let known = [home.appending(path: ".local/bin"), URL(fileURLWithPath: "/opt/homebrew/bin"), URL(fileURLWithPath: "/usr/local/bin")]
        var seen = Set<String>()
        return (fromPath + known).filter { seen.insert($0.path).inserted }
    }

    public static func find(path: String?, home: URL, isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)) -> URL? {
        searchDirectories(path: path, home: home).map { $0.appending(path: "claude") }.first { isExecutable($0.path) }
    }

    public static func findDefault() -> URL? {
        find(path: ProcessInfo.processInfo.environment["PATH"], home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Never pass on auth, config dir or proxy settings from a Claude session that happened to start us.
    public static func cleanEnvironment(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in
            let upper = key.uppercased()
            return !upper.hasPrefix("CLAUDE") && !upper.hasPrefix("ANTHROPIC")
        }
    }

    /// The environment for a `claude` child: cleaned, with the installer locations on PATH.
    public static func childEnvironment(_ environment: [String: String], home: URL) -> [String: String] {
        var env = cleanEnvironment(environment)
        env["PATH"] = searchDirectories(path: environment["PATH"], home: home).map(\.path).joined(separator: ":")
        return env
    }
}
```

Create `macos/Sources/ClaudeUsageBarCore/TokenRenewer.swift`:

```swift
import Foundation

@MainActor public protocol TokenRenewing: AnyObject {
    /// Asks the official CLI to refresh its login; false when throttled, missing or failed.
    func tryRenew() async -> Bool
    /// Forgets the last attempt: after an account switch the new login may renew right away.
    func reset()
}

/// Renews the Claude Code login with one tiny `claude -p` call: the CLI refreshes its own Keychain item.
@MainActor public final class CliTokenRenewer: TokenRenewing {
    nonisolated public static let minInterval: TimeInterval = 30 * 60
    nonisolated public static let runTimeout: TimeInterval = 90
    nonisolated public static let arguments = ["-p", "ok", "--model", "haiku", "--safe-mode", "--no-session-persistence"]

    let time: any TimeSource
    let cliLock: AsyncLock
    let runCli: @MainActor () async -> Bool
    private var lastAttempt: Date?

    public init(time: any TimeSource, cliLock: AsyncLock, runCli: @escaping @MainActor () async -> Bool) {
        self.time = time
        self.cliLock = cliLock
        self.runCli = runCli
    }

    public func tryRenew() async -> Bool {
        let now = time.now()
        if let last = lastAttempt, now.timeIntervalSince(last) < Self.minInterval { return false }
        lastAttempt = now
        await cliLock.lock()
        defer { cliLock.unlock() }
        return await runCli()
    }

    public func reset() { lastAttempt = nil }

    public static func standard(runner: any ProcessRunner, workDir: URL, cliLock: AsyncLock, time: any TimeSource = SystemTime()) -> CliTokenRenewer {
        CliTokenRenewer(time: time, cliLock: cliLock) {
            guard let claude = ClaudeCLI.findDefault() else {
                Log.write("renew: claude not found")
                return false
            }
            try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let request = ProcessRequest(
                executable: claude, arguments: arguments,
                environment: ClaudeCLI.childEnvironment(ProcessInfo.processInfo.environment, home: FileManager.default.homeDirectoryForCurrentUser),
                workingDirectory: workDir, timeout: runTimeout, captureOutput: false)
            guard let result = try? await runner.run(request) else {
                Log.write("renew: claude didn't start")
                return false
            }
            Log.write(result.timedOut ? "renew: claude timed out" : "renew: claude exited with \(result.exitCode)")
            return result.exitCode == 0 && !result.timedOut
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd macos && swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources macos/Tests
git commit -m "feat(macos): find claude with a login-time PATH and renew its token" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Usage service

**Files:**
- Create: `macos/Sources/ClaudeUsageBarCore/UsageService.swift`
- Test: `macos/Tests/ClaudeUsageBarCoreTests/UsageServiceTests.swift`; modify `TestSupport.swift` (adds `FakeCredentials`, `FakeRenewer`, `FakeAPI`, `Pending`)

**Interfaces:**
- Consumes: `CredentialSource`, `Credentials`, `UsageAPI`, `UsageAPIResult`, `TokenRenewing`, `TimeSource`, `AsyncLock`, `UsageParser`, `Format.planName`, `KeychainError`, `Log` (Tasks 2–6).
- Produces:
  - `ServiceStatus` (`.loading/.ok/.error/.needsLogin`);
  - `UsageState(status:snapshot:planName:lastSuccess:lastError:)` and `UsageState.initial`;
  - `@MainActor final class UsageService(credentials:api:renewer:time:)` with `state`, `onChange: ((UsageState) -> Void)?`, `refresh() async`, `reset()`, `nextDelay() -> TimeInterval`, and the nonisolated constants `pollInterval` and `staleAfter`.

- [ ] **Step 1: Write the failing tests**

Append to `macos/Tests/ClaudeUsageBarCoreTests/TestSupport.swift`:

```swift

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
```

Create `macos/Tests/ClaudeUsageBarCoreTests/UsageServiceTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macos && swift test`
Expected: build FAILS with `cannot find 'UsageService' in scope`.

- [ ] **Step 3: Implement**

Create `macos/Sources/ClaudeUsageBarCore/UsageService.swift`:

```swift
import Foundation

public enum ServiceStatus: Sendable, Equatable { case loading, ok, error, needsLogin }

/// Everything the UI draws; replaced as a whole on every refresh.
public struct UsageState: Sendable, Equatable {
    public var status: ServiceStatus
    public var snapshot: UsageSnapshot?
    public var planName: String
    public var lastSuccess: Date?
    public var lastError: String?

    public init(status: ServiceStatus, snapshot: UsageSnapshot?, planName: String, lastSuccess: Date?, lastError: String?) {
        self.status = status
        self.snapshot = snapshot
        self.planName = planName
        self.lastSuccess = lastSuccess
        self.lastError = lastError
    }

    public static let initial = UsageState(status: .loading, snapshot: nil, planName: "", lastSuccess: nil, lastError: nil)
}

/// Token → (renew) → fetch → state. Keeps the last good snapshot when a refresh fails.
@MainActor public final class UsageService {
    nonisolated public static let pollInterval: TimeInterval = 5 * 60
    nonisolated public static let staleAfter: TimeInterval = 15 * 60
    nonisolated static let expirySkew: TimeInterval = 60
    nonisolated static let afterReset: TimeInterval = 15
    nonisolated static let maxBackoff: TimeInterval = 30 * 60

    let credentials: any CredentialSource
    let api: any UsageAPI
    let renewer: any TokenRenewing
    let time: any TimeSource
    private let gate = AsyncLock()
    private var rateLimitStreak = 0 // consecutive HTTP 429 answers; the endpoint refills slowly once drained
    private var generation = 0 // bumped by reset(): a refresh that started earlier belongs to the previous account

    public private(set) var state = UsageState.initial
    public var onChange: ((UsageState) -> Void)?

    public init(credentials: any CredentialSource, api: any UsageAPI, renewer: any TokenRenewing, time: any TimeSource) {
        self.credentials = credentials
        self.api = api
        self.renewer = renewer
        self.time = time
    }

    public func refresh() async {
        await gate.lock()
        defer { gate.unlock() }
        let started = generation
        let next = await fetch()
        guard started == generation else {
            rateLimitStreak = 0 // whatever that refresh counted was about the account we left
            return
        }
        state = next
        let session = state.snapshot?.session.map { "\($0.usedPercent)" } ?? "-"
        let week = state.snapshot?.weekly.map { "\($0.usedPercent)" } ?? "-"
        Log.write("refresh: \(state.status) session=\(session) week=\(week) \(state.lastError ?? "")")
        onChange?(state)
    }

    /// After an account switch: back to loading with no data and no backoff, so the previous account's numbers
    /// never show under the new one.
    public func reset() {
        generation += 1
        rateLimitStreak = 0
        renewer.reset()
        state = .initial
        onChange?(state)
    }

    /// Next automatic refresh: the poll interval, or just after the session limit resets if that comes sooner;
    /// while rate limited, 10 → 20 → 30 min.
    public func nextDelay() -> TimeInterval {
        if rateLimitStreak > 0 {
            return min(Self.maxBackoff, Self.pollInterval * pow(2, Double(min(rateLimitStreak, 8))))
        }
        if let reset = state.snapshot?.session?.resetsAt {
            let untilReset = reset.timeIntervalSince(time.now())
            if untilReset > 0 && untilReset + Self.afterReset < Self.pollInterval { return untilReset + Self.afterReset }
        }
        return Self.pollInterval
    }

    private func fetch() async -> UsageState {
        var creds: Credentials?
        do {
            creds = try await credentials.read()
            if !isUsable(creds) {
                _ = await renewer.tryRenew()
                creds = try await credentials.read()
            }
        } catch {
            // e.g. a locked Keychain: transient, keep what is on screen
            return failed(error as? KeychainError == .locked ? "Keychain locked" : "Keychain read failed", plan: state.planName)
        }
        guard var current = creds, isUsable(current) else { return needsLogin(creds, "CLI login expired") }

        var result = await api.fetch(accessToken: current.accessToken)
        if result == .unauthorized {
            _ = await renewer.tryRenew()
            guard let renewed = try? await credentials.read(), isUsable(renewed) else { return needsLogin(current, "CLI login expired") }
            current = renewed
            result = await api.fetch(accessToken: current.accessToken)
            if result == .unauthorized { return needsLogin(current, result.error) }
        }

        let plan = Format.planName(subscriptionType: current.subscriptionType, rateLimitTier: current.rateLimitTier)
        switch result {
        case .ok(let json):
            guard let snapshot = try? UsageParser.parse(json, fetchedAt: time.now()) else {
                var next = state
                next.status = .error
                next.planName = plan
                next.lastError = "Unreadable API response"
                return next
            }
            rateLimitStreak = 0
            return UsageState(status: .ok, snapshot: snapshot, planName: plan, lastSuccess: snapshot.fetchedAt, lastError: nil)
        case .rateLimited:
            rateLimitStreak += 1
            return failed(result.error, plan: plan)
        default:
            return failed(result.error, plan: plan)
        }
    }

    /// A failed refresh only matters once the data already on screen gets old.
    private func failed(_ error: String?, plan: String) -> UsageState {
        let fresh = state.lastSuccess.map { time.now().timeIntervalSince($0) <= Self.staleAfter } ?? false
        var next = state
        next.status = fresh ? .ok : .error
        next.planName = plan
        next.lastError = error
        return next
    }

    private func needsLogin(_ creds: Credentials?, _ error: String?) -> UsageState {
        var next = state
        next.status = .needsLogin
        if let creds { next.planName = Format.planName(subscriptionType: creds.subscriptionType, rateLimitTier: creds.rateLimitTier) }
        next.lastError = error
        return next
    }

    private func isUsable(_ creds: Credentials?) -> Bool {
        guard let creds else { return false }
        return creds.expiresAt.addingTimeInterval(-Self.expirySkew) > time.now()
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd macos && swift test`
Expected: PASS. All 20 `UsageServiceTests` pass, along with the earlier suites.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources macos/Tests
git commit -m "feat(macos): usage service with renewal, backoff and stale data" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Popover, footer and accessibility wording

**Files:**
- Create: `macos/Sources/ClaudeUsageBarCore/DisplayText.swift`
- Test: `macos/Tests/ClaudeUsageBarCoreTests/DisplayTextTests.swift`

**Interfaces:**
- Consumes: `UsageState`, `UsageService.staleAfter`, `Format`, `Texts` (Tasks 3 and 7).
- Produces: `DisplayText.footer(_:now:_:)`, `.resetLine(_:now:_:calendar:)`, `.empty(_:_:)`, `.heading(_:)`, `.isStale(_:now:)`, `.accessibility(_:now:_:calendar:)`. All return `String` except `isStale`, which returns `Bool`.

- [ ] **Step 1: Write the failing tests**

Create `macos/Tests/ClaudeUsageBarCoreTests/DisplayTextTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macos && swift test`
Expected: build FAILS with `cannot find 'DisplayText' in scope`.

- [ ] **Step 3: Implement**

Create `macos/Sources/ClaudeUsageBarCore/DisplayText.swift`:

```swift
import Foundation

/// The words of the popover and the menu bar readout; the drawing lives in the app target.
public enum DisplayText {
    public static func footer(_ state: UsageState, now: Date, _ texts: Texts) -> String {
        switch (state.status, state.lastSuccess) {
        case (.ok, let last?): Texts.fill(texts.popup.updated, ("ago", Format.ago(now.timeIntervalSince(last), texts)))
        case (.error, let last?): Texts.fill(texts.popup.refreshFailed, ("ago", Format.ago(now.timeIntervalSince(last), texts)))
        case (.error, nil): texts.popup.loadFailed
        case (.needsLogin, _): texts.popup.signIn
        default: texts.popup.loading
        }
    }

    public static func resetLine(_ reset: Date, now: Date, _ texts: Texts, calendar: Calendar = .current) -> String {
        Texts.fill(texts.popup.resetLine,
            ("countdown", Format.countdownLong(reset.timeIntervalSince(now), texts)),
            ("moment", Format.resetMoment(reset, now: now, texts, calendar: calendar)))
    }

    /// Body text when there is no snapshot to show yet.
    public static func empty(_ state: UsageState, _ texts: Texts) -> String {
        switch state.status {
        case .needsLogin: texts.popup.emptyNeedsLogin
        case .error: texts.popup.emptyError
        default: texts.popup.emptyLoading
        }
    }

    /// "Claude Max 20x", or "Claude" before the plan is known.
    public static func heading(_ state: UsageState) -> String {
        state.planName.isEmpty ? "Claude" : "Claude \(state.planName)"
    }

    /// Data older than 15 minutes, or none yet, is drawn grey.
    public static func isStale(_ state: UsageState, now: Date) -> Bool {
        guard let last = state.lastSuccess else { return true }
        return now.timeIntervalSince(last) > UsageService.staleAfter
    }

    /// The VoiceOver label of the menu bar item.
    public static func accessibility(_ state: UsageState, now: Date, _ texts: Texts, calendar: Calendar = .current) -> String {
        if state.status == .needsLogin { return texts.bar.signIn }
        let limits = [state.snapshot?.session, state.snapshot?.weekly].compactMap { $0 }
        if limits.isEmpty { return "Claude: \(texts.popup.loading)" }
        return limits.map { limit in
            var part = "\(Format.limitLabel(limit, texts)) \(Format.percent(limit.usedPercent))"
            if let reset = limit.resetsAt { part += ", " + resetLine(reset, now: now, texts, calendar: calendar) }
            return part
        }.joined(separator: "; ")
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd macos && swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources macos/Tests
git commit -m "feat(macos): popover and accessibility wording" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 9: Account model and menu labels

**Files:**
- Create: `macos/Sources/ClaudeUsageBarCore/AccountLogin.swift`, `AccountLabels.swift`
- Test: `macos/Tests/ClaudeUsageBarCoreTests/AccountLoginTests.swift`, `AccountLabelsTests.swift`; modify `TestSupport.swift` (adds `Logins.make`, `Logins.accessToken`)

**Interfaces:**
- Consumes: `JSONValue`, `Format`, `Texts` (Tasks 2 and 3).
- Produces:
  - `AccountKey(accountUuid:organizationUuid:)`, which is Hashable and whose description shows uuid prefixes;
  - `AccountLogin(secure:account:)` with `static secureKeys`, `.secure`, `.account`, `.key`, `.email`, `.organizationName`, `.refreshToken`, `.refreshTokenExpiresAt` and `.planName`; it is Equatable and its description is masked;
  - `SavedAccount(login:savedAt:)` with `.key`;
  - `AccountLabels.ordered(_:)`, `.label(_:among:)`, `.needsSignIn(_:now:)`, `.menuText(_:among:needsSignIn:_:)`.

- [ ] **Step 1: Write the failing tests**

Append to `macos/Tests/ClaudeUsageBarCoreTests/TestSupport.swift`:

```swift

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
```

Create `macos/Tests/ClaudeUsageBarCoreTests/AccountLoginTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeUsageBarCore

struct AccountLoginTests {
    @Test func keepsOnlyTheAccountScopedKeychainKeys() {
        let login = AccountLogin(
            secure: ["claudeAiOauth": .object([:]), "organizationUuid": .string("o"), "trustedDeviceToken": .string("t"), "mcpOAuth": .object([:])],
            account: [:])
        #expect(Set(login.secure.keys) == ["claudeAiOauth", "organizationUuid", "trustedDeviceToken"])
    }

    @Test func readsWhoItIsAndWhichPlan() {
        let login = Logins.make("a", "jan@firma.pl", org: "org-9", orgName: "Firma", tier: "default_claude_max_20x")

        #expect(login.key == AccountKey(accountUuid: "acc-a", organizationUuid: "org-9"))
        #expect(login.email == "jan@firma.pl")
        #expect(login.organizationName == "Firma")
        #expect(login.refreshToken == "refresh-a-1")
        #expect(login.refreshTokenExpiresAt == Logins.defaultRefreshExpiry)
        #expect(login.planName == "Max 20x")
    }

    @Test func description_hidesTokensAndTheEmail() {
        let text = String(describing: Logins.make("a", "jan@firma.pl"))
        #expect(text == "j***@firma.pl acc-a/org-1")
    }
}
```

Create `macos/Tests/ClaudeUsageBarCoreTests/AccountLabelsTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeUsageBarCore

struct AccountLabelsTests {
    let now = iso("2026-10-06T12:00:00Z")

    func saved(_ login: AccountLogin) -> SavedAccount { SavedAccount(login: login, savedAt: now) }

    @Test func label_isEmailAndPlan() {
        let a = saved(Logins.make("a", "jan@firma.pl", tier: "default_claude_max_5x"))
        #expect(AccountLabels.label(a, among: [a]) == "jan@firma.pl · Max 5x")
    }

    @Test func label_sameEmailAndPlanInTwoOrganizations_addsTheOrganization() {
        let personal = saved(Logins.make("a", "jan@firma.pl", orgName: "Personal"))
        let work = saved(Logins.make("a", "jan@firma.pl", org: "org-2", orgName: "R&D"))

        #expect(AccountLabels.label(personal, among: [personal, work]) == "jan@firma.pl · Max 5x · Personal")
        #expect(AccountLabels.label(work, among: [personal, work]) == "jan@firma.pl · Max 5x · R&D")
    }

    @Test func ordered_isAlphabeticalByEmail() {
        let z = saved(Logins.make("z", "zofia@x.pl"))
        let a = saved(Logins.make("a", "Adam@x.pl"))
        #expect(AccountLabels.ordered([z, a]).map(\.login.email) == ["Adam@x.pl", "zofia@x.pl"])
    }

    @Test(arguments: [(-1, true), (0, true), (1, false)])
    func needsSignIn_onceTheRefreshTokenExpired(hoursFromNow: Double, expected: Bool) {
        let account = saved(Logins.make("a", "a@x.pl", refreshExpires: now.addingTimeInterval(hoursFromNow * 3600)))
        #expect(AccountLabels.needsSignIn(account, now: now) == expected)
    }

    @Test func needsSignIn_unknownExpiry_isFalse() {
        let login = Logins.make("a", "a@x.pl")
        var oauth = login.secure["claudeAiOauth"]!.object!
        oauth.removeValue(forKey: "refreshTokenExpiresAt")

        #expect(!AccountLabels.needsSignIn(saved(AccountLogin(secure: ["claudeAiOauth": .object(oauth)], account: login.account)), now: now))
    }

    @Test(arguments: [("en", false, "a@x.pl · Max 5x"), ("en", true, "a@x.pl · Max 5x — sign in again"), ("pl", true, "a@x.pl · Max 5x — zaloguj ponownie")])
    func menuText_marksAccountsThatNeedANewLogin(lang: String, needsSignIn: Bool, expected: String) {
        let a = saved(Logins.make("a", "a@x.pl"))
        #expect(AccountLabels.menuText(a, among: [a], needsSignIn: needsSignIn, Lang.get(lang)) == expected)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macos && swift test`
Expected: build FAILS with `cannot find 'AccountLogin' in scope`.

- [ ] **Step 3: Implement**

Create `macos/Sources/ClaudeUsageBarCore/AccountLogin.swift`:

```swift
import Foundation

/// One Claude account: oauthAccount.accountUuid + organizationUuid (one person can be in several organizations).
public struct AccountKey: Hashable, Sendable, CustomStringConvertible {
    public var accountUuid: String
    public var organizationUuid: String

    public init(accountUuid: String, organizationUuid: String) {
        self.accountUuid = accountUuid
        self.organizationUuid = organizationUuid
    }

    // the log only ever sees uuid prefixes
    public var description: String { "\(accountUuid.prefix(8))/\(organizationUuid.prefix(8))" }
}

/// A Claude Code login as the CLI stores it: the account-scoped keys of its Keychain item (tokens, plan) and
/// `oauthAccount` from its global config (who). Raw JSON, so fields this app doesn't know round-trip unchanged.
public struct AccountLogin: Sendable, Equatable, CustomStringConvertible {
    /// The keys Claude Code removes from its Keychain item on logout: everything that belongs to one account.
    public static let secureKeys = ["claudeAiOauth", "organizationUuid", "trustedDeviceToken", "enterpriseGateway", "designOauth"]

    public let secure: [String: JSONValue]
    public let account: [String: JSONValue]

    public init(secure: [String: JSONValue], account: [String: JSONValue]) {
        self.secure = secure.filter { Self.secureKeys.contains($0.key) }
        self.account = account
    }

    public var key: AccountKey {
        AccountKey(accountUuid: account["accountUuid"]?.string ?? "", organizationUuid: account["organizationUuid"]?.string ?? "")
    }

    public var email: String { account["emailAddress"]?.string ?? "" }
    public var organizationName: String? { account["organizationName"]?.string }
    var oauth: JSONValue? { secure["claudeAiOauth"] }
    public var refreshToken: String? { oauth?["refreshToken"]?.string }

    /// After this the refresh token is dead and only a new `claude auth login` helps; nil when the CLI didn't say.
    public var refreshTokenExpiresAt: Date? {
        oauth?["refreshTokenExpiresAt"]?.number.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    public var planName: String {
        Format.planName(subscriptionType: oauth?["subscriptionType"]?.string, rateLimitTier: oauth?["rateLimitTier"]?.string)
    }

    // never let tokens reach logs through string interpolation
    public var description: String { "\(Format.maskEmail(email)) \(key)" }
}

/// A saved login and when it was last captured.
public struct SavedAccount: Sendable, Equatable {
    public var login: AccountLogin
    public var savedAt: Date

    public init(login: AccountLogin, savedAt: Date) {
        self.login = login
        self.savedAt = savedAt
    }

    public var key: AccountKey { login.key }
}
```

Create `macos/Sources/ClaudeUsageBarCore/AccountLabels.swift`:

```swift
import Foundation

/// How saved accounts read in the menu.
public enum AccountLabels {
    /// Alphabetical by e-mail, then organization.
    public static func ordered(_ accounts: [SavedAccount]) -> [SavedAccount] {
        accounts.sorted {
            ($0.login.email.lowercased(), ($0.login.organizationName ?? "").lowercased())
                < ($1.login.email.lowercased(), ($1.login.organizationName ?? "").lowercased())
        }
    }

    /// "jan@firma.pl · Max 5x"; the organization is added when another saved account would read the same.
    public static func label(_ account: SavedAccount, among all: [SavedAccount]) -> String {
        let label = basic(account.login)
        let ambiguous = all.contains { $0.key != account.key && basic($0.login) == label }
        return ambiguous ? "\(label) · \(account.login.organizationName ?? account.key.organizationUuid)" : label
    }

    /// Past refreshTokenExpiresAt the saved tokens can't be renewed: only a new login helps.
    public static func needsSignIn(_ account: SavedAccount, now: Date) -> Bool {
        guard let expires = account.login.refreshTokenExpiresAt else { return false }
        return expires <= now
    }

    public static func menuText(_ account: SavedAccount, among all: [SavedAccount], needsSignIn: Bool, _ texts: Texts) -> String {
        needsSignIn ? Texts.fill(texts.accounts.signInAgain, ("account", label(account, among: all))) : label(account, among: all)
    }

    static func basic(_ login: AccountLogin) -> String {
        login.planName.isEmpty ? login.email : "\(login.email) · \(login.planName)"
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd macos && swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources macos/Tests
git commit -m "feat(macos): account model and menu labels" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Claude Code's login — read and write (Keychain item + `~/.claude.json`)

**Files:**
- Create: `macos/Sources/ClaudeUsageBarCore/CliLogin.swift`
- Test: `macos/Tests/ClaudeUsageBarCoreTests/CliLoginTests.swift`; modify `TestSupport.swift` (adds `Logins.writeCli`)

**Interfaces:**
- Consumes: `SecurityCLI`, `KeychainNames`, `JSONValue`, `AccountLogin`, `AppPaths`, `Log`, `FakeSecurity` (Tasks 2, 4, 5 and 9).
- Produces:
  - `CliLoginError.notWritten(String)`;
  - `struct CliLogin: Sendable` with `init(keychain:service:keychainAccount:globalConfig:backupDir:sealBackup:)`, `static standard(keychain:paths:sealBackup:)`, `static forConfigDir(_:keychain:account:)`, `readCurrent() async -> AccountLogin?`, `write(_:) async throws` and `deleteItem() async`;
  - `static accountCaches`;
  - the internal test hook `var beforeReplace: (@Sendable (URL) -> Void)?`;
  - the test helper `Logins.writeCli(_:service:account:config:_:)`.

- [ ] **Step 1: Write the failing tests**

Append to `macos/Tests/ClaudeUsageBarCoreTests/TestSupport.swift`:

```swift

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
```

Create `macos/Tests/ClaudeUsageBarCoreTests/CliLoginTests.swift`:

```swift
import Foundation
import os
import Testing
@testable import ClaudeUsageBarCore

struct CliLoginTests {
    let temp = TempDir()
    let fake = FakeSecurity()
    let a = Logins.make("a", "a@example.com", extraSecure: ["trustedDeviceToken": .string("device-a")])
    let b = Logins.make("b", "b@example.com", org: "org-2")
    var config: URL { temp["home/.claude.json"] }

    func cli(backup: Bool = false) -> CliLogin {
        CliLogin(keychain: SecurityCLI(runner: fake), service: KeychainNames.claudeService, keychainAccount: "tester",
                 globalConfig: config, backupDir: backup ? temp["backup"] : nil,
                 sealBackup: backup ? { @Sendable data in Data(data.reversed()) } : nil)
    }

    var itemData: Data? { fake[KeychainNames.claudeService, "tester"] }
    func item() throws -> [String: JSONValue] { try JSONValue.parse(itemData!).object! }
    func configRoot() throws -> [String: JSONValue] { try JSONValue.parse(Data(contentsOf: config)).object! }

    @Test func readCurrent_readsTheAccountScopedKeysAndOauthAccount() async {
        Logins.writeCli(fake, config: config, a)
        #expect(await cli().readCurrent() == a)
    }

    @Test func readCurrent_withoutALogin_isNil() async throws {
        #expect(await cli().readCurrent() == nil) // nothing at all

        Logins.writeCli(fake, config: config, a)
        try FileManager.default.removeItem(at: config)
        #expect(await cli().readCurrent() == nil) // no global config

        Logins.writeCli(fake, config: config, a)
        fake[KeychainNames.claudeService, "tester"] = Data(#"{"mcpOAuth":{}}"#.utf8)
        #expect(await cli().readCurrent() == nil) // signed out: no claudeAiOauth

        fake[KeychainNames.claudeService, "tester"] = Data("garbage".utf8)
        #expect(await cli().readCurrent() == nil)

        Logins.writeCli(fake, config: config, AccountLogin(secure: a.secure, account: ["emailAddress": .string("x@y.z")]))
        #expect(await cli().readCurrent() == nil) // no accountUuid
    }

    @Test func write_replacesOnlyTheLogin_andKeepsEverythingElse() async throws {
        Logins.writeCli(fake, config: config, a)

        try await cli().write(b)

        let item = try item()
        #expect(item["mcpOAuth"]?["srv|abc"]?["accessToken"]?.string == "mcp-token")
        #expect(item["claudeAiOauth"]?["accessToken"]?.string == "access-b-1")
        #expect(item["organizationUuid"]?.string == "org-2")
        #expect(item["trustedDeviceToken"] == nil) // a's, and b has none
        let root = try configRoot()
        #expect(root["oauthAccount"] == .object(b.account))
        #expect(root["numStartups"] == .int(5))
        #expect(root["projects"]?["/Users/łukasz/zażółć gęślą"] != nil)
        #expect(root["someFutureSetting"]?["nested"] == .array([.int(1), .double(2.5), .string("x")]))
        #expect(root["cachedGrowthBookFeatures"] != nil)
        #expect(root["modelAccessCache"] == nil)
        #expect(root["cachedUsageUtilization"] == nil)
        #expect(await cli().readCurrent() == b)
    }

    @Test func write_itemIsCompactJSON() async throws {
        Logins.writeCli(fake, config: config, a)
        try await cli().write(b)
        #expect(!String(decoding: itemData!, as: UTF8.self).contains("\n"))
    }

    @Test func write_keepsTheConfigPermissions() async throws {
        Logins.writeCli(fake, config: config, a)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)

        try await cli().write(b)

        #expect(try FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func write_withoutAnItem_createsIt() async throws {
        Logins.writeCli(fake, config: config, a)
        fake[KeychainNames.claudeService, "tester"] = nil

        try await cli().write(b)

        #expect(try item() == b.secure)
    }

    @Test func write_configChangedOnce_retriesAndKeepsTheOtherChange() async throws {
        Logins.writeCli(fake, config: config, a)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        var cli = cli()
        cli.beforeReplace = { url in
            guard calls.withLock({ $0 += 1; return $0 }) == 1 else { return }
            // a running Claude Code session saves its config in between
            var root = try! JSONValue.parse(Data(contentsOf: url)).object!
            root["numStartups"] = .int(6)
            try! JSONValue.object(root).serialized().write(to: url)
        }

        try await cli.write(b)

        let root = try configRoot()
        #expect(root["numStartups"] == .int(6))
        #expect(root["oauthAccount"] == .object(b.account))
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func write_configAlwaysBusy_failsAndRestoresTheItem() async throws {
        Logins.writeCli(fake, config: config, a)
        let itemBefore = itemData
        let calls = OSAllocatedUnfairLock(initialState: 0)
        var cli = cli()
        cli.beforeReplace = { url in
            let n = calls.withLock { $0 += 1; return $0 }
            let handle = try! FileHandle(forWritingTo: url)
            _ = try! handle.seekToEnd()
            try! handle.write(contentsOf: Data(String(repeating: " ", count: n).utf8))
            try! handle.close()
        }

        await #expect(throws: CliLoginError.self) { try await cli.write(b) }

        #expect(itemData == itemBefore)
        #expect(try configRoot()["oauthAccount"] == .object(a.account))
        #expect(calls.withLock { $0 } == 3)
    }

    @Test func write_unparseableConfig_failsAndRestoresTheItem() async throws {
        Logins.writeCli(fake, config: config, a)
        let itemBefore = itemData
        let damaged = try String(contentsOf: config, encoding: .utf8)
            .replacingOccurrences(of: "\"numStartups\": 5", with: "\"numStartups\": 5, \"lastPrompt\": \"x\\ud83dy\"")
        try damaged.write(to: config, atomically: true, encoding: .utf8)

        await #expect(throws: CliLoginError.self) { try await cli().write(b) }

        #expect(itemData == itemBefore)
    }

    @Test func write_itemThatIsNotJSON_isLeftAlone() async throws {
        Logins.writeCli(fake, config: config, a)
        fake[KeychainNames.claudeService, "tester"] = Data("garbage".utf8)

        await #expect(throws: CliLoginError.self) { try await cli().write(b) }

        #expect(itemData == Data("garbage".utf8))
    }

    @Test func write_lockedKeychain_changesNothing() async throws {
        Logins.writeCli(fake, config: config, a)
        let configBefore = try Data(contentsOf: config)
        fake.isLocked = true

        await #expect(throws: CliLoginError.self) { try await cli().write(b) }

        #expect(try Data(contentsOf: config) == configBefore)
    }

    @Test func write_backsUpTheConfigAndTheSealedItem() async throws {
        Logins.writeCli(fake, config: config, a)
        let itemBefore = try #require(itemData)
        let configBefore = try Data(contentsOf: config)

        try await cli(backup: true).write(b)

        #expect(try Data(contentsOf: temp["backup/claude.json"]) == configBefore)
        #expect(try Data(contentsOf: temp["backup/credentials.dat"]) == Data(itemBefore.reversed()))
    }

    @Test func forConfigDir_usesTheSuffixedItemAndTheDirsOwnConfig() async {
        let dir = temp["login-1"]
        let login = CliLogin.forConfigDir(dir, keychain: SecurityCLI(runner: fake), account: "tester")
        Logins.writeCli(fake, service: KeychainNames.claudeService(configDir: dir.path), config: dir.appending(path: ".claude.json"), b)

        #expect(await login.readCurrent() == b)
        await login.deleteItem()
        #expect(fake.services.isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macos && swift test`
Expected: build FAILS with `cannot find 'CliLogin' in scope`.

- [ ] **Step 3: Implement**

Create `macos/Sources/ClaudeUsageBarCore/CliLogin.swift`:

```swift
import Foundation

public enum CliLoginError: Error, Equatable {
    case notWritten(String)
}

/// Claude Code's login: the account-scoped keys of its Keychain item and `oauthAccount` in its global config.
/// The only code that writes Claude Code's data. It replaces those keys, drops the account caches (as
/// `claude auth logout` does) and leaves everything else (`mcpOAuth`, projects, keys it doesn't know) as it was.
public struct CliLogin: Sendable {
    /// Global config keys Claude Code removes on logout: they describe the previous account.
    public static let accountCaches = [
        "subscriptionNoticeCount", "hasAvailableSubscription", "additionalModelOptionsCache", "additionalModelOptionsAnsweredAt",
        "additionalModelCostsCache", "modelAccessCache", "orgModelDefaultCache", "cachedArtifactRoster", "artifactRosterDenied",
        "lastSeenOrgDefaultUpdatedAt", "clientDataCache", "clientDataCacheSlots", "autoCompactWindowsCache", "cachedUsageUtilization",
    ]
    static let attempts = 3

    let keychain: SecurityCLI
    let service: String
    let keychainAccount: String
    let globalConfig: URL
    let backupDir: URL?
    /// Encrypts the backup of the Keychain item (it holds live tokens); nil: the item isn't backed up.
    let sealBackup: (@Sendable (Data) async throws -> Data)?
    /// Test hook: runs between reading the config and replacing it, where a running Claude Code session may write it.
    var beforeReplace: (@Sendable (URL) -> Void)?

    public init(keychain: SecurityCLI, service: String, keychainAccount: String, globalConfig: URL,
                backupDir: URL? = nil, sealBackup: (@Sendable (Data) async throws -> Data)? = nil) {
        self.keychain = keychain
        self.service = service
        self.keychainAccount = keychainAccount
        self.globalConfig = globalConfig
        self.backupDir = backupDir
        self.sealBackup = sealBackup
    }

    /// The login in the user's home: the default item and ~/.claude.json.
    public static func standard(keychain: SecurityCLI, paths: AppPaths, sealBackup: @escaping @Sendable (Data) async throws -> Data) -> CliLogin {
        CliLogin(keychain: keychain, service: KeychainNames.claudeService, keychainAccount: KeychainNames.currentUser,
                 globalConfig: paths.claudeGlobalConfig, backupDir: paths.backupDir, sealBackup: sealBackup)
    }

    /// The login of a CLI run with CLAUDE_CONFIG_DIR=<dir>: its own item and <dir>/.claude.json.
    public static func forConfigDir(_ dir: URL, keychain: SecurityCLI, account: String = KeychainNames.currentUser) -> CliLogin {
        CliLogin(keychain: keychain, service: KeychainNames.claudeService(configDir: dir.path), keychainAccount: account,
                 globalConfig: dir.appending(path: ".claude.json"))
    }

    /// nil when the item or the file is missing or unreadable, or holds no claude.ai login.
    public func readCurrent() async -> AccountLogin? {
        guard let data = try? await keychain.read(service: service, account: keychainAccount),
              let item = (try? JSONValue.parse(data))?.object, item["claudeAiOauth"]?.object != nil,
              let config = try? Data(contentsOf: globalConfig),
              let account = (try? JSONValue.parse(config))?["oauthAccount"]?.object else { return nil }
        let login = AccountLogin(secure: item, account: account)
        return login.key.accountUuid.isEmpty ? nil : login
    }

    /// Makes `login` Claude Code's login. Throws when something can't be written; the old login then stays whole.
    public func write(_ login: AccountLogin) async throws {
        let itemBefore: Data?
        do { itemBefore = try await keychain.read(service: service, account: keychainAccount) }
        catch { throw CliLoginError.notWritten("keychain: \(error)") }
        var item: [String: JSONValue] = [:]
        if let itemBefore {
            guard let parsed = (try? JSONValue.parse(itemBefore))?.object else {
                throw CliLoginError.notWritten("the Keychain item is not a JSON object")
            }
            item = parsed
        }
        try await backup(itemBefore)

        for key in AccountLogin.secureKeys { item.removeValue(forKey: key) }
        item.merge(login.secure) { _, new in new }
        do { try await keychain.write(service: service, account: keychainAccount, data: try JSONValue.object(item).serialized(pretty: false)) }
        catch { throw CliLoginError.notWritten("keychain: \(error)") }

        do {
            try await updateConfig { config in
                config["oauthAccount"] = .object(login.account)
                for key in Self.accountCaches { config.removeValue(forKey: key) }
            }
        } catch {
            await restoreItem(itemBefore) // one account's tokens under another account's name would be worse
            throw error
        }
    }

    /// Only for the temporary login of "Add account".
    public func deleteItem() async {
        try? await keychain.delete(service: service, account: keychainAccount)
    }

    func updateConfig(_ edit: (inout [String: JSONValue]) -> Void) async throws {
        var lastError: any Error = CliLoginError.notWritten("not attempted")
        for attempt in 1...Self.attempts {
            do {
                try replaceConfig(edit)
                return
            } catch {
                lastError = error
                Log.write("login: \(globalConfig.lastPathComponent), attempt \(attempt) of \(Self.attempts): \(error)")
                if attempt < Self.attempts { try? await Task.sleep(for: .milliseconds(50 * attempt)) }
            }
        }
        throw CliLoginError.notWritten("\(globalConfig.lastPathComponent) not written: \(lastError)")
    }

    /// Read → edit → atomic replace, keeping the file's permissions. Running sessions rewrite ~/.claude.json often:
    /// when it changed after we read it, this throws and the caller starts over from its new content.
    func replaceConfig(_ edit: (inout [String: JSONValue]) -> Void) throws {
        let before = try ConfigFile.read(globalConfig)
        var root = before?.root ?? [:]
        edit(&root)
        let directory = globalConfig.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appending(path: ".\(globalConfig.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temp) }
        try JSONValue.object(root).serialized().write(to: temp)
        if let permissions = before?.permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
        }
        beforeReplace?(globalConfig)
        if ConfigFile.changed(globalConfig, since: before) {
            throw CliLoginError.notWritten("\(globalConfig.lastPathComponent) changed while being updated")
        }
        guard rename(temp.path, globalConfig.path) == 0 else { throw CliLoginError.notWritten("rename failed: errno \(errno)") }
    }

    /// The config and the (sealed) Keychain item as they were before the last switch.
    func backup(_ item: Data?) async throws {
        guard let backupDir else { return }
        do {
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            let configCopy = backupDir.appending(path: "claude.json")
            try? FileManager.default.removeItem(at: configCopy)
            if FileManager.default.fileExists(atPath: globalConfig.path) {
                try FileManager.default.copyItem(at: globalConfig, to: configCopy)
            }
            if let item, let sealBackup {
                try await sealBackup(item).write(to: backupDir.appending(path: "credentials.dat"), options: .atomic)
            }
        } catch {
            throw CliLoginError.notWritten("backup: \(error)")
        }
    }

    func restoreItem(_ data: Data?) async {
        do {
            if let data {
                try await keychain.write(service: service, account: keychainAccount, data: data)
            } else {
                try await keychain.delete(service: service, account: keychainAccount)
            }
        } catch {
            Log.write("login: couldn't restore the Keychain item: \(error)")
        }
    }
}

/// The global config as read, and the file's state at that moment.
struct ConfigFile {
    let root: [String: JSONValue]
    let modified: Date?
    let size: Int?
    let permissions: Int?

    /// nil when the file doesn't exist; throws when it can't be read or isn't a JSON object.
    static func read(_ url: URL) throws -> ConfigFile? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // taken before reading: a write after this point counts as a change
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let root = try JSONValue.parse(Data(contentsOf: url)).object else {
            throw CliLoginError.notWritten("\(url.lastPathComponent) is not a JSON object")
        }
        return ConfigFile(root: root, modified: attributes[.modificationDate] as? Date,
                          size: (attributes[.size] as? NSNumber)?.intValue,
                          permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue)
    }

    static func changed(_ url: URL, since before: ConfigFile?) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return before != nil }
        guard let before else { return true }
        return attributes[.modificationDate] as? Date != before.modified || (attributes[.size] as? NSNumber)?.intValue != before.size
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd macos && swift test`
Expected: PASS. All 13 `CliLoginTests` pass, along with the earlier suites.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources macos/Tests
git commit -m "feat(macos): read and write Claude Code's login in the Keychain and ~/.claude.json" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Encrypted saved accounts

**Files:**
- Create: `macos/Sources/ClaudeUsageBarCore/AccountStore.swift`
- Test: `macos/Tests/ClaudeUsageBarCoreTests/AccountStoreTests.swift`

**Interfaces:**
- Consumes: `SecurityCLI`, `KeychainNames`, `KeychainError`, `JSONValue`, `AccountLogin`, `SavedAccount`, `Log` (Tasks 2, 4, 5 and 9).
- Produces:
  - `@MainActor final class AccountsKey(keychain:account:)` with `key() async throws -> SymmetricKey`, `seal(_:) async throws -> Data` and `open(_:) async throws -> Data`;
  - `@MainActor final class AccountStore(file:key:)` with `all() async throws -> [SavedAccount]`, `find(_:)`, `upsert(_:)` and `remove(_:)`.

- [ ] **Step 1: Write the failing tests**

Create `macos/Tests/ClaudeUsageBarCoreTests/AccountStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeUsageBarCore

@MainActor struct AccountStoreTests {
    let temp = TempDir()
    let fake = FakeSecurity()
    let now = iso("2026-10-06T12:00:00Z")
    var file: URL { temp["data/accounts.dat"] }

    func store(_ keychain: FakeSecurity? = nil) -> AccountStore {
        AccountStore(file: file, key: AccountsKey(keychain: SecurityCLI(runner: keychain ?? fake)))
    }

    func saved(_ id: String, at offset: TimeInterval = 0) -> SavedAccount {
        SavedAccount(login: Logins.make(id, "\(id)@x.pl"), savedAt: now.addingTimeInterval(offset))
    }

    @Test func savedAccounts_surviveARestart() async throws {
        let first = store()
        try await first.upsert(saved("a"))
        try await first.upsert(saved("b", at: 0.123))

        #expect(try await store().all() == [saved("a"), saved("b", at: 0.123)])
    }

    @Test func upsert_replacesTheSameAccount_removeForgetsIt() async throws {
        let store = store()
        try await store.upsert(saved("a"))
        try await store.upsert(saved("b"))
        try await store.upsert(saved("a", at: 60))

        #expect(try await store.find(saved("a").key)?.savedAt == now.addingTimeInterval(60))
        try await store.remove(saved("a").key)
        #expect(try await store.all().map(\.key) == [saved("b").key])
    }

    @Test func file_isEncrypted_andOnlyForTheUser() async throws {
        try await store().upsert(saved("a"))

        let data = try Data(contentsOf: file)
        #expect(data.range(of: Data("access-a-1".utf8)) == nil)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    }

    @Test func key_isCreatedOnce_inTheAppsOwnItem() async throws {
        try await store().upsert(saved("a"))
        let stored = try #require(fake[KeychainNames.appService, KeychainNames.accountsKeyAccount])

        try await store().upsert(saved("b"))

        #expect(fake.services == ["ClaudeUsageBar"])
        #expect(fake[KeychainNames.appService, KeychainNames.accountsKeyAccount] == stored)
        #expect(Data(base64Encoded: stored)?.count == 32)
    }

    @Test func unreadableFile_isMovedAside_andTheListStartsEmpty() async throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: file)

        #expect(try await store().all().isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path + ".bad"))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func fileSealedWithAnotherKey_isMovedAside() async throws {
        try await store().upsert(saved("a"))

        #expect(try await store(FakeSecurity()).all().isEmpty) // another Mac user, or the key item was deleted
        #expect(FileManager.default.fileExists(atPath: file.path + ".bad"))
    }

    @Test func lockedKeychain_throws_andLeavesTheFileAlone() async throws {
        try await store().upsert(saved("a"))
        fake.isLocked = true

        await #expect(throws: KeychainError.locked) { _ = try await store().all() }

        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(!FileManager.default.fileExists(atPath: file.path + ".bad"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macos && swift test`
Expected: build FAILS with `cannot find 'AccountStore' in scope`.

- [ ] **Step 3: Implement**

Create `macos/Sources/ClaudeUsageBarCore/AccountStore.swift`:

```swift
import CryptoKit
import Foundation

/// The key that encrypts accounts.dat and the Keychain backup. It lives in this app's own Keychain item, written
/// through `security`, so a rebuilt app is never asked for the keychain password. Created on first use.
@MainActor public final class AccountsKey {
    let keychain: SecurityCLI
    let account: String
    private var cached: SymmetricKey?

    public init(keychain: SecurityCLI, account: String = KeychainNames.accountsKeyAccount) {
        self.keychain = keychain
        self.account = account
    }

    /// Throws while the Keychain can't be read (locked): a new key then would make the saved accounts unreadable.
    public func key() async throws -> SymmetricKey {
        if let cached { return cached }
        if let stored = try await keychain.read(service: KeychainNames.appService, account: account),
           let bytes = Data(base64Encoded: stored), bytes.count == 32 {
            let key = SymmetricKey(data: bytes)
            cached = key
            return key
        }
        let key = SymmetricKey(size: .bits256)
        // base64 is printable text, so `security -w` hands it back as it is
        let encoded = key.withUnsafeBytes { Data($0) }.base64EncodedData()
        try await keychain.write(service: KeychainNames.appService, account: account, data: encoded)
        cached = key
        return key
    }

    public func seal(_ data: Data) async throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: try await key()).combined else { throw CryptoKitError.incorrectParameterSize }
        return combined
    }

    public func open(_ data: Data) async throws -> Data {
        let key = try await key()
        return try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
    }
}

/// Saved accounts in accounts.dat: one JSON list, encrypted with AccountsKey. Shaped like the Windows file, except
/// that `secure` holds every account-scoped Keychain key.
@MainActor public final class AccountStore {
    let file: URL
    let key: AccountsKey
    private var accounts: [SavedAccount]?

    public init(file: URL, key: AccountsKey) {
        self.file = file
        self.key = key
    }

    /// Throws while the key can't be read (locked Keychain); nothing is cached then, so the next call tries again.
    public func all() async throws -> [SavedAccount] {
        if let accounts { return accounts }
        let loaded = try await load()
        accounts = loaded
        return loaded
    }

    public func find(_ key: AccountKey) async throws -> SavedAccount? {
        try await all().first { $0.key == key }
    }

    public func upsert(_ account: SavedAccount) async throws {
        var list = try await all()
        if let index = list.firstIndex(where: { $0.key == account.key }) {
            list[index] = account
        } else {
            list.append(account)
        }
        try await save(list)
    }

    public func remove(_ key: AccountKey) async throws {
        try await save(try await all().filter { $0.key != key })
    }

    private func load() async throws -> [SavedAccount] {
        guard let sealed = try? Data(contentsOf: file) else { return [] }
        let plain: Data
        do {
            plain = try await key.open(sealed)
        } catch let error as KeychainError {
            throw error
        } catch {
            return moveAside("can't be decrypted")
        }
        guard let root = try? JSONValue.parse(plain), case .array(let entries)? = root["accounts"] else {
            return moveAside("has no account list")
        }
        let parsed = entries.compactMap(Self.parse)
        guard parsed.count == entries.count else { return moveAside("has an unreadable entry") }
        return parsed
    }

    // another Mac user's file, a lost key or a damaged file: keep it aside and start over
    private func moveAside(_ why: String) -> [SavedAccount] {
        Log.write("accounts: \(file.lastPathComponent) \(why), moved to .bad")
        let bad = file.appendingPathExtension("bad")
        try? FileManager.default.removeItem(at: bad)
        try? FileManager.default.moveItem(at: file, to: bad)
        return []
    }

    private func save(_ list: [SavedAccount]) async throws {
        let root = JSONValue.object(["version": .int(1), "accounts": .array(list.map(Self.entry))])
        let sealed = try await key.seal(try root.serialized(pretty: false))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try sealed.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        accounts = list
    }

    static func entry(_ account: SavedAccount) -> JSONValue {
        .object([
            // seconds since Date's own reference date: round-trips exactly, unlike a 1970-based value
            "savedAt": .double(account.savedAt.timeIntervalSinceReferenceDate),
            "secure": .object(account.login.secure),
            "oauthAccount": .object(account.login.account),
        ])
    }

    static func parse(_ entry: JSONValue) -> SavedAccount? {
        guard let savedAt = entry["savedAt"]?.number, let secure = entry["secure"]?.object, let account = entry["oauthAccount"]?.object else {
            return nil
        }
        return SavedAccount(login: AccountLogin(secure: secure, account: account), savedAt: Date(timeIntervalSinceReferenceDate: savedAt))
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd macos && swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources macos/Tests
git commit -m "feat(macos): encrypted saved accounts with the key in the app's own Keychain item" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: Account switcher

**Files:**
- Create: `macos/Sources/ClaudeUsageBarCore/AccountSwitcher.swift`
- Test: `macos/Tests/ClaudeUsageBarCoreTests/AccountSwitcherTests.swift`

**Interfaces:**
- Consumes: `CliLogin`, `AccountStore`, `AccountsKey`, `AsyncLock`, `TimeSource`, `AccountLogin`, `SavedAccount`, `AccountKey`, `Log`, plus the test helpers `FakeSecurity`, `Logins`, `TempDir`, `FakeTime`, `Pending` (Tasks 4–11).
- Produces:
  - `AccountError` (`.claudeNotFound`, `.loginFailed(String)`, `.writeFailed(String)`);
  - `@MainActor final class AccountSwitcher(cli:store:cliLock:loginRoot:loginFor:runLogin:time:)` with `active: AccountLogin?`, `isLoginRunning`, `onSwitched: (() -> Void)?`, `accounts() async throws`, `sync() async`, `switchTo(_:) async throws`, `addAccount(email:) async throws` and `remove(_:) async throws`.

- [ ] **Step 1: Write the failing tests**

Create `macos/Tests/ClaudeUsageBarCoreTests/AccountSwitcherTests.swift`:

```swift
import Foundation
import os
import Testing
@testable import ClaudeUsageBarCore

@MainActor final class AccountSwitcherTests {
    let now: Date
    let temp: TempDir
    let fake: FakeSecurity
    let time: FakeTime
    let store: AccountStore
    let cliLock = AsyncLock()
    let a = Logins.make("a", "a@example.com")
    let b = Logins.make("b", "b@example.com")
    var logins: [(email: String?, dir: URL)] = []
    /// What the fake `claude auth login` does in its dir.
    var login: (URL) async throws -> Bool = { _ in false }
    var switched = 0

    init() {
        let now = iso("2026-10-06T12:00:00Z"), temp = TempDir(), fake = FakeSecurity()
        self.now = now
        self.temp = temp
        self.fake = fake
        time = FakeTime(now)
        store = AccountStore(file: temp["data/accounts.dat"], key: AccountsKey(keychain: SecurityCLI(runner: fake)))
    }

    var homeConfig: URL { temp["home/.claude.json"] }
    var cli: CliLogin {
        CliLogin(keychain: SecurityCLI(runner: fake), service: KeychainNames.claudeService, keychainAccount: "tester",
                 globalConfig: homeConfig, backupDir: temp["data/backup"])
    }

    func cliNow() async -> AccountLogin? { await cli.readCurrent() }
    func signInCli(_ login: AccountLogin) { Logins.writeCli(fake, config: homeConfig, login) }
    func temporaryService(_ dir: URL) -> String { KeychainNames.claudeService(configDir: dir.path) }

    /// A fake `claude auth login` that signs in as `account` in its dir.
    func logsIn(_ account: AccountLogin) -> (URL) async throws -> Bool {
        { [fake] dir in
            Logins.writeCli(fake, service: KeychainNames.claudeService(configDir: dir.path), config: dir.appending(path: ".claude.json"), account)
            return true
        }
    }

    func make(cli custom: CliLogin? = nil) -> AccountSwitcher {
        let switcher = AccountSwitcher(
            cli: custom ?? cli, store: store, cliLock: cliLock, loginRoot: temp["data"],
            loginFor: { [fake] dir in CliLogin.forConfigDir(dir, keychain: SecurityCLI(runner: fake), account: "tester") },
            runLogin: { [unowned self] email, dir in
                self.logins.append((email, dir))
                return try await self.login(dir)
            },
            time: time)
        switcher.onSwitched = { [unowned self] in self.switched += 1 }
        return switcher
    }

    @Test func sync_savesAnAccountSignedInByHand() async throws {
        signInCli(a)
        let switcher = make()

        await switcher.sync()

        #expect(switcher.active?.key == a.key)
        #expect(try await store.all() == [SavedAccount(login: a, savedAt: now)])
    }

    @Test func sync_unchangedLogin_keepsTheSavedCopy() async throws {
        signInCli(a)
        let switcher = make()
        await switcher.sync()
        time.advance(5 * 60)

        await switcher.sync()

        #expect(try await store.all().map(\.savedAt) == [now])
    }

    @Test func sync_rotatedTokens_updateTheSavedCopy() async throws {
        signInCli(a)
        let switcher = make()
        await switcher.sync()
        signInCli(Logins.make("a", "a@example.com", token: "2")) // the CLI refreshed its token

        await switcher.sync()

        #expect(Logins.accessToken(try await store.all().first?.login) == "access-a-2")
    }

    @Test func sync_signedOut_savesNothing() async throws {
        let switcher = make()

        await switcher.sync()

        #expect(switcher.active == nil)
        #expect(try await store.all().isEmpty)
    }

    @Test func switchTo_writesTheTarget_andKeepsTheLatestTokensOfTheAccountLeft() async throws {
        try await store.upsert(SavedAccount(login: b, savedAt: now))
        signInCli(a)
        let switcher = make()
        await switcher.sync()
        signInCli(Logins.make("a", "a@example.com", token: "2")) // rotated after the last sync

        try await switcher.switchTo(b.key)

        #expect(await cliNow() == b)
        #expect(switcher.active?.key == b.key)
        #expect(Logins.accessToken(try await store.find(a.key)?.login) == "access-a-2")
        #expect(switched == 1)
    }

    @Test func switchTo_theActiveAccount_changesNothing() async throws {
        signInCli(a)
        let switcher = make()
        let config = try Data(contentsOf: homeConfig)

        try await switcher.switchTo(a.key)

        #expect(try Data(contentsOf: homeConfig) == config)
        #expect(switched == 0)
    }

    @Test func switchTo_waitsWhileTheCliIsRenewingItsToken() async throws {
        try await store.upsert(SavedAccount(login: b, savedAt: now))
        signInCli(a)
        let switcher = make()
        await cliLock.lock() // a `claude -p` renewal is running

        let switching = Task { try await switcher.switchTo(b.key) }
        for _ in 0..<20 { await Task.yield() }
        #expect(await cliNow() == a)

        cliLock.unlock()
        try await switching.value
        #expect(await cliNow() == b)
        #expect(!cliLock.isLocked)
    }

    @Test func switchTo_unwritableConfig_failsAndKeepsTheActiveAccount() async throws {
        try await store.upsert(SavedAccount(login: b, savedAt: now))
        signInCli(a)
        let switcher = make()
        await switcher.sync()
        try Data("{damaged".utf8).write(to: homeConfig)
        let item = fake[KeychainNames.claudeService, "tester"]

        await #expect(throws: AccountError.self) { try await switcher.switchTo(b.key) }

        #expect(fake[KeychainNames.claudeService, "tester"] == item)
        #expect(switched == 0)
        #expect(!cliLock.isLocked)
    }

    @Test func switchTo_configThatCantBeWrittenBack_failsAndKeepsTheActiveAccount() async throws {
        try await store.upsert(SavedAccount(login: b, savedAt: now))
        signInCli(a)
        let text = try String(contentsOf: homeConfig, encoding: .utf8)
            .replacingOccurrences(of: "\"numStartups\": 5", with: "\"numStartups\": 5, \"lastPrompt\": \"x\\ud83dy\"")
        try text.write(to: homeConfig, atomically: true, encoding: .utf8)
        let switcher = make()

        await #expect(throws: AccountError.self) { try await switcher.switchTo(b.key) }

        #expect(Logins.accessToken(fake[KeychainNames.claudeService, "tester"].flatMap { try? JSONValue.parse($0) }
            .map { AccountLogin(secure: $0.object ?? [:], account: [:]) }) == "access-a-1")
    }

    @Test func addAccount_signsInIsolated_savesTheAccount_andSwitchesToIt() async throws {
        signInCli(a)
        login = { [unowned self] dir in
            #expect(await self.cliNow() == a) // the user's own login stays untouched while signing in
            return try await self.logsIn(self.b)(dir)
        }
        let switcher = make()

        try await switcher.addAccount(email: nil)

        let attempt = try #require(logins.first)
        #expect(logins.count == 1)
        #expect(attempt.email == nil)
        #expect(attempt.dir.path.hasPrefix(temp["data/login-"].path))
        #expect(!FileManager.default.fileExists(atPath: attempt.dir.path))
        #expect(fake[temporaryService(attempt.dir), "tester"] == nil)
        #expect(await cliNow() == b)
        #expect(try await store.find(a.key) != nil)
        #expect(try await store.find(b.key) != nil)
        #expect(switched == 1)
        #expect(!switcher.isLoginRunning)
    }

    @Test func addAccount_loginFailedOrClosed_changesNothing() async throws {
        signInCli(a)
        login = { [unowned self] dir in
            _ = try await self.logsIn(self.b)(dir) // the login got as far as writing its item, then the window was closed
            return false
        }
        let switcher = make()

        await #expect(throws: AccountError.loginFailed("claude auth login failed or was closed")) { try await switcher.addAccount(email: nil) }

        let attempt = try #require(logins.first)
        #expect(await cliNow() == a)
        #expect(!FileManager.default.fileExists(atPath: attempt.dir.path))
        #expect(fake[temporaryService(attempt.dir), "tester"] == nil)
        #expect(switched == 0)
        #expect(!switcher.isLoginRunning)
    }

    @Test func addAccount_exitedWithoutALogin_isAFailedLogin() async {
        signInCli(a)
        login = { _ in true }

        await #expect(throws: AccountError.loginFailed("claude auth login left no login")) { try await self.make().addAccount(email: nil) }

        #expect(await cliNow() == a)
    }

    @Test func addAccount_cancelled_removesTheTempDir() async throws {
        login = { _ in throw CancellationError() }
        let switcher = make()

        await #expect(throws: CancellationError.self) { try await switcher.addAccount(email: nil) }

        #expect(!FileManager.default.fileExists(atPath: try #require(logins.first).dir.path))
        #expect(!switcher.isLoginRunning)
    }

    @Test func addAccount_freshLoginOfTheActiveAccount_replacesItsDeadTokens() async throws {
        signInCli(a)
        let switcher = make()
        await switcher.sync()
        login = logsIn(Logins.make("a", "a@example.com", token: "9"))

        try await switcher.addAccount(email: "a@example.com")

        #expect(logins.first?.email == "a@example.com")
        #expect(Logins.accessToken(await cliNow()) == "access-a-9")
        #expect(Logins.accessToken(try await store.all().first?.login) == "access-a-9")
        #expect(try await store.all().count == 1)
        #expect(switched == 1)
    }

    @Test func addAccount_freshLoginOfASavedAccount_refreshesItAndSwitches() async throws {
        try await store.upsert(SavedAccount(login: Logins.make("b", "b@example.com", refreshExpires: now.addingTimeInterval(-86400)), savedAt: now))
        signInCli(a)
        login = logsIn(Logins.make("b", "b@example.com", token: "9"))

        try await make().addAccount(email: "b@example.com")

        #expect(Logins.accessToken(try await store.find(b.key)?.login) == "access-b-9")
        #expect(Logins.accessToken(await cliNow()) == "access-b-9")
        #expect(try await store.find(a.key) != nil) // captured on the way out
    }

    @Test func addAccount_onlyOneLoginAtATime() async throws {
        let finish = Pending<Bool>()
        login = { [unowned self] dir in
            _ = try await self.logsIn(self.b)(dir)
            return await finish.wait()
        }
        let switcher = make()

        let first = Task { try await switcher.addAccount(email: nil) }
        while logins.isEmpty { await Task.yield() }
        #expect(switcher.isLoginRunning)
        try await switcher.addAccount(email: nil) // ignored: returns at once
        finish.resolve(true)
        try await first.value

        #expect(logins.count == 1)
        #expect(!switcher.isLoginRunning)
    }

    @Test func addAccount_removesLoginDirsAndItemsLeftByAnEarlierCrash() async throws {
        let leftover = temp["data/login-0123"]
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        fake[temporaryService(leftover), "tester"] = Data("{}".utf8)

        await #expect(throws: AccountError.self) { try await self.make().addAccount(email: nil) }

        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(fake[temporaryService(leftover), "tester"] == nil)
    }

    @Test func remove_inactiveAccount_forgetsIt_withoutTouchingTheCli() async throws {
        try await store.upsert(SavedAccount(login: b, savedAt: now))
        signInCli(a)
        let switcher = make()
        let item = fake[KeychainNames.claudeService, "tester"]
        let config = try Data(contentsOf: homeConfig)

        try await switcher.remove(b.key)

        #expect(try await store.find(b.key) == nil)
        #expect(fake[KeychainNames.claudeService, "tester"] == item)
        #expect(try Data(contentsOf: homeConfig) == config)
    }

    @Test func remove_activeAccount_isRefused() async throws {
        signInCli(a)
        let switcher = make()

        await #expect(throws: AccountError.self) { try await switcher.remove(self.a.key) }

        #expect(try await store.find(a.key) != nil)
    }

    @Test func sync_anotherAccountSignedInByHand_raisesSwitched() async {
        signInCli(a)
        let switcher = make()
        await switcher.sync() // what the app found at startup
        signInCli(b) // `/login` as b in a Claude Code session

        await switcher.sync()

        #expect(switcher.active?.key == b.key)
        #expect(switched == 1)
    }

    @Test func sync_firstReadAndTokenRotation_doNotRaiseSwitched() async {
        signInCli(a)
        let switcher = make()
        await switcher.sync()
        signInCli(Logins.make("a", "a@example.com", token: "2"))

        await switcher.sync()

        #expect(switched == 0)
    }

    @Test func sync_tokensOfAnotherSavedAccount_areNotSavedUnderThisOne() async throws {
        try await store.upsert(SavedAccount(login: a, savedAt: now))
        try await store.upsert(SavedAccount(login: b, savedAt: now))
        // b's tokens under a's name: a half-finished switch, or the CLI caught between writing its item and its config
        signInCli(AccountLogin(secure: b.secure, account: a.account))

        await make().sync()

        #expect(Logins.accessToken(try await store.find(a.key)?.login) == "access-a-1")
    }

    @Test func addAccount_freshLoginOfTheActiveAccountThatCantBeWritten_keepsStoreAndCliInStep() async throws {
        signInCli(a)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        var busy = cli // a busy session rewrites ~/.claude.json every time: the switch gives up after 3 attempts
        busy.beforeReplace = { url in
            let n = calls.withLock { $0 += 1; return $0 }
            let handle = try! FileHandle(forWritingTo: url)
            _ = try! handle.seekToEnd()
            try! handle.write(contentsOf: Data(String(repeating: " ", count: n).utf8))
            try! handle.close()
        }
        let switcher = make(cli: busy)
        await switcher.sync()
        login = logsIn(Logins.make("a", "a@example.com", token: "9"))

        await #expect(throws: AccountError.self) { try await switcher.addAccount(email: "a@example.com") }

        #expect(Logins.accessToken(await cliNow()) == "access-a-1")
        #expect(Logins.accessToken(try await store.all().first?.login) == "access-a-1")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macos && swift test`
Expected: build FAILS with `cannot find 'AccountSwitcher' in scope`.

- [ ] **Step 3: Implement**

Create `macos/Sources/ClaudeUsageBarCore/AccountSwitcher.swift`:

```swift
import Foundation

public enum AccountError: Error, Equatable {
    case claudeNotFound
    case loginFailed(String)
    case writeFailed(String)
}

/// Saved accounts ↔ Claude Code's login: captures the active login, switches to a saved one, adds new ones.
/// `cliLock` is shared with the token renewer: a `claude -p` refresh must never write the old account's tokens over
/// a login that was just switched to.
@MainActor public final class AccountSwitcher {
    let cli: CliLogin
    let store: AccountStore
    let cliLock: AsyncLock
    let loginRoot: URL
    let loginFor: (URL) -> CliLogin
    let runLogin: (String?, URL) async throws -> Bool
    let time: any TimeSource
    private var lastSeen: AccountKey? // the last account read from Claude Code; nil until the first read

    public private(set) var active: AccountLogin?
    public private(set) var isLoginRunning = false
    /// Claude Code now has another login (or a fresh one); everything shown for the previous one is stale.
    public var onSwitched: (() -> Void)?

    public init(cli: CliLogin, store: AccountStore, cliLock: AsyncLock, loginRoot: URL,
                loginFor: @escaping (URL) -> CliLogin, runLogin: @escaping (String?, URL) async throws -> Bool, time: any TimeSource) {
        self.cli = cli
        self.store = store
        self.cliLock = cliLock
        self.loginRoot = loginRoot
        self.loginFor = loginFor
        self.runLogin = runLogin
        self.time = time
    }

    public func accounts() async throws -> [SavedAccount] { try await store.all() }

    /// Reads the active login and saves it when it is new or changed: token rotation, `/login` by hand.
    /// Another account signed in by hand raises onSwitched, like a switch from the menu.
    public func sync() async {
        guard let current = await cli.readCurrent() else {
            active = nil
            return
        }
        active = current
        let switchedByHand = lastSeen.map { $0 != current.key } ?? false
        lastSeen = current.key
        await save(current)
        if switchedByHand {
            Log.write("accounts: signed in by hand as \(current)")
            onSwitched?()
        }
    }

    private func save(_ login: AccountLogin) async {
        do {
            let all = try await store.all()
            if let saved = all.first(where: { $0.key == login.key }), saved.login == login { return }
            // another saved account's refresh token under this name is a half-written pair, not a new login: saving it
            // would replace this account's real tokens
            if let token = login.refreshToken, all.contains(where: { $0.key != login.key && $0.login.refreshToken == token }) {
                Log.write("accounts: \(login) carries another account's tokens, not saved")
                return
            }
            try await store.upsert(SavedAccount(login: login, savedAt: time.now()))
            Log.write("accounts: saved \(login)")
        } catch {
            Log.write("accounts: can't save \(login): \(error)")
        }
    }

    public func switchTo(_ key: AccountKey) async throws {
        await cliLock.lock()
        defer { cliLock.unlock() }
        await sync() // the account being left may have rotated its tokens since the last sync
        if active?.key == key { return }
        guard let target = try await store.find(key) else { throw AccountError.writeFailed("no saved account \(key)") }
        try await apply(target.login)
    }

    /// Signs in with `claude auth login` in a throwaway CLAUDE_CONFIG_DIR, so the current login is never signed out,
    /// then saves the new login and switches to it. `email` pre-fills the login page (for "sign in again").
    public func addAccount(email: String?) async throws {
        if isLoginRunning { return }
        isLoginRunning = true
        let dir = loginRoot.appending(path: "login-\(UUID().uuidString.lowercased())")
        do {
            try await addAccount(email: email, in: dir)
        } catch {
            await removeLoginDir(dir) // it holds live tokens
            isLoginRunning = false
            throw error
        }
        await removeLoginDir(dir)
        isLoginRunning = false
    }

    private func addAccount(email: String?, in dir: URL) async throws {
        await removeLeftoverLoginDirs()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard try await runLogin(email, dir) else { throw AccountError.loginFailed("claude auth login failed or was closed") }
        guard let login = await loginFor(dir).readCurrent() else { throw AccountError.loginFailed("claude auth login left no login") }
        await cliLock.lock()
        defer { cliLock.unlock() }
        await sync() // after the login, not before: the account being left may have rotated its tokens meanwhile
        let saved = SavedAccount(login: login, savedAt: time.now())
        if active?.key == login.key {
            // a fresh login of the active account replaces its dead tokens; store it only once Claude Code has it,
            // or the next sync would put the dead tokens back over it anyway
            try await apply(login)
            try await store.upsert(saved)
        } else {
            try await store.upsert(saved)
            try await apply(login)
        }
    }

    /// Forgets a saved account. No server call: its login stays valid wherever else it is used.
    public func remove(_ key: AccountKey) async throws {
        await sync()
        if active?.key == key { throw AccountError.writeFailed("the active account can't be removed") }
        try await store.remove(key)
        Log.write("accounts: removed \(key)")
    }

    private func apply(_ login: AccountLogin) async throws {
        do { try await cli.write(login) }
        catch { throw AccountError.writeFailed("\(error)") }
        active = await cli.readCurrent()
        lastSeen = active?.key ?? lastSeen
        Log.write("accounts: switched to \(login)")
        onSwitched?()
        if active?.key != login.key {
            throw AccountError.writeFailed("Claude Code's login reads back as \(active.map { "\($0)" } ?? "nothing")")
        }
    }

    // a login dir left by a crash or a kill still holds tokens, in the dir and in its own Keychain item;
    // only one login runs at a time, so none is in use
    private func removeLeftoverLoginDirs() async {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: loginRoot.path)) ?? []
        for name in names where name.hasPrefix("login-") {
            await removeLoginDir(loginRoot.appending(path: name))
        }
    }

    private func removeLoginDir(_ dir: URL) async {
        await loginFor(dir).deleteItem()
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        do { try FileManager.default.removeItem(at: dir) }
        catch { Log.write("accounts: can't delete \(dir.lastPathComponent): \(error)") }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd macos && swift test`
Expected: PASS. All 23 `AccountSwitcherTests` pass, along with the earlier suites.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources macos/Tests
git commit -m "feat(macos): switch, add and remove Claude Code accounts" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: `claude auth login` in a Terminal window

**Files:**
- Create: `macos/Sources/ClaudeUsageBarCore/LoginRunner.swift`
- Test: `macos/Tests/ClaudeUsageBarCoreTests/LoginRunnerTests.swift`

**Interfaces:**
- Consumes: `ProcessRunner`, `ProcessRequest`, `SystemProcessRunner`, `AccountError`, `Log`, `TempDir` (Tasks 4, 5 and 12).
- Produces: `struct LoginRunner(claude:hint:openTerminal:pollInterval:startTimeout:)` with `run(email:dir:) async throws -> Bool`, `static script(claude:email:hint:dir:) -> String`, `static terminal(runner:) -> @Sendable (URL) async throws -> Void` and `static readInt(_:) -> Int?`.

The tests run the real script with zsh. A stand-in `claude` records its arguments and environment. The script is started detached (`sh -c '… &'`), the way Terminal starts it, so launchd reaps it and a closed "window" really disappears from the process table.

- [ ] **Step 1: Write the failing tests**

Create `macos/Tests/ClaudeUsageBarCoreTests/LoginRunnerTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeUsageBarCore

struct LoginRunnerTests {
    let temp = TempDir()

    struct NoPid: Error {}

    /// A stand-in for `claude`: records its arguments and environment, then exits with `exitCode` after `delay` s.
    func fakeClaude(exitCode: Int, delay: Double = 0) throws -> URL {
        let url = temp["bin/claude"]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
            #!/bin/sh
            echo "$@" > "$CLAUDE_CONFIG_DIR/args.txt"
            env > "$CLAUDE_CONFIG_DIR/env.txt"
            sleep \(delay)
            exit \(exitCode)
            """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Starts the script the way Terminal would: detached (reaped by launchd), with Claude variables around.
    static let zsh: @Sendable (URL) async throws -> Void = { script in
        var env = ProcessInfo.processInfo.environment
        env["ANTHROPIC_API_KEY"] = "sk-test"
        env["CLAUDE_CODE_ENTRYPOINT"] = "cli"
        _ = try await SystemProcessRunner().run(ProcessRequest(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "/bin/zsh \"$0\" >/dev/null 2>&1 &", script.path],
            environment: env, captureOutput: false))
    }

    func loginDir(_ name: String) throws -> URL {
        let dir = temp[name]
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func waitForPid(in dir: URL) async throws -> pid_t {
        for _ in 0..<250 {
            if let pid = LoginRunner.readInt(dir.appending(path: "pid")) { return pid_t(pid) }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NoPid()
    }

    @Test func script_quotesEverything_andDropsAnEmailThatIsntPlain() {
        let script = LoginRunner.script(claude: URL(fileURLWithPath: "/Users/O'Brien/.local/bin/claude"), email: "a@b.pl; rm -rf ~",
                                        hint: "It's fine", dir: URL(fileURLWithPath: "/tmp/x y"))
        #expect(script.contains("'/Users/O'\\''Brien/.local/bin/claude' auth login\n"))
        #expect(script.contains("export CLAUDE_CONFIG_DIR='/tmp/x y'\n"))
        #expect(script.contains("print -r -- 'It'\\''s fine'\n"))
        #expect(!script.contains("rm -rf"))
    }

    @Test func script_passesAPlainEmail() {
        let script = LoginRunner.script(claude: URL(fileURLWithPath: "/c"), email: "jan.k+1@firma.pl", hint: "h", dir: URL(fileURLWithPath: "/d"))
        #expect(script.contains("'/c' auth login --email 'jan.k+1@firma.pl'\n"))
    }

    @Test func run_successfulLogin_returnsTrue_withACleanEnvironment() async throws {
        let dir = try loginDir("login-1")
        let runner = LoginRunner(claude: try fakeClaude(exitCode: 0), hint: "Sign in", openTerminal: Self.zsh, pollInterval: .milliseconds(20))

        #expect(try await runner.run(email: "a@b.pl", dir: dir))

        let env = try String(contentsOf: dir.appending(path: "env.txt"), encoding: .utf8)
        #expect(env.contains("CLAUDE_CONFIG_DIR=\(dir.path)\n"))
        #expect(!env.contains("ANTHROPIC_API_KEY"))
        #expect(!env.contains("CLAUDE_CODE_ENTRYPOINT"))
        #expect(try String(contentsOf: dir.appending(path: "args.txt"), encoding: .utf8) == "auth login --email a@b.pl\n")
    }

    @Test func run_failedLogin_returnsFalse() async throws {
        let runner = LoginRunner(claude: try fakeClaude(exitCode: 1), hint: "x", openTerminal: Self.zsh, pollInterval: .milliseconds(20))
        #expect(try await runner.run(email: nil, dir: try loginDir("login-2")) == false)
    }

    @Test func run_windowClosed_returnsFalse() async throws {
        let dir = try loginDir("login-3")
        let runner = LoginRunner(claude: try fakeClaude(exitCode: 0, delay: 3), hint: "x", openTerminal: Self.zsh, pollInterval: .milliseconds(20))
        let running = Task { try await runner.run(email: nil, dir: dir) }

        kill(try await waitForPid(in: dir), SIGHUP) // what closing the Terminal window does

        #expect(try await running.value == false)
    }

    @Test func run_scriptNeverStarts_returnsFalse() async throws {
        let runner = LoginRunner(claude: URL(fileURLWithPath: "/usr/bin/false"), hint: "x", openTerminal: { _ in },
                                 pollInterval: .milliseconds(20), startTimeout: 0.2)
        #expect(try await runner.run(email: nil, dir: try loginDir("login-4")) == false)
    }

    @Test func run_cancelled_closesTheScriptAndThrows() async throws {
        let dir = try loginDir("login-5")
        let runner = LoginRunner(claude: try fakeClaude(exitCode: 0, delay: 3), hint: "x", openTerminal: Self.zsh, pollInterval: .milliseconds(20))
        let running = Task { try await runner.run(email: nil, dir: dir) }
        let pid = try await waitForPid(in: dir)

        running.cancel()

        await #expect(throws: CancellationError.self) { _ = try await running.value }
        try await Task.sleep(for: .milliseconds(300))
        #expect(kill(pid, 0) != 0)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd macos && swift test`
Expected: build FAILS with `cannot find 'LoginRunner' in scope`.

- [ ] **Step 3: Implement**

Create `macos/Sources/ClaudeUsageBarCore/LoginRunner.swift`:

```swift
import Foundation

/// Runs `claude auth login` for a new account in its own Terminal window, isolated with CLAUDE_CONFIG_DIR=<dir>, so
/// the user's current login is never touched. The script reports back through files in <dir>: `pid`, `exit-code`.
public struct LoginRunner: Sendable {
    let claude: URL
    let hint: String
    let openTerminal: @Sendable (URL) async throws -> Void
    let pollInterval: Duration
    let startTimeout: TimeInterval

    public init(claude: URL, hint: String, openTerminal: @escaping @Sendable (URL) async throws -> Void,
                pollInterval: Duration = .seconds(1), startTimeout: TimeInterval = 60) {
        self.claude = claude
        self.hint = hint
        self.openTerminal = openTerminal
        self.pollInterval = pollInterval
        self.startTimeout = startTimeout
    }

    /// Opens the script with Terminal: no Automation permission needed, unlike AppleScript.
    public static func terminal(runner: any ProcessRunner) -> @Sendable (URL) async throws -> Void {
        { script in
            let result = try await runner.run(ProcessRequest(executable: URL(fileURLWithPath: "/usr/bin/open"), arguments: ["-a", "Terminal", script.path]))
            if result.exitCode != 0 { throw AccountError.loginFailed("open -a Terminal exited with \(result.exitCode)") }
        }
    }

    // anything else is not passed on; the user then types the address in the browser
    static func isPlainEmail(_ email: String) -> Bool {
        email.wholeMatch(of: #/[A-Za-z0-9._+\-]+@[A-Za-z0-9.\-]+/#) != nil
    }

    /// zsh single quotes: nothing inside is interpreted.
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public static func script(claude: URL, email: String?, hint: String, dir: URL) -> String {
        var login = "\(quote(claude.path)) auth login"
        if let email, isPlainEmail(email) { login += " --email \(quote(email))" }
        return """
            #!/bin/zsh
            echo $$ > \(quote(dir.path + "/pid"))
            print -r -- \(quote(hint))
            print
            for name in $(env | cut -d= -f1 | grep -iE '^(CLAUDE|ANTHROPIC)'); do unset "$name"; done
            export CLAUDE_CONFIG_DIR=\(quote(dir.path))
            \(login)
            echo $? > \(quote(dir.path + "/exit-code"))
            """
    }

    /// True when the login finished; false when it failed or its window was closed. Cancelling closes it.
    public func run(email: String?, dir: URL) async throws -> Bool {
        let script = dir.appending(path: "login.command")
        try Self.script(claude: claude, email: email, hint: hint, dir: dir).write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        try await openTerminal(script)
        let started = Date()
        while true {
            if let code = Self.readInt(dir.appending(path: "exit-code")) {
                Log.write("login: claude auth login exited with \(code)")
                return code == 0
            }
            if let pid = Self.readInt(dir.appending(path: "pid")) {
                if kill(pid_t(pid), 0) != 0 && errno == ESRCH {
                    // gone without an exit code: the window was closed (look once more: it may have just finished)
                    Log.write("login: the Terminal window was closed")
                    return Self.readInt(dir.appending(path: "exit-code")) == 0
                }
            } else if Date().timeIntervalSince(started) > startTimeout {
                Log.write("login: the Terminal script never started")
                return false
            }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                if let pid = Self.readInt(dir.appending(path: "pid")) { kill(pid_t(pid), SIGHUP) }
                throw error
            }
        }
    }

    public static func readInt(_ url: URL) -> Int? {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd macos && swift test`
Expected: PASS. All 7 `LoginRunnerTests` pass, and the whole suite is green.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources macos/Tests
git commit -m "feat(macos): run claude auth login for a new account in Terminal" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 14: Menu bar readout, app shell and packaging

**Files:**
- Modify: `macos/Package.swift` (adds the executable target)
- Create: `macos/Sources/ClaudeUsageBar/main.swift`, `AppDelegate.swift`, `AppController.swift`, `Theme.swift`, `Spark.swift`, `BarView.swift`, `StatusItemController.swift`, `MenuItems.swift`
- Create: `macos/Resources/Info.plist`, `macos/tools/package.sh`

**Interfaces:**
- Consumes: everything in `ClaudeUsageBarCore` up to Task 8 (`UsageService`, `KeychainCredentialStore`, `HTTPUsageAPI`, `CliTokenRenewer`, `SecurityCLI`, `SystemProcessRunner`, `AsyncLock`, `Texts`, `Format`, `DisplayText`, `AppPaths`, `Log`).
- Produces:
  - in the app target: `Palette` (`.dark`, `.light`, `.current(_:)`, `severity(_:)`, `number(_:)`), `Spark.draw(center:radius:color:flipped:)`, `Spark.image(size:color:)`, `Spark.renderIconset(to:)`, `BarView(texts:)` (`state`, `tick()`), `StatusItemController(texts:)` (`item`, `bar`, `onLeftClick`, `onRightClick`, `showMenu(_:)`), `ClosureMenuItem(_:checked:enabled:handler:)` and `AppController` (`start()`, `refreshNow()`);
  - `tools/package.sh <version> [out-dir]`, which writes `ClaudeUsageBar.app` and `ClaudeUsageBar-<version>-macos.zip`.

There are no unit tests for AppKit drawing: the wording and the decisions behind it are tested in Core (Task 8). This task is verified by building, packaging, launching and taking a screenshot of the menu bar. Launching reads the real Claude Code login with `security` (read-only) and calls the usage endpoint, which is exactly what the app is for.

- [ ] **Step 1: Add the executable target**

Replace `macos/Package.swift` with:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeUsageBar",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "ClaudeUsageBarCore"),
        .executableTarget(name: "ClaudeUsageBar", dependencies: ["ClaudeUsageBarCore"]),
        .testTarget(name: "ClaudeUsageBarCoreTests", dependencies: ["ClaudeUsageBarCore"]),
    ]
)
```

- [ ] **Step 2: Colours and the spark**

Create `macos/Sources/ClaudeUsageBar/Theme.swift`:

```swift
import AppKit
import ClaudeUsageBarCore

/// Colours for a light or dark menu bar and popover (the Windows palettes).
@MainActor struct Palette {
    let text, muted, track, ok, warn, critical, clay: NSColor

    static let dark = Palette(
        text: .white, muted: NSColor(white: 1, alpha: 0.65), track: NSColor(white: 1, alpha: 0.22),
        ok: NSColor(srgbRed: 108 / 255, green: 203 / 255, blue: 95 / 255, alpha: 1),
        warn: NSColor(srgbRed: 1, green: 185 / 255, blue: 0, alpha: 1),
        critical: NSColor(srgbRed: 1, green: 107 / 255, blue: 107 / 255, alpha: 1),
        clay: NSColor(srgbRed: 217 / 255, green: 119 / 255, blue: 87 / 255, alpha: 1))

    static let light = Palette(
        text: NSColor(white: 0.1, alpha: 1), muted: NSColor(white: 0, alpha: 0.63), track: NSColor(white: 0, alpha: 0.16),
        ok: NSColor(srgbRed: 15 / 255, green: 123 / 255, blue: 15 / 255, alpha: 1),
        warn: NSColor(srgbRed: 157 / 255, green: 93 / 255, blue: 0, alpha: 1),
        critical: NSColor(srgbRed: 196 / 255, green: 43 / 255, blue: 28 / 255, alpha: 1),
        clay: NSColor(srgbRed: 193 / 255, green: 95 / 255, blue: 60 / 255, alpha: 1))

    static func current(_ appearance: NSAppearance) -> Palette {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    }

    func severity(_ used: Double) -> NSColor {
        switch Format.severity(used) {
        case .ok: ok
        case .warn: warn
        case .critical: critical
        }
    }

    // numbers stay neutral for contrast until the limit needs attention
    func number(_ used: Double) -> NSColor { Format.severity(used) == .ok ? text : severity(used) }
}
```

Create `macos/Sources/ClaudeUsageBar/Spark.swift`:

```swift
import AppKit

/// The Claude spark: 12 rounded rays of uneven length, clockwise from 12 o'clock (as on Windows).
enum Spark {
    static let rayLength: [CGFloat] = [1.0, 0.74, 0.9, 0.8, 1.0, 0.72, 0.94, 0.78, 0.98, 0.76, 0.88, 0.82]

    /// Draws into the current graphics context; `flipped` for views whose y axis points down.
    static func draw(center: CGPoint, radius r: CGFloat, color: NSColor, flipped: Bool) {
        let path = NSBezierPath()
        path.lineWidth = r * 0.24
        path.lineCapStyle = .round
        let down: CGFloat = flipped ? 1 : -1 // clockwise from the top in both coordinate systems
        for (index, length) in rayLength.enumerated() {
            let angle = CGFloat(-90 + index * 30) * .pi / 180
            let r0 = r * 0.22, r1 = r * length
            path.move(to: CGPoint(x: center.x + cos(angle) * r0, y: center.y + down * sin(angle) * r0))
            path.line(to: CGPoint(x: center.x + cos(angle) * r1, y: center.y + down * sin(angle) * r1))
        }
        color.setStroke()
        path.stroke()
    }

    /// The spark as an image, for the popover header.
    static func image(size: CGFloat, color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            draw(center: CGPoint(x: rect.midX, y: rect.midY), radius: size / 2 * 0.95, color: color, flipped: true)
            return true
        }
    }

    /// AppIcon.iconset for iconutil: the spark on a rounded light tile, in every size macOS asks for.
    static func renderIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                let side = CGFloat(pixels)
                let tile = NSRect(x: side * 0.1, y: side * 0.1, width: side * 0.8, height: side * 0.8)
                NSColor(srgbRed: 0.98, green: 0.96, blue: 0.93, alpha: 1).setFill()
                NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.22, yRadius: tile.width * 0.22).fill()
                draw(center: CGPoint(x: side / 2, y: side / 2), radius: tile.width * 0.36,
                     color: NSColor(srgbRed: 217 / 255, green: 119 / 255, blue: 87 / 255, alpha: 1), flipped: false)
                NSGraphicsContext.restoreGraphicsState()
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                guard let png = rep.representation(using: .png, properties: [:]) else { continue }
                try png.write(to: directory.appending(path: name))
            }
        }
    }
}
```

- [ ] **Step 3: The readout**

Create `macos/Sources/ClaudeUsageBar/BarView.swift`:

```swift
import AppKit
import ClaudeUsageBarCore

/// The two-row menu bar readout: "✻ 5h ▰▱ 38% 3h 49m" over "W ▰▱ 24% 6d 17h" (the Windows BarRenderer layout).
@MainActor final class BarView: NSView {
    static let width: CGFloat = 112
    static let label = NSFont.systemFont(ofSize: 9.5)
    static let number = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)

    var state = UsageState.initial {
        didSet { tick() }
    }
    let texts: Texts

    init(texts: Texts) {
        self.texts = texts
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: NSStatusBar.system.thickness))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    // clicks go to the status bar button underneath
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidChangeEffectiveAppearance() { needsDisplay = true }

    /// Redraws: countdowns move on, data turns grey when it gets old.
    func tick() {
        needsDisplay = true
        setAccessibilityLabel(DisplayText.accessibility(state, now: Date(), texts))
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = Palette.current(effectiveAppearance)
        let middle = bounds.midY
        Spark.draw(center: CGPoint(x: 9, y: middle), radius: 6.5, color: palette.clay, flipped: true)
        if state.status == .needsLogin {
            text(texts.bar.signIn, font: .systemFont(ofSize: 12), color: palette.muted, x: 20, baseline: middle + 4)
            return
        }
        let now = Date()
        let stale = DisplayText.isStale(state, now: now)
        row(texts.bar.session, state.snapshot?.session, baseline: middle - 1.5, palette: palette, stale: stale, now: now)
        row(texts.bar.week, state.snapshot?.weekly, baseline: middle + 9, palette: palette, stale: stale, now: now)
    }

    private func row(_ name: String, _ limit: LimitInfo?, baseline: CGFloat, palette: Palette, stale: Bool, now: Date) {
        let x: CGFloat = 20
        text(name, font: Self.label, color: palette.muted, x: x, baseline: baseline)
        let barX = x + 12, barWidth: CGFloat = 24, barHeight: CGFloat = 3.5
        let barY = baseline - 3.5 - barHeight / 2
        let numberRight = barX + barWidth + 25
        pill(palette.track, x: barX, y: barY, width: barWidth, height: barHeight)
        guard let limit else {
            text("…", font: Self.number, color: palette.muted, right: numberRight, baseline: baseline)
            return
        }
        let used = min(max(limit.usedPercent, 0), 100)
        pill(stale ? palette.muted : palette.severity(limit.usedPercent), x: barX, y: barY,
             width: max(barHeight, barWidth * used / 100), height: barHeight)
        text(Format.percent(limit.usedPercent), font: Self.number, color: stale ? palette.muted : palette.number(limit.usedPercent),
             right: numberRight, baseline: baseline)
        if let reset = limit.resetsAt {
            text(Format.countdownShort(reset.timeIntervalSince(now), texts), font: Self.label, color: palette.muted, x: numberRight + 3, baseline: baseline)
        }
    }

    private func text(_ string: String, font: NSFont, color: NSColor, x: CGFloat, baseline: CGFloat) {
        (string as NSString).draw(at: NSPoint(x: x, y: baseline - font.ascender), withAttributes: [.font: font, .foregroundColor: color])
    }

    private func text(_ string: String, font: NSFont, color: NSColor, right: CGFloat, baseline: CGFloat) {
        let width = (string as NSString).size(withAttributes: [.font: font]).width
        text(string, font: font, color: color, x: right - width, baseline: baseline)
    }

    private func pill(_ color: NSColor, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: height / 2, yRadius: height / 2).fill()
    }
}
```

Create `macos/Sources/ClaudeUsageBar/StatusItemController.swift`:

```swift
import AppKit
import ClaudeUsageBarCore

/// The menu bar item: the readout is the button's content; left click → popover, right click or ctrl+click → menu.
@MainActor final class StatusItemController: NSObject {
    let item = NSStatusBar.system.statusItem(withLength: BarView.width)
    let bar: BarView
    var onLeftClick: (() -> Void)?
    var onRightClick: (() -> Void)?

    init(texts: Texts) {
        bar = BarView(texts: texts)
        super.init()
        guard let button = item.button else { return }
        bar.frame = NSRect(x: 0, y: 0, width: BarView.width, height: NSStatusBar.system.thickness)
        bar.autoresizingMask = [.width, .height]
        button.addSubview(bar)
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            onRightClick?()
        } else {
            onLeftClick?()
        }
    }

    /// Shows `menu` attached to the item, the way a status item's own menu opens.
    func showMenu(_ menu: NSMenu) {
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }
}
```

Create `macos/Sources/ClaudeUsageBar/MenuItems.swift`:

```swift
import AppKit

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() { handler() }
}
```

- [ ] **Step 4: Wiring, refresh loop and start-up**

Create `macos/Sources/ClaudeUsageBar/AppController.swift`:

```swift
import AppKit
import ClaudeUsageBarCore

/// Wires the service, the readout, the menu and the timers together.
@MainActor final class AppController {
    let paths: AppPaths
    let texts: Texts
    let service: UsageService
    let status: StatusItemController
    private var refreshTimer: Timer?
    private var tickTimer: Timer?

    init() {
        // locals first: a class can't read its own properties before they are all set
        let paths = AppPaths.standard()
        Log.configure(directory: paths.logs)
        let texts = Self.loadTexts()
        let runner = SystemProcessRunner()
        let keychain = SecurityCLI(runner: runner)
        self.paths = paths
        self.texts = texts
        service = UsageService(
            credentials: KeychainCredentialStore(keychain: keychain),
            api: HTTPUsageAPI(version: Self.version),
            renewer: CliTokenRenewer.standard(runner: runner, workDir: paths.renewDir, cliLock: AsyncLock()),
            time: SystemTime())
        status = StatusItemController(texts: texts)
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    /// Translations ship inside the app; a missing file is a packaging bug, found at the first launch.
    static func loadTexts() -> Texts {
        let directory = Bundle.main.resourceURL!.appending(path: "localization")
        let code = Texts.languageCode(preferred: Locale.preferredLanguages, available: Texts.available(in: directory))
        do { return try Texts.load(code, from: directory) }
        catch { fatalError("translations missing from \(directory.path): \(error)") }
    }

    func start() {
        Log.write("start \(Self.version)")
        service.onChange = { [weak self] state in self?.status.bar.state = state }
        status.onRightClick = { [weak self] in self?.showMenu() }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
        refreshNow()
    }

    func tick() { status.bar.tick() }

    func refreshNow() {
        refreshTimer?.invalidate()
        Task {
            await service.refresh()
            scheduleNextRefresh()
        }
    }

    private func scheduleNextRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: max(1, service.nextDelay()), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
    }

    func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(texts.menu.refreshNow) { [weak self] in self?.refreshNow() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(texts.macos.menu.quit) { NSApp.terminate(nil) })
        status.showMenu(menu)
    }
}
```

Create `macos/Sources/ClaudeUsageBar/AppDelegate.swift`:

```swift
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            // already running, e.g. started at login and again by hand
            NSApp.terminate(nil)
            return
        }
        let controller = AppController()
        self.controller = controller
        controller.start()
    }
}
```

Create `macos/Sources/ClaudeUsageBar/main.swift`:

```swift
import AppKit

// tools/package.sh renders the app icon with the same spark code as the menu bar
if let index = CommandLine.arguments.firstIndex(of: "--render-icon"), index + 1 < CommandLine.arguments.count {
    do {
        try Spark.renderIconset(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("render-icon: \(error)\n".utf8))
        exit(1)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
```

- [ ] **Step 5: Bundle template and packaging script**

Create `macos/Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>io.github.liskeee.ClaudeUsageBar</string>
    <key>CFBundleName</key>
    <string>ClaudeUsageBar</string>
    <key>CFBundleDisplayName</key>
    <string>ClaudeUsageBar</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeUsageBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>__VERSION__</string>
    <key>CFBundleVersion</key>
    <string>__VERSION__</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Claude usage limits in the menu bar</string>
</dict>
</plist>
```

Create `macos/tools/package.sh`:

```bash
#!/bin/zsh
# Builds a universal ClaudeUsageBar.app (ad-hoc signed) and zips it:
#   tools/package.sh <version> [out-dir]   →   <out-dir>/ClaudeUsageBar.app, <out-dir>/ClaudeUsageBar-<version>-macos.zip
set -euo pipefail
version=${1:?usage: tools/package.sh <version> [out-dir]}
macos=${0:A:h:h}
repo=${macos:h}
out=${2:-$macos/dist}
mkdir -p "$out"
out=${out:A}
cd "$macos"

swift build -c release --arch arm64 --arch x86_64
bin=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/ClaudeUsageBar

app="$out/ClaudeUsageBar.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/localization"
cp "$bin" "$app/Contents/MacOS/ClaudeUsageBar"
cp "$repo"/shared/localization/*.json "$app/Contents/Resources/localization/"
sed "s/__VERSION__/$version/g" "$macos/Resources/Info.plist" > "$app/Contents/Info.plist"

iconset=$(mktemp -d)/AppIcon.iconset
"$app/Contents/MacOS/ClaudeUsageBar" --render-icon "$iconset"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

codesign --force --sign - --timestamp=none "$app"
zip="$out/ClaudeUsageBar-$version-macos.zip"
rm -f "$zip"
ditto -c -k --keepParent "$app" "$zip"
echo "$zip"
```

Then make it executable and ignore its default output folder:

```bash
chmod +x macos/tools/package.sh
printf 'macos/dist/\n' >> .gitignore
```

- [ ] **Step 6: Build, package, launch and look**

```bash
cd macos && swift build && swift test && tools/package.sh 0.0.0-dev
codesign --verify --verbose=2 dist/ClaudeUsageBar.app
lipo -archs dist/ClaudeUsageBar.app/Contents/MacOS/ClaudeUsageBar
open dist/ClaudeUsageBar.app && sleep 8
screencapture -x /tmp/claude-usage-bar-readout.png
tail -5 ~/Library/Logs/ClaudeUsageBar/app.log
```

Expected:
- the build passes and all tests pass;
- `codesign` reports `valid on disk`;
- `lipo` prints `x86_64 arm64`;
- the log shows `start 0.0.0-dev`, then `refresh: ok session=… week=…`;
- the screenshot (open it with the Read tool) shows, at the right end of the menu bar, the spark and two rows, `5h ▰▱ NN% …` and `W ▰▱ NN% …`.

If the screenshot shows only the wallpaper, the terminal lacks Screen Recording permission. Ask the user to look at the menu bar instead.

If a row is clipped at the top or bottom, adjust the two baselines in `BarView.draw` (`middle - 1.5`, `middle + 9`) by ±1 pt and package again. Right-click the item: the menu shows "Refresh now" and "Quit ClaudeUsageBar". Quit it with `osascript -e 'quit app "ClaudeUsageBar"'`.

- [ ] **Step 7: Commit**

```bash
git add .gitignore macos/Package.swift macos/Sources/ClaudeUsageBar macos/Resources macos/tools
git commit -m "feat(macos): two-row menu bar readout, app shell and packaging" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: Details popover

**Files:**
- Create: `macos/Sources/ClaudeUsageBar/DetailsView.swift`
- Replace: `macos/Sources/ClaudeUsageBar/AppController.swift`

**Interfaces:**
- Consumes: `Palette`, `Spark.image`, `StatusItemController` (Task 14); `DisplayText`, `Format`, `UsageState`, `LimitInfo` (Core).
- Produces: `@Observable DetailsModel(texts:)` (`state`, `account`, `now`, `onRefresh`) and `DetailsView(model:)`. `AppController` gains `togglePopover()` and the `--show-popover` launch flag, which opens the popover right away so the screen can be captured.

- [ ] **Step 1: The popover view**

Create `macos/Sources/ClaudeUsageBar/DetailsView.swift`:

```swift
import AppKit
import ClaudeUsageBarCore
import Observation
import SwiftUI

/// What the popover shows; the controller updates it.
@MainActor @Observable final class DetailsModel {
    var state = UsageState.initial
    var account: String?
    var now = Date()
    let texts: Texts
    @ObservationIgnored var onRefresh: () -> Void = {}

    init(texts: Texts) { self.texts = texts }
}

/// The details popover: one block per limit, then a footer with the data's age and a refresh link
/// (the Windows DetailsRenderer layout).
struct DetailsView: View {
    let model: DetailsModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let palette = scheme == .dark ? Palette.dark : Palette.light
        let limits = model.state.snapshot?.limits ?? []
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: Spark.image(size: 15, color: palette.clay))
                Text(DisplayText.heading(model.state)).font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 12)
                if let account = model.account {
                    Text(account).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            .frame(height: 44)
            if limits.isEmpty {
                Text(DisplayText.empty(model.state, model.texts))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(height: 58, alignment: .leading)
            }
            ForEach(Array(limits.enumerated()), id: \.offset) { _, limit in
                LimitBlock(limit: limit, now: model.now, texts: model.texts, palette: palette)
            }
            Divider()
            HStack {
                Text(DisplayText.footer(model.state, now: model.now, model.texts)).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button(model.texts.popup.refresh) { model.onRefresh() }.buttonStyle(.link).font(.system(size: 11))
            }
            .frame(height: 40)
        }
        .padding(.horizontal, 16)
        .frame(width: 300)
    }
}

private struct LimitBlock: View {
    let limit: LimitInfo
    let now: Date
    let texts: Texts
    let palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(Format.limitLabel(limit, texts)).font(.system(size: 12))
                Spacer()
                Text(Format.percent(limit.usedPercent))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color(nsColor: palette.number(limit.usedPercent)))
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(nsColor: palette.track))
                    Capsule().fill(Color(nsColor: palette.severity(limit.usedPercent)))
                        .frame(width: max(6, geometry.size.width * min(max(limit.usedPercent, 0), 100) / 100))
                }
            }
            .frame(height: 6)
            if let reset = limit.resetsAt {
                Text(DisplayText.resetLine(reset, now: now, texts)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .frame(height: 58)
    }
}
```

- [ ] **Step 2: Show it from the readout**

Replace `macos/Sources/ClaudeUsageBar/AppController.swift` with:

```swift
import AppKit
import ClaudeUsageBarCore
import SwiftUI

/// Wires the service, the readout, the popover, the menu and the timers together.
@MainActor final class AppController: NSObject, NSPopoverDelegate {
    let paths: AppPaths
    let texts: Texts
    let service: UsageService
    let status: StatusItemController
    let details: DetailsModel
    let popover = NSPopover()
    private var refreshTimer: Timer?
    private var tickTimer: Timer?

    override init() {
        // locals first: a class can't read its own properties before super.init
        let paths = AppPaths.standard()
        Log.configure(directory: paths.logs)
        let texts = Self.loadTexts()
        let runner = SystemProcessRunner()
        let keychain = SecurityCLI(runner: runner)
        self.paths = paths
        self.texts = texts
        service = UsageService(
            credentials: KeychainCredentialStore(keychain: keychain),
            api: HTTPUsageAPI(version: Self.version),
            renewer: CliTokenRenewer.standard(runner: runner, workDir: paths.renewDir, cliLock: AsyncLock()),
            time: SystemTime())
        status = StatusItemController(texts: texts)
        details = DetailsModel(texts: texts)
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: DetailsView(model: details))
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    /// Translations ship inside the app; a missing file is a packaging bug, found at the first launch.
    static func loadTexts() -> Texts {
        let directory = Bundle.main.resourceURL!.appending(path: "localization")
        let code = Texts.languageCode(preferred: Locale.preferredLanguages, available: Texts.available(in: directory))
        do { return try Texts.load(code, from: directory) }
        catch { fatalError("translations missing from \(directory.path): \(error)") }
    }

    func start() {
        Log.write("start \(Self.version)")
        service.onChange = { [weak self] state in
            self?.status.bar.state = state
            self?.details.state = state
        }
        status.onLeftClick = { [weak self] in self?.togglePopover() }
        status.onRightClick = { [weak self] in self?.showMenu() }
        details.onRefresh = { [weak self] in self?.refreshNow() }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
        refreshNow()
        if CommandLine.arguments.contains("--show-popover") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                togglePopover()
            }
        }
    }

    func tick() {
        status.bar.tick()
        if popover.isShown { details.now = Date() }
    }

    func refreshNow() {
        refreshTimer?.invalidate()
        Task {
            await service.refresh()
            scheduleNextRefresh()
        }
    }

    private func scheduleNextRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: max(1, service.nextDelay()), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
    }

    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = status.item.button else { return }
        details.now = Date()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        NSApp.activate()
    }

    func popoverDidClose(_ notification: Notification) { status.item.button?.highlight(false) }

    func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem(texts.menu.refreshNow) { [weak self] in self?.refreshNow() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(texts.macos.menu.quit) { NSApp.terminate(nil) })
        status.showMenu(menu)
    }
}
```

- [ ] **Step 3: Build, launch with the popover open, and look**

```bash
cd macos && swift build && tools/package.sh 0.0.0-dev
osascript -e 'quit app "ClaudeUsageBar"' 2>/dev/null; sleep 1
open dist/ClaudeUsageBar.app --args --show-popover && sleep 6
screencapture -x /tmp/claude-usage-bar-popover.png
```

Expected: in the screenshot (open it with the Read tool), under the menu bar item there is a 300 pt popover with:
- the heading "Claude <plan>";
- three blocks ("Current session" / "Sesja (5 h)", the week, the per-model week), each with a coloured bar and a reset line;
- the footer "Updated just now" with a "Refresh" link.

Click "Refresh": the footer still says "just now" and the log gets a new `refresh:` line. Quit the app.

- [ ] **Step 4: Commit**

```bash
git add macos/Sources/ClaudeUsageBar
git commit -m "feat(macos): details popover" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 16: Accounts in the menu, start at login, alerts

**Files:**
- Create: `macos/Sources/ClaudeUsageBar/LoginItem.swift`
- Replace: `macos/Sources/ClaudeUsageBar/AppController.swift`, `macos/Sources/ClaudeUsageBar/AppDelegate.swift`

**Interfaces:**
- Consumes: `AccountSwitcher`, `AccountStore`, `AccountsKey`, `CliLogin.standard/forConfigDir`, `LoginRunner`, `ClaudeCLI`, `AccountLabels`, `AccountError` (Core, Tasks 9–13); `ClosureMenuItem`, `DetailsModel` (Tasks 14 and 15).
- Produces:
  - `LoginItem.isEnabled`, `LoginItem.setEnabled(_:)`, `LoginItem.toggle()`;
  - the complete menu:
    - accounts (✓ on the active one; "— sign in again");
    - Add account…;
    - Remove account ▸;
    - Refresh now;
    - Start at login;
    - Quit;
  - first run registers the login item;
  - quitting closes a running add-account Terminal script.

Account actions change the real Claude Code login, so they are exercised with the user in Task 18, not here.

- [ ] **Step 1: Start at login**

Create `macos/Sources/ClaudeUsageBar/LoginItem.swift`:

```swift
import ClaudeUsageBarCore
import ServiceManagement

/// "Start at login": the app itself as a login item (System Settings → General → Login Items).
@MainActor enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func toggle() { setEnabled(!isEnabled) }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.write("login item: \(error)")
        }
    }
}
```

- [ ] **Step 2: Accounts, menu, alerts**

Replace `macos/Sources/ClaudeUsageBar/AppController.swift` with:

```swift
import AppKit
import ClaudeUsageBarCore
import SwiftUI

/// Wires the service, the accounts, the readout, the popover, the menu and the timers together.
@MainActor final class AppController: NSObject, NSPopoverDelegate {
    let paths: AppPaths
    let texts: Texts
    let service: UsageService
    let switcher: AccountSwitcher
    let status: StatusItemController
    let details: DetailsModel
    let popover = NSPopover()
    private var refreshTimer: Timer?
    private var tickTimer: Timer?
    private var syncingForRefresh = false // a hand switch found by the refresh's own sync needs no second refresh

    override init() {
        // locals first: a class can't read its own properties before super.init
        let paths = AppPaths.standard()
        Log.configure(directory: paths.logs)
        let texts = Self.loadTexts()
        let runner = SystemProcessRunner()
        let keychain = SecurityCLI(runner: runner)
        let accountsKey = AccountsKey(keychain: keychain)
        let cliLock = AsyncLock() // shared: a token renewal never runs during a switch
        self.paths = paths
        self.texts = texts
        service = UsageService(
            credentials: KeychainCredentialStore(keychain: keychain),
            api: HTTPUsageAPI(version: Self.version),
            renewer: CliTokenRenewer.standard(runner: runner, workDir: paths.renewDir, cliLock: cliLock),
            time: SystemTime())
        switcher = AccountSwitcher(
            cli: CliLogin.standard(keychain: keychain, paths: paths, sealBackup: { data in try await accountsKey.seal(data) }),
            store: AccountStore(file: paths.accountsFile, key: accountsKey),
            cliLock: cliLock,
            loginRoot: paths.support,
            loginFor: { dir in CliLogin.forConfigDir(dir, keychain: keychain) },
            runLogin: { email, dir in
                guard let claude = ClaudeCLI.findDefault() else { throw AccountError.claudeNotFound }
                let login = LoginRunner(claude: claude, hint: texts.accounts.loginHint, openTerminal: LoginRunner.terminal(runner: runner))
                return try await login.run(email: email, dir: dir)
            },
            time: SystemTime())
        status = StatusItemController(texts: texts)
        details = DetailsModel(texts: texts)
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: DetailsView(model: details))
    }

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    /// Translations ship inside the app; a missing file is a packaging bug, found at the first launch.
    static func loadTexts() -> Texts {
        let directory = Bundle.main.resourceURL!.appending(path: "localization")
        let code = Texts.languageCode(preferred: Locale.preferredLanguages, available: Texts.available(in: directory))
        do { return try Texts.load(code, from: directory) }
        catch { fatalError("translations missing from \(directory.path): \(error)") }
    }

    func start() {
        Log.write("start \(Self.version)")
        firstRun()
        service.onChange = { [weak self] state in
            self?.status.bar.state = state
            self?.details.state = state
        }
        switcher.onSwitched = { [weak self] in
            guard let self else { return }
            service.reset() // the previous account's numbers must never show under the new one
            details.account = switcher.active?.email
            if !syncingForRefresh { refreshNow() }
        }
        status.onLeftClick = { [weak self] in self?.togglePopover() }
        status.onRightClick = { [weak self] in self?.showMenu() }
        details.onRefresh = { [weak self] in self?.refreshNow() }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
        refreshNow()
        if CommandLine.arguments.contains("--show-popover") {
            Task {
                try? await Task.sleep(for: .seconds(3))
                togglePopover()
            }
        }
    }

    /// The first run turns on "Start at login", as the Windows app does with "Start with Windows".
    private func firstRun() {
        guard !FileManager.default.fileExists(atPath: paths.firstRunMarker.path) else { return }
        LoginItem.setEnabled(true)
        try? FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: paths.firstRunMarker.path, contents: Data())
    }

    /// On quit: close a running add-account Terminal script (its login dir is cleaned up on the next add).
    func stop() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.support.path)) ?? []
        for name in names where name.hasPrefix("login-") {
            if let pid = LoginRunner.readInt(paths.support.appending(path: "\(name)/pid")) { kill(pid_t(pid), SIGHUP) }
        }
    }

    func tick() {
        status.bar.tick()
        if popover.isShown { details.now = Date() }
    }

    func refreshNow() {
        refreshTimer?.invalidate()
        Task {
            syncingForRefresh = true
            await switcher.sync()
            syncingForRefresh = false
            details.account = switcher.active?.email
            await service.refresh()
            scheduleNextRefresh()
        }
    }

    private func scheduleNextRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: max(1, service.nextDelay()), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshNow() }
        }
    }

    func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = status.item.button else { return }
        details.now = Date()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        NSApp.activate()
    }

    func popoverDidClose(_ notification: Notification) { status.item.button?.highlight(false) }

    func showMenu() {
        Task {
            await switcher.sync()
            details.account = switcher.active?.email
            status.showMenu(await buildMenu())
        }
    }

    /// Accounts sit at the top of the menu, so switching takes two clicks.
    private func buildMenu() async -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let all: [SavedAccount]
        do { all = AccountLabels.ordered(try await switcher.accounts()) }
        catch {
            Log.write("accounts: can't read the list: \(error)")
            all = []
        }
        let now = Date()
        let activeKey = switcher.active?.key
        for account in all {
            let active = account.key == activeKey
            // the active account also needs a new login when its tokens turned out to be revoked
            let needsSignIn = AccountLabels.needsSignIn(account, now: now) || (active && service.state.status == .needsLogin)
            let title = AccountLabels.menuText(account, among: all, needsSignIn: needsSignIn, texts)
            menu.addItem(ClosureMenuItem(title, checked: active) { [weak self] in
                guard let self else { return }
                if needsSignIn {
                    runAccountAction { try await self.switcher.addAccount(email: account.login.email) }
                } else if !active {
                    runAccountAction { try await self.switcher.switchTo(account.key) }
                }
            })
        }
        menu.addItem(ClosureMenuItem(texts.accounts.add, enabled: !switcher.isLoginRunning) { [weak self] in
            guard let self else { return }
            runAccountAction { try await self.switcher.addAccount(email: nil) }
        })
        let removable = all.filter { $0.key != activeKey }
        if !removable.isEmpty {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for account in removable {
                submenu.addItem(ClosureMenuItem(AccountLabels.label(account, among: all)) { [weak self] in
                    self?.confirmRemove(account, among: all)
                })
            }
            let remove = NSMenuItem(title: texts.accounts.remove, action: nil, keyEquivalent: "")
            remove.submenu = submenu
            menu.addItem(remove)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(texts.menu.refreshNow) { [weak self] in self?.refreshNow() })
        menu.addItem(ClosureMenuItem(texts.macos.menu.startAtLogin, checked: LoginItem.isEnabled) { LoginItem.toggle() })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(texts.macos.menu.quit) { NSApp.terminate(nil) })
        return menu
    }

    /// Runs an account action from the menu; a failure is explained in an alert (nothing was changed).
    private func runAccountAction(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch is CancellationError {
                // the app is quitting
            } catch let error as AccountError {
                Log.write("accounts: \(error)")
                let text = switch error {
                case .claudeNotFound: texts.macos.accounts.claudeNotFound
                case .loginFailed: texts.accounts.loginFailed
                case .writeFailed: texts.accounts.writeFailed
                }
                showError(text)
            } catch {
                Log.write("accounts: \(error)")
                showError(texts.accounts.writeFailed)
            }
        }
    }

    private func confirmRemove(_ account: SavedAccount, among all: [SavedAccount]) {
        let alert = NSAlert()
        alert.messageText = Texts.fill(texts.accounts.removeConfirm, ("account", AccountLabels.label(account, among: all)))
        alert.addButton(withTitle: texts.macos.dialogs.remove)
        alert.addButton(withTitle: texts.macos.dialogs.cancel)
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            do { try await switcher.remove(account.key) }
            catch { Log.write("accounts: remove failed: \(error)") }
        }
    }

    private func showError(_ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ClaudeUsageBar"
        alert.informativeText = text
        alert.addButton(withTitle: texts.macos.dialogs.ok)
        NSApp.activate()
        alert.runModal()
    }
}
```

Replace `macos/Sources/ClaudeUsageBar/AppDelegate.swift` with:

```swift
import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !others.isEmpty {
            // already running, e.g. started at login and again by hand
            NSApp.terminate(nil)
            return
        }
        let controller = AppController()
        self.controller = controller
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) { controller?.stop() }
}
```

- [ ] **Step 3: Build, launch and look at the menu**

```bash
cd macos && swift build && swift test && tools/package.sh 0.0.0-dev
osascript -e 'quit app "ClaudeUsageBar"' 2>/dev/null; sleep 1
open dist/ClaudeUsageBar.app && sleep 8
tail -5 ~/Library/Logs/ClaudeUsageBar/app.log
```

Expected: the log shows `accounts: saved l***@… …` for the active Claude Code login (the first sync), then `refresh: ok …`. Right-click the item. The menu should show:
- the active account, ticked;
- "Add account…";
- a separator;
- "Refresh now";
- "Start at login", ticked after the first run;
- a separator;
- "Quit ClaudeUsageBar".

Don't click "Add account…" or switch accounts now: that is Task 18, with the user. Quit the app.

- [ ] **Step 4: Commit**

```bash
git add macos/Sources/ClaudeUsageBar
git commit -m "feat(macos): accounts in the menu, start at login, error alerts" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 17: One workflow for both apps, READMEs

**Files:**
- Replace: `.github/workflows/build.yml`, `README.md`
- Create: `windows/README.md`, `macos/README.md`

**Interfaces:**
- Consumes: `windows/tools/next-version.ps1`, `windows/tools/package.ps1` (Task 1), `macos/tools/package.sh` (Task 14).
- Produces: GitHub Releases `v<major>.<minor>.<n>` containing `ClaudeUsageBar-<v>-win-x64.zip`, `ClaudeUsageBar-<v>-win-x64-self-contained.zip`, `ClaudeUsageBar-<v>-macos.zip` and `SHA256SUMS.txt`.

- [ ] **Step 1: The workflow**

Replace `.github/workflows/build.yml` with:

```yaml
name: Build

on:
  push:
    branches: [main]
    paths-ignore: ['**.md']
  pull_request:
    branches: [main]
    paths-ignore: ['**.md']
  workflow_dispatch:

# one run per branch at a time: each release must see the previous release's tag
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

permissions:
  contents: read

jobs:
  version:
    runs-on: ubuntu-latest
    outputs:
      version: ${{ steps.version.outputs.version }}
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 0 # tags, for the next version number

      - name: Version
        id: version
        shell: pwsh
        run: |
          $version = ./windows/tools/next-version.ps1
          "version=$version" >> $env:GITHUB_OUTPUT
          "Version: $version"

  build-windows:
    needs: version
    runs-on: windows-latest
    defaults:
      run:
        working-directory: windows
    steps:
      - uses: actions/checkout@v7

      - uses: actions/setup-dotnet@v6
        with:
          dotnet-version: 9.0.x

      - name: Test
        run: dotnet test ClaudeUsageBar.sln -c Release --nologo

      - name: Package
        run: ./tools/package.ps1 -Version ${{ needs.version.outputs.version }} -Out ../dist

      - uses: actions/upload-artifact@v7
        with:
          name: ClaudeUsageBar-${{ needs.version.outputs.version }}-windows
          path: dist/*.zip
          if-no-files-found: error

  build-macos:
    needs: version
    runs-on: macos-latest
    defaults:
      run:
        working-directory: macos
    steps:
      - uses: actions/checkout@v7

      - name: Toolchain
        run: swift --version

      - name: Test
        run: swift test

      - name: Package
        run: tools/package.sh ${{ needs.version.outputs.version }} ../dist

      - uses: actions/upload-artifact@v7
        with:
          name: ClaudeUsageBar-${{ needs.version.outputs.version }}-macos
          path: dist/*.zip
          if-no-files-found: error

  release:
    needs: [version, build-windows, build-macos]
    if: github.ref == 'refs/heads/main' && github.event_name != 'pull_request'
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/download-artifact@v8
        with:
          pattern: ClaudeUsageBar-${{ needs.version.outputs.version }}-*
          merge-multiple: true
          path: dist

      - name: Checksums
        working-directory: dist
        run: sha256sum *.zip > SHA256SUMS.txt

      - name: Release
        env:
          GH_TOKEN: ${{ github.token }}
          TAG: v${{ needs.version.outputs.version }}
        run: >
          gh release create "$TAG" dist/*
          --repo "$GITHUB_REPOSITORY"
          --target "$GITHUB_SHA"
          --title "ClaudeUsageBar $TAG"
          --generate-notes
```

- [ ] **Step 2: Check the workflow syntax**

```bash
ruby -ryaml -e 'y = YAML.load_file(".github/workflows/build.yml"); puts y["jobs"].keys.join(" ")'
```

Expected: `version build-windows build-macos release`. If `ruby` is missing, use `python3 -c "import yaml"` if PyYAML is installed; otherwise rely on CI in Task 18.

- [ ] **Step 3: READMEs**

Run `git mv README.md windows/README.md`, then edit `windows/README.md`:
- Title: `# ClaudeUsageBar for Windows`.
- Remove the `[![Build]…]` badge line and the whole `## Releases` section (both move to the root README).
- Under `## Languages`, change "Translations live in `src/ClaudeUsageBar/Localization/<code>.json` (embedded in the exe)" to "Translations live in `shared/localization/<code>.json` at the repository root (embedded in the exe, shared with the macOS app)", and add after the paragraph: "Keys under `macos` are used only by the macOS app."
- Under `## Build`, add before the code block: "From the `windows/` folder:".

Create `README.md`:

````markdown
# ClaudeUsageBar

[![Build](https://github.com/liskeee/claude-usage-bar/actions/workflows/build.yml/badge.svg)](https://github.com/liskeee/claude-usage-bar/actions/workflows/build.yml)

Claude usage limits (5-hour session and weekly) always in sight: in the **Windows 11 taskbar** or the **macOS menu bar**.
The numbers match claude.ai → Settings → Usage. Both apps also switch the account Claude Code (`claude`) is signed in with,
from their menu, without a browser.

| | Windows | macOS |
|---|---|---|
| Where | taskbar, next to the tray arrow | menu bar |
| Details | left click | left click |
| Accounts, refresh, autostart, exit | right click | right click (or ctrl+click) |
| Docs | [windows/README.md](windows/README.md) | [macos/README.md](macos/README.md) |

Both need a signed-in Claude Code CLI. When its login expires they renew it with one tiny `claude -p` call
(at most once every 30 min). The usage endpoint is rate limited: they poll every 5 minutes and back off to
10 → 20 → 30 minutes on HTTP 429, keeping the last data on screen.

## Download

[Releases](https://github.com/liskeee/claude-usage-bar/releases/latest):

- `ClaudeUsageBar-<version>-win-x64.zip`: Windows, needs the [.NET 9 Desktop Runtime](https://dotnet.microsoft.com/download/dotnet/9.0).
- `ClaudeUsageBar-<version>-win-x64-self-contained.zip`: Windows, no runtime needed, ~45 MB.
- `ClaudeUsageBar-<version>-macos.zip`: macOS 14 or later, Apple silicon and Intel.

## Repository

```
windows/   .NET 9 / WinForms app, tests, packaging scripts
macos/     Swift package: ClaudeUsageBarCore (logic, tested) and the AppKit app
shared/    translations (localization/<code>.json) and API fixtures used by both
```

## Releases

GitHub Actions ([build.yml](.github/workflows/build.yml)) tests and packages both apps for every pull request and every
push to `main`. A push to `main` also publishes one GitHub Release with all zips, tagged `v<major>.<minor>.<n>`. Major and
minor come from `<Version>` in `windows/src/ClaudeUsageBar/ClaudeUsageBar.csproj`, and `n` counts up from the last tag
(`windows/tools/next-version.ps1`). Pushes that only touch `*.md` files don't build or release.
````

Create `macos/README.md`:

````markdown
# ClaudeUsageBar for macOS

Claude usage limits in the menu bar: `✻ 5h ▰▱ 38% 3h 49m` over `W ▰▱ 24% 6d 17h`. The colours are green below 50 %,
amber up to 80 % and red above that. Data older than 15 minutes turns grey.

- **Left click:** details, with every limit, reset times and "Refresh".
- **Right click** (or ctrl+click): your Claude Code accounts (click one to switch) · Add account… · Remove account ·
  Refresh now · Start at login · Quit.

Requires macOS 14 or later and a signed-in Claude Code CLI (`claude`).

## Install

1. Download `ClaudeUsageBar-<version>-macos.zip` from [Releases](https://github.com/liskeee/claude-usage-bar/releases/latest),
   unzip it and move `ClaudeUsageBar.app` to `/Applications` before the first start (the login item points at that place).
2. The app is signed ad-hoc, not by an Apple Developer ID. The first time, macOS refuses to open it: go to
   System Settings → Privacy & Security and click "Open Anyway" next to ClaudeUsageBar. Or build it yourself (below).

The first run turns on "Start at login" (System Settings → General → Login Items). With many menu bar items, macOS hides
the ones that don't fit next to the notch. If the readout doesn't show, quit some other menu bar apps.

## Accounts

The menu lists every Claude Code account the app has seen; the active one is ticked. Clicking another account switches
Claude Code to it at once, with no browser. `claude auth status` shows the new account and new `claude` processes use it.
Running sessions use it within about 30 seconds, since Claude Code keeps its Keychain read for that long. The readout
shows the new account's limits within seconds.

- **Add account…** opens a Terminal window with `claude auth login` in a separate, temporary Claude Code config, so the
  current login is never signed out. If the browser is signed in to another claude.ai account, copy the link into a
  private window. The new account becomes active.
- An account whose saved login has expired (about 30 days unused) reads "sign in again". Clicking it runs the same login.
- **Remove account** only forgets an inactive account. It is not signed out on the server.
- An account you sign in to by hand (`/login` in Claude Code) is picked up automatically.

On macOS, Claude Code keeps its login in the Keychain (item "Claude Code-credentials") and `~/.claude.json`. Switching
changes only the account's keys in that item (`claudeAiOauth`, `organizationUuid` and a few more), never `mcpOAuth`,
plus `oauthAccount` in `~/.claude.json` and the account caches Claude Code itself drops on logout. Settings, plugins,
MCP servers and history stay shared. The app reaches the Keychain only through `/usr/bin/security`, the same way
Claude Code does, so it never asks for your keychain password.

## Build

```bash
cd macos
swift test
tools/package.sh 1.2.3          # → dist/ClaudeUsageBar.app and dist/ClaudeUsageBar-1.2.3-macos.zip
open dist/ClaudeUsageBar.app
```

Translations come from `shared/localization/<code>.json`. Keys under `macos` are Mac-only. The UI follows the first
preferred system language: Polish when it is Polish, English otherwise.

## Files

- Saved accounts: `~/Library/Application Support/ClaudeUsageBar/accounts.dat`, encrypted (AES-GCM). The key is in the
  Keychain item "ClaudeUsageBar" / "accounts-key".
- Claude Code's login from before the last switch: `~/Library/Application Support/ClaudeUsageBar/backup/`. It holds
  `claude.json` and the Keychain item, encrypted, in `credentials.dat`.
- Log: `~/Library/Logs/ClaudeUsageBar/app.log`. It never contains tokens.

## Uninstall

Right click → untick "Start at login" → Quit, then:

```bash
rm -rf /Applications/ClaudeUsageBar.app ~/Library/Application\ Support/ClaudeUsageBar ~/Library/Logs/ClaudeUsageBar
security delete-generic-password -s ClaudeUsageBar -a accounts-key
```
````

- [ ] **Step 4: Commit**

```bash
git add -A .github README.md windows/README.md macos/README.md
git commit -m "ci: build and release Windows and macOS together; docs: per-platform READMEs" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 18: Check it on this Mac with the user, then the pull request

**Files:** none (fixes found here go in their own commits).

**Interfaces:**
- Consumes: the packaged app (Task 16) and the workflow (Task 17).
- Produces: a verified build and a pull request with green CI for both platforms.

These checks touch the user's real Claude Code login, so the user does them or approves each one. They are the manual checks from the spec.

- [ ] **Step 1: Install the fresh build**

```bash
cd macos && tools/package.sh 0.0.0-dev
osascript -e 'quit app "ClaudeUsageBar"' 2>/dev/null; sleep 1
ditto dist/ClaudeUsageBar.app /Applications/ClaudeUsageBar.app && open /Applications/ClaudeUsageBar.app
```

- [ ] **Step 2: The numbers match claude.ai**

The user opens claude.ai → Settings → Usage and compares the session and weekly percentages and reset times with the readout and the popover. Expected: the same numbers, rounded to whole percent.

- [ ] **Step 3: Add a second account**

The user picks "Add account…" and signs in with a second claude.ai account in the Terminal window that opens.

Expected:
- While the login runs, `claude auth status` in another terminal still shows the first account.
- Afterwards the menu lists both, with the second one ticked.
- `security dump-keychain | grep -c '"Claude Code-credentials-'` prints `0`, because the temporary item is gone (this lists item names only, never secrets).
- `ls ~/Library/Application\ Support/ClaudeUsageBar/` shows no `login-*` folder.

This step also confirms the `CLAUDE_CONFIG_DIR` Keychain naming that was read from Claude Code's binary. If the login works in Terminal but the app reports "Sign-in didn't finish", look in `app.log` and compare the service name with the one listed by `security dump-keychain | grep 'Claude Code-credentials-'`.

- [ ] **Step 4: Switch and switch back**

The user clicks the first account in the menu. Expected:
- `claude auth status` shows it;
- `claude -p ok` answers;
- the readout shows its numbers within seconds.

Then they switch back to the second account and run the same checks. `security find-generic-password -s "Claude Code-credentials" -w | python3 -c "import json,sys; print(sorted(json.load(sys.stdin)))"` still lists `mcpOAuth`.

- [ ] **Step 5: Start at login and rebuild without prompts**

1. The user logs out and back in: the readout appears without starting the app by hand.
2. Run `tools/package.sh 0.0.1-dev`, copy the app to `/Applications` again and open it. Expected: no Keychain password prompt at any point.

- [ ] **Step 6: The pull request**

Use superpowers:finishing-a-development-branch. With the user's OK, push `macos-port` and open a pull request against `main`. The `build-windows` job is the first real build of the moved Windows project, so check it as well as `build-macos`. Use the ccd_pr tools to bind the PR and read its CI.
