# ClaudeUsageBar

[![Build](https://github.com/liskeee/claude-usage-bar/actions/workflows/build.yml/badge.svg)](https://github.com/liskeee/claude-usage-bar/actions/workflows/build.yml)

Claude usage limits (5-hour session and weekly) in the Windows 11 taskbar, next to the system tray arrow.
The numbers match claude.ai → Settings → Usage.

- Left click: details (all limits, reset times, "Refresh").
- Right click: Refresh now · Start with Windows · Exit.

Requires a signed-in Claude Code CLI (`claude`). When its login expires, the app runs
`claude -p ok --model haiku --safe-mode --no-session-persistence` to renew it (at most once every 30 min).

The usage endpoint is rate limited: the app polls every 5 minutes and backs off to 10 → 20 → 30 minutes
on HTTP 429, keeping the last data on screen.

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
Translations live in `src/ClaudeUsageBar/Localization/<code>.json` (embedded in the exe), one file per
two-letter ISO language code. To add a language, copy `en.json` to e.g. `de.json`, translate the values
(keep the `{placeholders}`) and rebuild — the tests check that every file has all texts and only known
placeholders.

## Build

```powershell
dotnet test ClaudeUsageBar.sln
dotnet publish src/ClaudeUsageBar/ClaudeUsageBar.csproj -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true -o app
```

Both release zips: `tools/package.ps1 -Version 1.2.3` (into `dist\`).

## Releases

GitHub Actions ([build.yml](.github/workflows/build.yml)) runs the tests and builds both zips for every pull request
and every push to `main`. A push to `main` also publishes a GitHub Release, tagged `v<major>.<minor>.<n>`:
major and minor come from `<Version>` in `ClaudeUsageBar.csproj`, `n` counts up from the last tag
(`tools/next-version.ps1`). To start a new line, e.g. 1.1.0, change `<Version>`. Pushes that only touch `*.md` files
don't build or release.

## Files

- App: `app\ClaudeUsageBar.exe`
- Log and first-run marker: `%LOCALAPPDATA%\ClaudeUsageBar\`
- Autostart: `ClaudeUsageBar.lnk` in the Startup folder

## Uninstall

Right click → untick "Start with Windows" → Exit, then delete this folder
and `%LOCALAPPDATA%\ClaudeUsageBar`.
