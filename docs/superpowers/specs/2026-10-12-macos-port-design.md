# macOS port and monorepo: design

Date: 2026-10-12 · Status: approved in conversation, awaiting spec review

## Goal

ClaudeUsageBar on macOS, with full parity with the Windows app: Claude usage limits (5-hour session and weekly,
the same numbers as claude.ai → Settings → Usage) always visible in the menu bar, details on click, and switching
between Claude Code accounts from the menu. The repository becomes a monorepo with both apps.

Success:

- A glance at the menu bar shows the same session and weekly numbers as claude.ai, with countdowns to reset.
- The app runs unattended: starts at login, renews the Claude Code login itself, survives sleep, backs off on 429.
- Account switching behaves as on Windows: one menu click → `claude auth status` shows the new account; new
  `claude` processes use it; running sessions use it from their next request (within ~30 s, see below).
- Adding an account never signs out the current one; removing one never revokes it on the server.
- No Keychain password prompts, not even after rebuilding or updating the app.
- The Windows app keeps building, testing and releasing exactly as before, from its new folder.

Decisions taken in conversation:

| Topic | Decision |
|---|---|
| Scope | Full parity with Windows, including accounts. |
| Menu bar readout | Two rows, as on Windows: `✻ 5h ▰▱ 38% 3h 49m` over `W ▰▱ 24% 6d 17h`. |
| Repository | Monorepo: `windows/`, `macos/`, `shared/` in `liskeee/claude-usage-bar`. |
| Stack | Native Swift (AppKit + SwiftUI), Swift Package Manager, no Xcode project. Logic ported from C#. |
| Releases | One workflow; every release carries both Windows zips and the macOS zip. |

## Findings (Claude Code 2.1.287 on macOS 27)

| Question | Result | How we know |
|---|---|---|
| Where is the login? | Keychain, generic password, service `Claude Code-credentials`, account `$USER`. `~/.claude/.credentials.json` does not exist. | Checked on this Mac. |
| What is in it? | JSON: `claudeAiOauth` (`accessToken`, `expiresAt`, `refreshToken`, `refreshTokenExpiresAt`, `scopes`, `subscriptionType`, `rateLimitTier`), `mcpOAuth`, `organizationUuid`. | Checked on this Mac (key names only). |
| `oauthAccount`? | In `~/.claude.json`, as on Windows. | Checked on this Mac. |
| How does Claude Code access it? | Only through `/usr/bin/security`: `find-generic-password -a <user> -w -s <service>`; writes `add-generic-password -U -a <user> -s <service> -X <hex>` via `security -i` on stdin, or via argv when the command is longer than 4032 characters. Exit 44 = item not found, 36 = keychain locked. | Read from the CLI binary. |
| Service name with `CLAUDE_CONFIG_DIR` | `Claude Code-credentials-` + first 8 hex chars of `sha256(<config dir>, NFC-normalised)`. `CLAUDE_SECURESTORAGE_CONFIG_DIR` overrides the dir used. | Read from the CLI binary; verified in the first implementation task. |
| Keychain account name | `$USER` if it matches `^[a-zA-Z0-9._-]+$`, else `claude-code-user`. | Read from the CLI binary. |
| Account-scoped keys in the item | On logout Claude Code removes `claudeAiOauth`, `organizationUuid`, `trustedDeviceToken`, `enterpriseGateway`, `designOauth`; it keeps `mcpOAuth`. | Read from the CLI binary. |
| Running sessions after a switch | Claude Code caches its Keychain read for 30 s. | Read from the CLI binary. |
| Tooling | Swift 6.4, Xcode 27, no Developer ID identity (ad-hoc signing only). | Checked on this Mac. |

Because every access goes through `/usr/bin/security`, the item's access list trusts that tool, not Claude Code's
own binary. The app does the same and is never prompted, whatever its own signature is. The Security framework
is not used: an ad-hoc signature changes with every build, and each change would bring a Keychain prompt back.

## Monorepo

```
claude-usage-bar/
├─ README.md                  overview, download for both systems, how accounts work
├─ windows/                   git mv of ClaudeUsageBar.sln, src/, tests/, tools/
│  └─ README.md               Windows build, files, uninstall
├─ macos/
│  ├─ Package.swift
│  ├─ Sources/ClaudeUsageBarCore/
│  ├─ Sources/ClaudeUsageBar/
│  ├─ Tests/ClaudeUsageBarCoreTests/
│  ├─ tools/package.sh
│  └─ README.md
├─ shared/
│  ├─ localization/en.json, pl.json
│  └─ fixtures/usage-2026-10-01.json
├─ docs/superpowers/…
└─ .github/workflows/build.yml
```

Windows changes are paths only. The C# code stays as it is:

- `ClaudeUsageBar.csproj`: `EmbeddedResource Include="..\..\..\shared\localization\*.json"`, same `LogicalName`.
- Test csproj: the fixture is linked from `..\..\..\shared\fixtures\` into the output `Fixtures\` folder, so
  `TestSupport.Fixtures` is unchanged.
- `tools/*.ps1` resolve paths from `$PSScriptRoot` and move with the code, so they need no change.
- The C# `Texts` ignores the new `macos` block (System.Text.Json skips unknown members by default), and
  `TextsTests` walks the deserialized object, not the raw file, so it is unaffected.
- Windows cannot be built on this Mac (WinForms). It is verified by CI on the pull request.
- `.gitignore` gains `.build/`, `.swiftpm/` and `macos/dist/`.

### Localization

`shared/localization/<code>.json` is the single source for both apps. Existing keys keep their meaning. Strings
that only make sense on macOS live in a top-level `macos` object, which the Windows app ignores:

```json
"macos": {
  "menu": { "startAtLogin": "Uruchamiaj przy logowaniu", "quit": "Zakończ" },
  "accounts": { "claudeNotFound": "Nie znaleziono Claude Code (claude). Zainstaluj go i spróbuj ponownie." }
}
```

The macOS app uses the shared `limits`, `bar`, `time`, `popup` and `accounts` texts plus the `macos` block. It
does not use `menu.startWithWindows`, `menu.exit`, `accounts.claudeNotFound` or `autostartDescription`. The
language follows the first preferred system language: Polish when it is `pl`, English otherwise.

### CI and releases

One workflow, `.github/workflows/build.yml`, with the same triggers as today (push and PR to `main`, ignoring
`**.md`, plus manual runs):

- `build-windows` (windows-latest): `dotnet test` and `tools/package.ps1` in `windows/`. It also computes the
  version with `windows/tools/next-version.ps1`, which is still the source of the version (`<Version>` in the
  csproj plus the patch number from tags).
- `build-macos` (macos-latest, needs the version): `swift test`, then `tools/package.sh <version>` → a universal
  (arm64 + x86_64) ad-hoc signed `ClaudeUsageBar.app` in `ClaudeUsageBar-<version>-macos.zip`.
- `release` (main only): downloads both artifacts, writes one `SHA256SUMS.txt` over all zips, runs
  `gh release create v<version>` with everything. Tags continue `v1.0.n`.

## macOS app

Two SPM targets plus tests. `swift-tools-version: 6.0`, Swift 6 language mode (strict concurrency),
`platforms: [.macOS(.v14)]`. Bundle id `io.github.liskeee.ClaudeUsageBar`, `LSUIElement` (no Dock icon).

### `ClaudeUsageBarCore` (logic, no AppKit)

Each file matches its C# counterpart in `windows/src/ClaudeUsageBar/Core/`, so fixes can be carried across.

- `UsageSnapshot`: `LimitKind` (session, weekly, weeklyScoped), `LimitInfo`, `UsageSnapshot`.
- `UsageParser`: `limits[]` (`session`, `weekly_all`, `weekly_scoped` with `scope.model.display_name`), falling
  back to `five_hour` / `seven_day`.
- `UsageAPI`: protocol plus a `URLSession` implementation. `GET https://api.anthropic.com/api/oauth/usage`, headers
  `Authorization: Bearer`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: ClaudeUsageBar/<version> (macOS)`.
  Timeout 15 s. Result: ok(json), unauthorized, rateLimited, failed(error).
- `ProcessRunner`: protocol plus a `Foundation.Process` implementation (arguments, stdin, environment, timeout →
  exit code, stdout, stderr). The single seam for every external process, so tests can fake it.
- `SecurityCLI`: the only code that touches the Keychain, through `/usr/bin/security`. `read(service:account:)` →
  `Data?` (nil on 44), `write(service:account:data:)` (stdin via `security -i` up to 4032 characters, argv
  above that, as Claude Code does), `delete(service:account:)`. Exit 36 → `keychainLocked`.
- `KeychainNames`: the Claude Code service name for the default dir and for a `CLAUDE_CONFIG_DIR`, and the
  account name rule.
- `CredentialStore`: from the active item's `claudeAiOauth` → `Credentials(accessToken, expiresAt,
  subscriptionType, rateLimitTier)`. Its description never contains the token.
- `TokenRenewer`: `claude -p ok --model haiku --safe-mode --no-session-persistence`, at most once every 30 min,
  90 s timeout, working directory in Application Support. Finds `claude` in `PATH`, `~/.local/bin`,
  `/opt/homebrew/bin`, `/usr/local/bin` (an app started at login has a minimal `PATH`). Removes every `CLAUDE*`
  and `ANTHROPIC*` variable from the child environment. Shares one lock with `AccountSwitcher`.
- `UsageService`: the same state machine as C#. State is `loading`, `ok`, `error` or `needsLogin`, plus the
  snapshot, plan name, last success and last error. It keeps the last good snapshot when a refresh fails. It
  polls every 5 min, or 15 s after the session reset when that comes sooner. On HTTP 429 it waits 10 → 20 →
  30 min. Data counts as stale after 15 min. `reset()` bumps the generation after an account switch, so a refresh
  that started earlier is discarded. A clock is injected for tests.
- `Format`: severity (< 50 ok, 50–80 warn, > 80 critical), percent, short and long countdowns, "ago", reset
  moment ("today 18:00", "tomorrow 08:00", other day), limit labels, plan name (`max_20x` → "Max 20x"),
  masked e-mail.
- `Texts`: loads `<dir>/<code>.json` from a directory URL given by the caller. That is the app bundle's
  `Resources/localization` at runtime and `shared/localization` in tests (found through `#filePath`). SPM
  resources are not used, because they cannot point outside the package.
- Accounts: see the next section.
- `Log`: `~/Library/Logs/ClaudeUsageBar/app.log`, timestamped lines, trimmed to the last 1 MB at start. It never
  logs tokens, only masked e-mails and uuid prefixes.

### Accounts

- `AccountKey`: `oauthAccount.accountUuid` plus `organizationUuid`.
- `AccountLogin`: raw JSON copies of the account-scoped Keychain keys (`claudeAiOauth`, `organizationUuid`,
  `trustedDeviceToken`, `enterpriseGateway`, `designOauth`, whichever exist) and of `oauthAccount`. Unknown fields
  round-trip unchanged. Accessors: key, e-mail, organization name, refresh token, `refreshTokenExpiresAt`, plan
  name. `sameAs` compares both parts.
- `CliLogin` is the only code that writes Claude Code's login. It works on one Keychain service plus one global
  config path: `~/.claude.json` for the default login, `<dir>/.claude.json` for a `CLAUDE_CONFIG_DIR`.
  - `readCurrent()` → `AccountLogin?`. It returns nil when the item or the file is missing or unreadable, has no
    `claudeAiOauth` or `oauthAccount`, or has an empty `accountUuid`.
  - `write(login)` runs in four steps:
    1. Back up the current item value and `~/.claude.json` to `~/Library/Application Support/ClaudeUsageBar/backup/`.
       The item value is encrypted with the accounts key. Only the last backup is kept.
    2. Read the item, replace the account-scoped keys with the target's (removing those the target lacks),
       leave `mcpOAuth` and any other key as it was, and write it back.
    3. Update `~/.claude.json`: set `oauthAccount`, remove the same account caches as on Windows
       (`CliLogin.AccountCaches`), then write it atomically (temp file in the same dir, then rename). If the
       file's modification date or size changed since it was read, re-read and retry, up to 3 attempts. JSON is
       written with `JSONSerialization` (pretty-printed, slashes unescaped). Values round-trip, including
       non-ASCII text, large integers and booleans. Key order does not, which is harmless because Claude Code
       rewrites the file in its own order on its next save.
    4. If step 3 fails, write the item value from step 1 back.
  - `deleteItem()` is used only for the temporary add-account login.
- `AccountStore`: `~/Library/Application Support/ClaudeUsageBar/accounts.dat`. The JSON is shaped like the
  Windows file, except that `secure` holds every account-scoped Keychain key where Windows has only
  `claudeAiOauth`: `{"version":1,"accounts":[{"savedAt", "secure":{…}, "oauthAccount":{…}}]}`. It is encrypted with AES-GCM
  (CryptoKit). The 256-bit key is in the app's own generic password, service `ClaudeUsageBar`, account
  `accounts-key`, created on first use through `SecurityCLI`. A file that does not decrypt or parse is renamed to
  `accounts.dat.bad` and the list starts empty. Supports upsert by key and remove.
- `AccountSwitcher`: the same rules as C#.
  - `sync()` runs on every refresh. It reads the active login and saves it when it is new or changed. If another
    account was signed in by hand, it raises `switched`. It does not save a login whose refresh token belongs to
    another saved account.
  - `switchTo(key)` holds the CLI lock, runs `sync()`, then `CliLogin.write`, then reads the login back and
    compares the key.
  - `addAccount(email?)` uses a temporary dir in Application Support. It deletes leftover `login-*` dirs and
    their Keychain items first, runs `LoginRunner` and waits. Then it reads the new login from the temporary dir's
    service and `.claude.json`. Under the CLI lock it runs `sync()`, saves the login and switches to it.
    Finally it always deletes the temporary dir and its Keychain item, because both hold live tokens.
  - `remove(key)` works on inactive accounts only.
- `LoginRunner`: writes `<dir>/login.command` (zsh, mode 700) and opens it with `open -a Terminal`. The script:
  1. Prints the translated hint.
  2. Unsets every `CLAUDE*` and `ANTHROPIC*` variable.
  3. Runs `CLAUDE_CONFIG_DIR=<dir> <claude> auth login [--email <email>]`. The e-mail is passed only when it
     matches a plain address pattern, and paths are single-quoted.
  4. Writes the exit code to `<dir>/exit-code`.

  The script records its own pid in `<dir>/pid`. The app polls every second: an exit code ends the wait, and a pid
  that is gone with no exit code means the window was closed (failure). On app quit the script's process is
  killed. Only one login runs at a time.
- `AccountLabels`: ordering (e-mail, then organization), labels `e-mail · plan` with the organization added when
  two would read the same, "sign in again" past `refreshTokenExpiresAt`.

### `ClaudeUsageBar` (UI)

- `main.swift` / `AppDelegate`: accessory app. It builds the core objects and runs one timer that refreshes on
  `UsageService.nextDelay()`. It refreshes right away on `NSWorkspace.didWakeNotification`, and repaints the bar
  every minute for the countdowns. First run: register the login item, write a marker file in Application
  Support.
- `StatusItemController`: `NSStatusItem` with variable length and a custom `BarView` as the button's content.
  - Left click toggles the popover.
  - Right click or ctrl+click opens the menu.
  - The button is highlighted while the popover is open.
- `BarView` follows the Windows `BarRenderer` layout, scaled to the menu bar height (~112 pt wide):
  - Clay spark (#D97757), drawn as a port of `Primitives.Spark`.
  - Two rows: label (`5h`, `W`; SF Pro 9.5 pt, secondary colour), pill track with fill, percent (10 pt
    semibold, monospaced digits, right-aligned), countdown (secondary).
  - Severity colours are tuned for the light and dark menu bar (`effectiveAppearance`). Stale data turns grey,
    a missing limit shows "…", and `needsLogin` reads "Claude: zaloguj" / "Claude: sign in".
  - The view sets an accessibility label, e.g. "Session 38%, resets in 3h 49m; week 24%".
- `DetailsView` (SwiftUI in an `NSPopover`, 300 pt wide, transient):
  - Header: spark, "Claude <plan>", the active account's e-mail right-aligned and truncated.
  - One block per limit: label, percent, bar, "Resets in 3h 49m · today 18:00".
  - Empty-state text.
  - Footer: "Updated 2m ago" / "Not refreshed · data 20m ago" / …, plus a "Refresh" link. The text ticks while
    the popover is open.
- `StatusMenu` (`NSMenu`, rebuilt on open):

  ```
  ✓ jan@firma.pl · Max 5x
    l***@gmail.com · Pro
    stare@konto.pl · Pro — zaloguj ponownie
    Dodaj konto…
    Usuń konto              ▸   (inactive accounts only; hidden when none)
  ───────────────────────────
    Odśwież teraz
    Uruchamiaj przy logowaniu   (checkmark)
  ───────────────────────────
    Zakończ
  ```

  - Clicking an inactive account switches to it with no confirmation.
  - "Sign in again" runs `addAccount(email)`.
  - "Dodaj konto…" is disabled while a login is running.
  - Removing an account asks for confirmation in an `NSAlert` (`accounts.removeConfirm`).
- `LoginItem`: `SMAppService.mainApp` register, unregister and status.
- Errors from user actions (`claude` not found, login failed, write failed) show an `NSAlert` with the
  translated text. Nothing changes in that case.

### Packaging: `macos/tools/package.sh <version> [out]`

`swift build -c release --arch arm64 --arch x86_64`, then it assembles `ClaudeUsageBar.app`:

- `Contents/MacOS/ClaudeUsageBar`.
- `Contents/Info.plist` with bundle id, version, `LSUIElement`, `LSMinimumSystemVersion` 14.0.
- `Contents/Resources/localization/*.json` copied from `shared/`.
- `Contents/Resources/AppIcon.icns`, copied from `macos/Resources/AppIcon.icns`. That file is generated once
  from the spark by `macos/tools/make-icon.swift` and committed.

Then `codesign --force --deep -s -` (ad-hoc), and `ditto -c -k --keepParent` into
`ClaudeUsageBar-<version>-macos.zip`.

## Error handling

- Usage fetch fails or is rate limited: the last data stays on screen and turns grey after 15 min. The footer
  says why.
- Login expired: one renewal attempt (throttled). If that fails, the state is `needsLogin`, the bar reads
  "Claude: zaloguj", and the popover explains how to sign in.
- Keychain locked (36): a transient error, retried on the next refresh. No prompt is triggered.
- `~/.claude.json` changed during a switch: up to 3 attempts. If it still fails, the Keychain item is restored,
  an `NSAlert` explains, and the active account is unchanged.
- Add account: if the Terminal window is closed, `claude auth login` fails, or no login is found in the temporary
  dir, nothing changes and the temporary dir and Keychain item are removed.
- A race is accepted, as on Windows: a token refresh by a running session in the same millisecond as a switch can
  lose that account's newest tokens, and it then needs a new login.
- Running sessions see a switch after up to 30 s (Claude Code's Keychain cache). This is documented in the
  README.

## Testing

Swift Testing (`swift test` in `macos/`). No test touches the real Keychain, `~/.claude.json` or the network.
Fakes are injected for `ProcessRunner` (backed by an in-memory Keychain for `security` calls), `UsageAPI`, the
clock and the file locations, which are temporary directories.

- `UsageParserTests`: the shared fixture; legacy fallback; unknown kinds skipped.
- `FormatTests`: severity edges, countdowns, "ago", reset moment today, tomorrow and another day, rounding of
  17:59:59.9, plan names, e-mail masking.
- `TextsTests`: every file in `shared/localization` has every text the macOS app reads (shared plus `macos`),
  with no empty values, 7 weekdays and 12 months, and only known placeholders. `pl` / `pl-PL` → Polish;
  `de`, `en` → English.
- `UsageServiceTests`: ok, 401 → renew → retry, `needsLogin`, 429 backoff sequence, stale after 15 min, next
  delay before a session reset, `reset()` drops an in-flight refresh.
- `TokenRenewerTests`: throttle; environment cleaned; `claude` lookup order.
- `KeychainNamesTests`: default service; `CLAUDE_CONFIG_DIR` suffix against values computed by Claude Code's
  formula; account name rule.
- `SecurityCLITests`: argument shapes for read, write and delete; stdin vs argv at the 4032 boundary; exit 44 →
  nil; exit 36 → `keychainLocked`.
- `CliLoginTests`: only the account-scoped keys and `oauthAccount` change; `mcpOAuth`, unknown keys and non-ASCII
  survive; keys the target lacks are removed; caches are dropped; retry on a concurrent change; the Keychain is
  restored when the config write fails; missing or corrupt data reads as nil.
- `AccountStoreTests`: encrypt/decrypt round-trip, upsert by key, remove, corrupt file → `.bad`, key created once.
- `AccountSwitcherTests` with a fake `LoginRunner`: rotated tokens captured before switching away; a login made
  by hand is picked up and raises `switched`; add and switch; re-login of a known account; the active account
  can't be removed; tokens shared with another saved account are not saved; temporary dir and item always
  removed.
- `AccountLabelsTests`: ordering, ambiguity suffix, "sign in again".
- `LoginRunnerTests`: script text (quoting, e-mail filter, environment cleanup) and the wait (exit code, window
  closed, cancel).

Manual check on this Mac, by the user, since a switch also moves the running Claude Code sessions:

1. The numbers match claude.ai.
2. Add a second account via Terminal: the current one stays signed in until the switch.
3. Switch: `claude auth status` shows the new account and `claude -p ok` works. Then switch back.
4. Turn "Start at login" on, log out and back in: the app comes up.
5. Rebuild the app and run it again: no Keychain prompt.

## Docs

- Root `README.md`: what it is, a screenshot per platform, downloads (Windows zips, macOS zip), how accounts
  work on both systems, and the repo layout.
- `windows/README.md`: today's README minus the overview, with paths updated.
- `macos/README.md`:
  - Install: unzip to `/Applications`. On first open, use System Settings → Privacy & Security → "Open Anyway"
    (ad-hoc signed), or build it yourself.
  - Build: `swift test`, `tools/package.sh`.
  - Files: Application Support, Logs, the `ClaudeUsageBar` Keychain item.
  - Notch note: with many menu bar items macOS may hide the readout.
  - Uninstall.

## Out of scope

- Developer ID signing and notarisation (no identity available). It can be added later in `package.sh` and CI.
- Sharing logic between the C# and Swift code.
- Checking whether the Windows switch should also carry `organizationUuid` / `trustedDeviceToken` in
  `.credentials.json`. That is a separate follow-up.
- Sparkle or any other auto-update.
