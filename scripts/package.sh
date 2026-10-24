#!/bin/bash
# Build the download package: the extension, a universal helper (Apple silicon + Intel), scripts and a short guide.
# Output: dist/iphone-photos-vX.Y.Z.zip
# 生成下载包：插件、通用版读取助手（Apple 芯片 + Intel）、脚本和简短说明。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/helper/Info.plist")"
EXT_VERSION="$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$ROOT/extension/manifest.json")"
if [ "$VERSION" != "$EXT_VERSION" ]; then
  echo "Helper $VERSION and extension $EXT_VERSION versions differ / 读取助手和插件版本号不一致"
  exit 1
fi
NAME="iphone-photos-v$VERSION"
OUT="$ROOT/dist/$NAME"
rm -rf "$OUT" "$OUT.zip"
mkdir -p "$OUT/helper"
bash "$ROOT/helper/build.sh" universal
ditto "$ROOT/helper/build/iPhonePhotosHelper.app" "$OUT/helper/iPhonePhotosHelper.app"
rsync -a --exclude '.DS_Store' "$ROOT/extension/" "$OUT/extension/"
cp "$ROOT"/{install.sh,uninstall.sh,selftest.sh} "$OUT/"
cp "$ROOT/docs/HELPER.zh-CN.md" "$OUT/README.md"
# No ._ AppleDouble files or extended attributes in the zip. / zip 里不要 ._ 附加文件和扩展属性。
(cd "$ROOT/dist" && ditto -c -k --norsrc --noextattr --noqtn --keepParent "$NAME" "$NAME.zip")
echo "Package / 下载包: $OUT.zip"
