#!/bin/bash
# 安装 iPhone 照片插件的读取助手（只需运行一次）
set -euo pipefail
HOST_NAME="com.song.iphone_photos"
EXT_ID="endldjnpicempoibdmlndkiinmmekggn"
APP_DIR="$HOME/Library/Application Support/iPhonePhotosHelper"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "== 1/4 查找 Python 3.10 以上版本"
PY=""
for c in /opt/homebrew/bin/python3 /usr/local/bin/python3 python3.13 python3.12 python3.11 python3.10 python3; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
    PY="$(command -v "$c")"; break
  fi
done
if [ -z "$PY" ]; then
  echo "没找到 Python 3.10 或更高版本（macOS 自带的是 3.9，不够用）。"
  echo "Python 3.10+ not found (the one bundled with macOS is 3.9)."
  echo
  echo "最简单的办法 / Easiest fix:"
  echo "  打开 https://www.python.org/downloads/macos/ ，下载最新的 macOS 安装包，双击安装，然后重新运行 bash install.sh"
  echo "  Download the latest macOS installer from https://www.python.org/downloads/macos/, install it, then run bash install.sh again."
  echo "开发者也可以用 / Developers can also use:  brew install python@3.12"
  exit 1
fi
echo "   使用 $PY ($("$PY" --version))"

echo "== 2/4 创建独立环境并安装依赖（第一次需要一两分钟）"
mkdir -p "$APP_DIR"
cp "$HERE/helper/host.py" "$APP_DIR/host.py"
cp "$HERE/helper/requirements.txt" "$APP_DIR/requirements.txt"
if [ ! -x "$APP_DIR/venv/bin/python" ]; then "$PY" -m venv "$APP_DIR/venv"; fi
"$APP_DIR/venv/bin/python" -m pip install -q --upgrade pip
"$APP_DIR/venv/bin/python" -m pip install -q -r "$APP_DIR/requirements.txt"

echo "== 3/4 写入启动脚本"
cat > "$APP_DIR/run_host.sh" <<RUN
#!/bin/bash
exec "$APP_DIR/venv/bin/python" "$APP_DIR/host.py" "\$@"
RUN
chmod +x "$APP_DIR/run_host.sh"

echo "== 4/4 向 Chrome 注册读取助手"
for d in "$HOME/Library/Application Support/Google/Chrome" "$HOME/Library/Application Support/Google/Chrome Beta" "$HOME/Library/Application Support/Chromium"; do
  if [ -d "$d" ]; then
    mkdir -p "$d/NativeMessagingHosts"
    cat > "$d/NativeMessagingHosts/$HOST_NAME.json" <<JSON
{
  "name": "$HOST_NAME",
  "description": "iPhone 照片插件读取助手",
  "path": "$APP_DIR/run_host.sh",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXT_ID/"]
}
JSON
    echo "   已注册到 $d"
  fi
done

echo
echo "安装完成。下一步："
echo "  1. Chrome 打开 chrome://extensions ，右上角打开“开发者模式”"
echo "  2. 点“加载已解压的扩展程序”，选择 $HERE/extension"
echo "  3. 插件 ID 应该是 $EXT_ID"
echo "  4. 插上 iPhone，点工具栏里的插件图标"
echo
echo "想先不开 Chrome、直接测速度：bash selftest.sh"
