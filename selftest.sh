#!/bin/bash
# 不经过 Chrome，直接测：连接 iPhone、列出最新 20 项、生成缩略图分别要多久
APP_DIR="$HOME/Library/Application Support/iPhonePhotosHelper"
if [ ! -x "$APP_DIR/venv/bin/python" ]; then echo "请先运行 bash install.sh"; exit 1; fi
"$APP_DIR/venv/bin/python" "$APP_DIR/host.py" --selftest "$@"
