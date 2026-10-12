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
