#!/bin/bash
# Test without Chrome: connect to the iPhone, list photos, time thumbnails and a preview, show what metadata the phone gives.
# Plug in and unlock the iPhone first; it waits up to 2 minutes for one.
# 不经过 Chrome 直接测试：连接 iPhone、列出照片、测缩略图和放大预览的耗时、看手机提供哪些元数据。
# 先插好并解锁 iPhone；没插的话最多等 2 分钟。
#   bash selftest.sh                       # the connected iPhone / 插着的 iPhone
#   bash selftest.sh --mock /path/folder   # a folder with a DCIM subfolder / 含 DCIM 子文件夹的本地文件夹
HELPER="$HOME/Library/Application Support/iPhonePhotosHelper/iPhonePhotosHelper.app/Contents/MacOS/iphone-photos-helper"
if [ ! -x "$HELPER" ]; then
  echo "The helper is not installed yet. Run: bash install.sh / 还没安装读取助手，请先运行：bash install.sh"
  exit 1
fi
"$HELPER" --selftest "$@"
