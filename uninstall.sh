#!/bin/bash
# Remove the helper, its cache and log. Never touches the phone or photos already exported to Downloads.
# 卸载读取助手、缓存和日志。不会动手机，也不会删已经导出到“下载”的照片。
HOST_NAME="com.song.iphone_photos"
AS="$HOME/Library/Application Support"
for browser in "Google/Chrome" "Google/Chrome Beta" "Google/Chrome Dev" "Google/Chrome Canary" "Chromium" \
               "Microsoft Edge" "BraveSoftware/Brave-Browser" "Vivaldi" "Arc/User Data"; do
  rm -f "$AS/$browser/NativeMessagingHosts/$HOST_NAME.json"
done
rm -rf "$AS/iPhonePhotosHelper" "$HOME/Library/Caches/iPhonePhotosHelper"
rm -f "$HOME/Library/Logs/iPhonePhotosHelper.log"*
echo "Removed the helper. / 已卸载读取助手。"
echo "Remove the extension itself in chrome://extensions. / 插件本身请在 chrome://extensions 里移除。"
