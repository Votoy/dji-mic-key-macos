#!/bin/bash
# install-autostart.sh — 让状态栏图标在登录时自动出现
#
# 用法：
#   ./modules/statusbar/scripts/install-autostart.sh           # 安装
#   ./modules/statusbar/scripts/install-autostart.sh --remove  # 移除

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
LABEL="com.lmf.djimicstatus"
APP="$HOME/Applications/DJI Mic Status.app"
BIN="$APP/Contents/MacOS/DJIMicStatus"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [ "${1:-}" = "--remove" ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "已移除开机自启（应用本身仍保留在 ~/Applications）。"
    exit 0
fi

if [ ! -x "$BIN" ]; then
    echo "找不到应用：$BIN"
    echo "请先执行 ./modules/statusbar/scripts/build-status.sh"
    exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__APP_PATH__|$BIN|" "$ROOT/modules/statusbar/launchd/$LABEL.plist" > "$PLIST"
plutil -lint "$PLIST" >/dev/null

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "已安装开机自启：$PLIST"
echo "下次登录会自动启动；现在如需立即启动：open \"$APP\""
