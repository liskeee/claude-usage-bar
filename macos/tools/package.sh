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
