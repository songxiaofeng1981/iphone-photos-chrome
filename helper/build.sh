#!/bin/bash
# Build the helper app (needs Xcode Command Line Tools: xcode-select --install)
# 编译读取助手（需要 Xcode 命令行工具：xcode-select --install）
#   bash helper/build.sh            # this Mac's architecture / 只编译本机架构
#   bash helper/build.sh universal  # Apple silicon + Intel, used for releases / 发布用的通用版本
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/build/iPhonePhotosHelper.app"
SRC=("$HERE"/*.swift)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
BIN="$APP/Contents/MacOS/iphone-photos-helper"
if [ "${1:-}" = "universal" ]; then
  swiftc -O -target arm64-apple-macos12 "${SRC[@]}" -o "$HERE/build/helper-arm64"
  swiftc -O -target x86_64-apple-macos12 "${SRC[@]}" -o "$HERE/build/helper-x86_64"
  lipo -create "$HERE/build/helper-arm64" "$HERE/build/helper-x86_64" -output "$BIN"
  rm -f "$HERE/build/helper-arm64" "$HERE/build/helper-x86_64"
else
  swiftc -O "${SRC[@]}" -o "$BIN"
fi
codesign --force --sign - --identifier com.song.iphone_photos.helper "$APP"
echo "Built / 已编译: $APP"
