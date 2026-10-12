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
