# ClaudeUsageBar

Claude usage limits (5-hour session and weekly) in the Windows 11 taskbar, next to the system tray arrow.
The numbers match claude.ai → Settings → Usage.

- Left click: details (all limits, reset times, "Refresh").
- Right click: Refresh now · Start with Windows · Exit.

Requires a signed-in Claude Code CLI (`claude`). When its login expires, the app runs
`claude -p ok --model haiku --safe-mode --no-session-persistence` to renew it (at most once every 30 min).

The usage endpoint is rate limited: the app polls every 5 minutes and backs off to 10 → 20 → 30 minutes
on HTTP 429, keeping the last data on screen.

## Build

```powershell
dotnet test ClaudeUsageBar.sln
dotnet publish src/ClaudeUsageBar/ClaudeUsageBar.csproj -c Release -r win-x64 --self-contained false -p:PublishSingleFile=true -o app
```

## Files

- App: `app\ClaudeUsageBar.exe`
- Log and first-run marker: `%LOCALAPPDATA%\ClaudeUsageBar\`
- Autostart: `ClaudeUsageBar.lnk` in the Startup folder

## Uninstall

Right click → untick "Start with Windows" → Exit, then delete this folder
and `%LOCALAPPDATA%\ClaudeUsageBar`.
