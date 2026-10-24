#!/bin/bash
# Build the helper download package: universal helper (Apple silicon + Intel), scripts and a short guide.
# Output: dist/iphone-photos-helper-vX.Y.Z.zip
# 生成读取助手下载包：通用版助手（Apple 芯片 + Intel）、脚本和简短说明。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/helper/Info.plist")"
NAME="iphone-photos-helper-v$VERSION"
OUT="$ROOT/dist/$NAME"
rm -rf "$OUT" "$OUT.zip"
mkdir -p "$OUT/helper"
bash "$ROOT/helper/build.sh" universal
ditto "$ROOT/helper/build/iPhonePhotosHelper.app" "$OUT/helper/iPhonePhotosHelper.app"
cp "$ROOT"/{install.sh,uninstall.sh,selftest.sh} "$OUT/"
cp "$ROOT/docs/HELPER.zh-CN.md" "$OUT/README.md"
# No ._ AppleDouble files or extended attributes in the zip. / zip 里不要 ._ 附加文件和扩展属性。
(cd "$ROOT/dist" && ditto -c -k --norsrc --noextattr --noqtn --keepParent "$NAME" "$NAME.zip")
echo "Package / 下载包: $OUT.zip"
