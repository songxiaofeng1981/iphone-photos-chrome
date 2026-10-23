#!/bin/bash
# 卸载读取助手（不会动手机，也不会删已经导出到“下载”的照片）
HOST_NAME="com.song.iphone_photos"
for d in "$HOME/Library/Application Support/Google/Chrome" "$HOME/Library/Application Support/Google/Chrome Beta" "$HOME/Library/Application Support/Chromium"; do
  rm -f "$d/NativeMessagingHosts/$HOST_NAME.json"
done
rm -rf "$HOME/Library/Application Support/iPhonePhotosHelper" "$HOME/Library/Caches/iPhonePhotosHelper"
rm -f "$HOME/Library/Logs/iPhonePhotosHelper.log"*
echo "已卸载读取助手。插件本身请在 chrome://extensions 里移除。"
