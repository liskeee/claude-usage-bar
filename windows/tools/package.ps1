# Publishes both release variants as zips plus SHA256SUMS.txt:
#   ClaudeUsageBar-<version>-win-x64.zip                 needs the .NET 9 Desktop Runtime
#   ClaudeUsageBar-<version>-win-x64-self-contained.zip  runs anywhere, bigger
param([Parameter(Mandatory)][string]$Version, [string]$Out = "$PSScriptRoot/../dist")
$ErrorActionPreference = 'Stop'
$project = "$PSScriptRoot/../src/ClaudeUsageBar/ClaudeUsageBar.csproj"
$variants = [ordered]@{
    ''                = @('--self-contained', 'false')
    '-self-contained' = @('--self-contained', 'true', '-p:EnableCompressionInSingleFile=true', '-p:IncludeNativeLibrariesForSelfExtract=true')
}
New-Item -ItemType Directory -Force $Out | Out-Null
foreach ($suffix in $variants.Keys) {
    $name = "ClaudeUsageBar-$Version-win-x64$suffix"
    $dir = Join-Path $Out "publish/$name"
    dotnet publish $project -c Release -r win-x64 -p:PublishSingleFile=true -p:DebugType=none "-p:Version=$Version" @($variants[$suffix]) -o $dir --nologo
    if ($LASTEXITCODE) { throw "publish failed: $name" }
    Compress-Archive -Path "$dir/*" -DestinationPath (Join-Path $Out "$name.zip") -Force
}
Get-ChildItem $Out -Filter *.zip |
    ForEach-Object { "$((Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant())  $($_.Name)" } |
    Set-Content (Join-Path $Out 'SHA256SUMS.txt')
