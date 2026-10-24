#!/bin/bash
# Install the iPhone Photos helper. Needs nothing else on the Mac: no Python, no Homebrew, no admin password.
# Safe to run again to update.
# 安装 iPhone 照片的读取助手。这台 Mac 上不需要装任何别的东西：不需要 Python、Homebrew，也不需要管理员密码。
# 可以重复运行，用来更新。
set -euo pipefail

HOST_NAME="com.song.iphone_photos"
EXT_ID="endldjnpicempoibdmlndkiinmmekggn"
HERE="$(cd "$(dirname "$0")" && pwd)"
SUPPORT="$HOME/Library/Application Support/iPhonePhotosHelper"
APP="$SUPPORT/iPhonePhotosHelper.app"
BIN="$APP/Contents/MacOS/iphone-photos-helper"

say() { printf '%s\n' "$@"; }

if [ "$(uname)" != "Darwin" ]; then
  say "This only works on macOS. / 只支持 macOS。"
  exit 1
fi
if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 12 ]; then
  say "Needs macOS 12 or later. / 需要 macOS 12 或更新版本。"
  exit 1
fi

say "== 1/3 Preparing the helper / 准备读取助手"
if [ -d "$HERE/helper/iPhonePhotosHelper.app" ]; then
  SRC_APP="$HERE/helper/iPhonePhotosHelper.app"                    # from the download package / 来自下载包
elif xcrun --find swiftc >/dev/null 2>&1; then
  bash "$HERE/helper/build.sh" >/dev/null                            # from source / 从源码编译
  SRC_APP="$HERE/helper/build/iPhonePhotosHelper.app"
else
  say ""
  say "No ready-made helper in this folder, and no Swift compiler to build one."
  say "Download the release package (not the source code) and run its install.sh."
  say "这个文件夹里没有现成的读取助手，也没有能编译它的 Swift 编译器。"
  say "请下载发布包（不是源代码），运行里面的 install.sh。"
  exit 1
fi

say "== 2/3 Installing the helper / 安装读取助手"
mkdir -p "$SUPPORT"
rm -rf "$APP"
ditto "$SRC_APP" "$APP"
# A downloaded zip marks files as "from the internet"; clear that so Chrome can start the helper,
# then sign it on this Mac (ad-hoc). Both only touch the helper itself.
# 下载的压缩包会把文件标记为“来自互联网”；去掉标记，Chrome 才能启动助手；再在本机签名。两步都只针对助手本身。
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
codesign --force --sign - --identifier com.song.iphone_photos.helper "$APP" >/dev/null 2>&1
cp "$HERE/uninstall.sh" "$SUPPORT/uninstall.sh"
cp "$HERE/selftest.sh" "$SUPPORT/selftest.sh"
"$BIN" --version >/dev/null
say "   $APP"

say "== 3/3 Registering the helper with your browsers / 向浏览器登记读取助手"
manifest() {
  cat <<JSON
{
  "name": "$HOST_NAME",
  "description": "iPhone 照片插件读取助手 / iPhone Photos helper",
  "path": "$BIN",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXT_ID/"]
}
JSON
}
AS="$HOME/Library/Application Support"
registered=0
for browser in "Google/Chrome" "Google/Chrome Beta" "Google/Chrome Dev" "Google/Chrome Canary" "Chromium" \
               "Microsoft Edge" "BraveSoftware/Brave-Browser" "Vivaldi" "Arc/User Data"; do
  if [ -d "$AS/$browser" ] || { [ "$browser" = "Google/Chrome" ] && [ $registered -eq 0 ]; }; then
    mkdir -p "$AS/$browser/NativeMessagingHosts"
    manifest > "$AS/$browser/NativeMessagingHosts/$HOST_NAME.json"
    say "   $browser"
    registered=$((registered + 1))
  fi
done

# Version 0.1 used Python. Its files are no longer used; they are only removed when you ask.
# 0.1 版用的是 Python，那些文件已经用不到了；只有你要求时才删除。
if [ -d "$SUPPORT/venv" ] || [ -f "$SUPPORT/host.py" ]; then
  if [ "${1:-}" = "--remove-python" ]; then
    rm -rf "$SUPPORT/venv" "$SUPPORT/host.py" "$SUPPORT/run_host.sh" "$SUPPORT/requirements.txt"
    say "   Removed the old Python helper / 已删除旧的 Python 版读取助手"
  else
    say ""
    say "The old Python helper (0.1) is still in $SUPPORT but no longer used."
    say "To free the space: bash install.sh --remove-python"
    say "旧的 Python 版读取助手（0.1）还留在上面这个文件夹里，已经不再使用。"
    say "想腾出空间可以运行：bash install.sh --remove-python"
  fi
fi

say ""
say "Done! If the iPhone Photos page is open, close it and click the extension icon again."
say "完成！如果 iPhone 照片页面开着，关掉它，再点一次工具栏里的插件图标。"
say "Test without Chrome (iPhone plugged in and unlocked): bash selftest.sh"
say "不开 Chrome 先测试（插好并解锁 iPhone）：bash selftest.sh"
