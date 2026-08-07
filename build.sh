#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
build_dir="$project_dir/build"
app_dir="$build_dir/NitsBar.app"
contents_dir="$app_dir/Contents"

rm -rf "$app_dir"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"

xcrun swiftc \
  -swift-version 5 \
  -parse-as-library \
  -O \
  -framework AppKit \
  -framework IOKit \
  -framework ServiceManagement \
  "$project_dir/NitsBar.swift" \
  -o "$contents_dir/MacOS/NitsBar"

cp "$project_dir/Info.plist" "$contents_dir/Info.plist"
xattr -cr "$app_dir"
if ! codesign --force --sign - "$app_dir"; then
  # File Provider can reattach Finder metadata between the clear and sign
  # operations in Documents. Clear once more and retry deterministically.
  xattr -cr "$app_dir"
  codesign --force --sign - "$app_dir"
fi

echo "$app_dir"
