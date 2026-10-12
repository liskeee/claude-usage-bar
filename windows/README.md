# ClaudeUsageBar for Windows

Claude usage limits (5-hour session and weekly) in the Windows 11 taskbar, next to the system tray arrow.
The numbers match claude.ai → Settings → Usage.

- Left click: details (all limits, reset times, "Refresh").
- Right click: your Claude Code accounts (click one to switch) · Add account… · Remove account ·
  Refresh now · Start with Windows · Exit.

Requires a signed-in Claude Code CLI (`claude`). When its login expires, the app runs
`claude -p ok --model haiku --safe-mode --no-session-persistence` to renew it (at most once every 30 min).

The usage endpoint is rate limited: the app polls every 5 minutes and backs off to 10 → 20 → 30 minutes
on HTTP 429, keeping the last data on screen.

## Accounts

The menu lists every Claude Code account the app has seen; the active one is ticked. Clicking another account
switches Claude Code to it at once, with no browser: `claude auth status` shows the new account, new `claude`
processes use it, and running sessions use it from their next request. The bar shows the new account's limits
within seconds.

- **Add account…** opens a console window with `claude auth login` in a separate, temporary Claude Code config,
  so the current login is never signed out. If the browser is signed in to another claude.ai account, copy the
  link into a private window. The new account becomes active.
- An account whose saved login has expired (about 30 days unused) reads "sign in again"; clicking it runs the
  same login.
- **Remove account** only forgets an inactive account; it is not signed out on the server.
- An account you sign in to by hand (`/login` in Claude Code) is picked up automatically.

Switching writes Claude Code's login files: only `claudeAiOauth` in `~\.claude\.credentials.json` and
`oauthAccount` in `~\.claude.json` (plus the account caches Claude Code itself drops on logout). Settings,
plugins, MCP servers and history stay shared. A copy of both files from before the last switch is kept in
`%LOCALAPPDATA%\ClaudeUsageBar\backup\`.

## Download

[Releases](https://github.com/liskeee/claude-usage-bar/releases/latest) → unzip `ClaudeUsageBar.exe` into a folder
of your choice and run it. The first run turns on "Start with Windows".

- `ClaudeUsageBar-<version>-win-x64.zip` — small, needs the
  [.NET 9 Desktop Runtime](https://dotnet.microsoft.com/download/dotnet/9.0).
- `ClaudeUsageBar-<version>-win-x64-self-contained.zip` — no runtime needed, ~45 MB.

Windows starts apps from the Startup folder only after all its other startup entries, so after signing in
the readout can take a few minutes to appear.

## Languages

The UI follows the Windows display language: Polish on a Polish Windows, English otherwise.
Translations live in `shared/localization/<code>.json` at the repository root (embedded in the exe, shared with the macOS app), one file per
two-letter ISO language code. To add a language, copy `en.json` to e.g. `de.json`, translate the values
(keep the `{placeholders}`) and rebuild — the tests check that every file has all texts and only known
placeholders. Keys under `macos` are used only by the macOS app.

## Build

From the `windows/` folder:

```powershell
dotnet test ClaudeUsageBar.sln
dotnet publish src/ClaudeUsageBar/ClaudeUsageBar.csproj -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true -o app
```

Both release zips: `tools/package.ps1 -Version 1.2.3` (into `dist\`).

## Files

- App: `app\ClaudeUsageBar.exe`
- Log and first-run marker: `%LOCALAPPDATA%\ClaudeUsageBar\`
- Saved accounts: `%LOCALAPPDATA%\ClaudeUsageBar\accounts.dat` (encrypted for your Windows user with DPAPI)
- Claude Code login files from before the last switch: `%LOCALAPPDATA%\ClaudeUsageBar\backup\`
- Autostart: `ClaudeUsageBar.lnk` in the Startup folder

## Uninstall

Right click → untick "Start with Windows" → Exit, then delete this folder
and `%LOCALAPPDATA%\ClaudeUsageBar`.
