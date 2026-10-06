# Account switching: design

Date: 2026-10-06 · Status: approved in conversation, awaiting spec review

## Goal

ClaudeUsageBar switches the account Claude Code CLI is signed in with, from the taskbar menu, without a
browser round-trip. The bar keeps showing usage of the active account only.

Success:

- One menu click → `claude auth status` shows the new account; new `claude` processes use it; already running
  sessions use it from their next request.
- The bar shows the new account's limits within seconds (never the old account's numbers labelled as new).
- Adding an account never signs out the current one.
- Removing an account from the list never revokes it on the server.
- Claude Code settings, plugins, MCP servers and history stay shared; only the login changes.

## Spike findings (Claude Code 2.1.291, throwaway, test dirs only)

| Question | Result |
|---|---|
| `claude auth login` with `CLAUDE_CONFIG_DIR=<temp>` | Login lands only in `<temp>`; `~/.claude` untouched (hash unchanged). |
| Replace `claudeAiOauth` (`.credentials.json`) + `oauthAccount` (`.claude.json`), drop account caches | `auth status` shows the new account, `claude -p` works. |
| Running session during a swap | Re-reads the login before every request: invalid login → next request fails; valid login restored → next request succeeds. |
| CLI token refresh | Rotates access **and** refresh token → the active account must be captured right before switching away. |
| `refreshTokenExpiresAt` after refresh | Unchanged (30 days from login). An account idle past it needs a new login. |

Not tested on purpose: reusing a refresh token after rotation (could revoke the whole token family). The design
treats any older copy of an account's tokens as dead.

Also known from the CLI: `logout` revokes the refresh token on the server. The app never runs `logout`, and never
runs `login` against `~/.claude`.

## Architecture

Three new classes in `Core/`. `UsageService`, `FileCredentialStore` and `CliTokenRenewer` keep working on
`~/.claude` (the active account) as today.

### `CliLogin` — the only writer of Claude Code files

- `ReadCurrent()` → `AccountLogin?`: `claudeAiOauth` from `<dir>/.credentials.json` and `oauthAccount` from the
  global config, both kept as raw JSON (`JsonNode`) so unknown CLI fields (e.g. `clientId`) round-trip unchanged.
  The global config is `~/.claude.json` for the default dir and `<dir>/.claude.json` for a `CLAUDE_CONFIG_DIR`
  (the add-account temp dir).
- `Write(AccountLogin)`: replaces only `claudeAiOauth` and only `oauthAccount`; everything else (`mcpOAuth`,
  `projects`, unknown keys, non-ASCII text) is preserved. Also removes the account-scoped caches Claude Code
  drops on logout: `subscriptionNoticeCount`, `hasAvailableSubscription`, `additionalModelOptionsCache`,
  `additionalModelOptionsAnsweredAt`, `additionalModelCostsCache`, `modelAccessCache`, `orgModelDefaultCache`,
  `cachedArtifactRoster`, `artifactRosterDenied`, `lastSeenOrgDefaultUpdatedAt`, `clientDataCache`,
  `clientDataCacheSlots`, `autoCompactWindowsCache`, `cachedUsageUtilization`.
- Each file is written atomically (temp file in the same dir → replace). Optimistic concurrency for
  `~/.claude.json` (written often by running sessions): if its mtime/size changed between read and replace,
  re-read and retry; up to 3 attempts.
- Before each write, copies both files to `%LOCALAPPDATA%\ClaudeUsageBar\backup\` (last one only).
- JSON is written indented, without escaping non-ASCII (`UnsafeRelaxedJsonEscaping`).

### `AccountStore` — saved accounts

- `%LOCALAPPDATA%\ClaudeUsageBar\accounts.dat`: the whole JSON list encrypted with DPAPI (CurrentUser),
  package `System.Security.Cryptography.ProtectedData`.
- Entry: key (`accountUuid` + `organizationUuid` from `oauthAccount`), e-mail, organization name, plan
  (`subscriptionType`, `rateLimitTier`), `refreshTokenExpiresAt`, saved-at, and the raw login
  (`claudeAiOauth` + `oauthAccount`).
- `Upsert` replaces an entry with the same key. Unreadable file (other Windows user, corruption): log it,
  rename it to `accounts.dat.bad`, start with an empty list.

### `AccountSwitcher` — orchestration

- `Sync()` (every refresh): read the active login; if its key is new or its tokens differ from the stored copy,
  upsert it. This also picks up accounts signed in by hand with `/login`.
- `SwitchTo(key)`: `Sync()` (captures freshly rotated tokens of the account being left) → `CliLogin.Write(target)`
  → read back and compare key → `UsageService.Reset()` → refresh.
- `AddAccount(email?)`: temp dir under `%LOCALAPPDATA%\ClaudeUsageBar\login-<guid>` → console window
  "ClaudeUsageBar: add account" running `claude auth login [--email <email>]` with a clean environment
  (no `CLAUDE*`/`ANTHROPIC*` variables) and `CLAUDE_CONFIG_DIR=<temp>` → wait for exit → read the login from the
  temp dir → upsert → delete the temp dir → `SwitchTo` the new account. Only one login at a time. The login
  runner is injected (`Func<string? email, string dir, CancellationToken, Task<bool>>`) so tests can fake it.
- `Remove(key)`: inactive accounts only; deletes the entry, no server call.

### `UsageService`

New `Reset()`: state back to `UsageState.Initial` (Loading, no snapshot), 429 streak to zero, `Changed` raised —
so the old account's numbers are never shown for the new one.

## UI

Right-click menu (accounts on the first level, two clicks to switch):

```
● jan@firma.pl · Max 5x          ← active (radio check)
  l***@gmail.com · Pro
  stare@konto.pl · Pro — sign in again
  Add account…
  Remove account              ▸  (inactive accounts only)
─────────────────────────────
  Refresh now
  Start with Windows
─────────────────────────────
  Exit
```

- Label `e-mail · plan` (`Format.PlanName`); if two entries share e-mail and plan, the organization name is added.
- Clicking an inactive account switches immediately, no confirmation.
- Accounts past `refreshTokenExpiresAt` get the "sign in again" suffix; clicking runs `AddAccount(email)`.
- "Add account…" is disabled while a login is running. The console window prints a hint: if the browser is signed
  in with another account, copy the link into a private window.
- "Remove account ▸" lists inactive accounts; confirmation: "Remove X from the list? It won't sign it out."
  Hidden when there is nothing to remove.
- Details popup header: the active account's e-mail right-aligned next to "Claude <plan>", muted, ellipsized.
  The taskbar readout is unchanged.
- Errors of user actions (no `claude.exe`, login failed, files not written): `MessageBox`; nothing changed.
- New texts in `Localization/en.json` and `pl.json`.

## Error handling

- Target account's tokens revoked (found after switching): renewal fails → `NeedsLogin`; the popup says so and the
  menu marks the account "sign in again". The account left behind is safe in the store.
- Write failure after 3 attempts: `MessageBox`, files unchanged (atomic), active account unchanged.
- Login cancelled or failed (window closed, exit code ≠ 0, no login in the temp dir): no change, temp dir removed.
- Known race, accepted: if a running session refreshes the active account's token in the same instant the app
  switches away, that account's new tokens can be lost and it needs a new login. Refresh happens about every
  8 hours; the window is milliseconds.
- Tokens never reach the log: only masked e-mails and uuid prefixes.

## Testing

- `CliLoginTests` (temp dirs): only the two keys change; `mcpOAuth`, `projects`, unknown fields and non-ASCII
  survive byte-for-byte in meaning; caches removed; missing/corrupt files read as null; retry on concurrent change.
- `AccountStoreTests`: DPAPI round-trip, upsert by key, corrupt file → `.bad` + empty list.
- `AccountSwitcherTests` with a fake login runner: rotated tokens captured before switching; unknown active
  account auto-added; add + switch; re-login of a known account refreshes it; active account can't be removed.
- `UsageServiceTests`: `Reset()` → Loading, no snapshot, backoff cleared.
- Manual check on the real `~/.claude` by the user (switching also moves the running Claude Code session):
  `claude auth status`, `claude -p ok`, switch back.

## Docs

README: account switching section; "Files" lists `accounts.dat` and `backup\`; the app now writes Claude Code's
login files (only `claudeAiOauth` and `oauthAccount`).
