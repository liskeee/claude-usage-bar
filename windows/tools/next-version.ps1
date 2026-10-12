# Prints the next release version: major.minor from <Version> in the csproj, patch one above the highest v<major>.<minor>.* tag.
$project = [xml](Get-Content "$PSScriptRoot/../src/ClaudeUsageBar/ClaudeUsageBar.csproj")
$base = [version]$project.SelectSingleNode('//Version').InnerText
$prefix = "v$($base.Major).$($base.Minor)."
$released = @(git tag --list "$prefix*" | ForEach-Object { $_.Substring($prefix.Length) } | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
$patch = [Math]::Max($base.Build, 0)
if ($released.Count) { $patch = [Math]::Max($patch, ($released | Measure-Object -Maximum).Maximum + 1) }
"$($base.Major).$($base.Minor).$patch"
