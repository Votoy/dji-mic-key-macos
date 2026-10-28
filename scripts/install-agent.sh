#!/bin/bash
# install-agent.sh — 安装事件驱动的按键映射守护
#
# 做的事：
#   1. 编译并复制 usbmapd 到 ~/Library/Application Support/DJIMicKey/
#   2. 用实际路径渲染 LaunchAgent 到 ~/Library/LaunchAgents/
#   3. 加载并启动（事件驱动：平时 0% CPU，插拔时唤醒）
#
# 卸载：./scripts/uninstall-agent.sh

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

SUPPORT_DIR="$HOME/Library/Application Support/DJIMicKey"
AGENT_DIR="$HOME/Library/LaunchAgents"
LABEL="com.lmf.djimic-hidutil"
PLIST="$AGENT_DIR/$LABEL.plist"
BIN="$SUPPORT_DIR/usbmapd"

mkdir -p "$SUPPORT_DIR" "$AGENT_DIR"

# 没有二进制就先编译
if [ ! -x "$ROOT/bin/usbmapd" ]; then
  echo "编译 usbmapd…"
  clang -O2 -Wall -o "$ROOT/bin/usbmapd" "$ROOT/src/usbmapd.c" \
    -framework IOKit -framework CoreFoundation
fi

cp "$ROOT/bin/usbmapd" "$BIN"
cp "$ROOT/scripts/apply-map.sh" "$SUPPORT_DIR/apply-map.sh"
chmod +x "$BIN" "$SUPPORT_DIR/apply-map.sh"

sed "s|__BIN_PATH__|$BIN|" "$ROOT/launchd/$LABEL.plist" > "$PLIST"
plutil -lint "$PLIST" >/dev/null

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || true

sleep 2
echo "已安装："
echo "  守护  $BIN"
echo "  自启  $PLIST"
echo
if launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -q "state = running"; then
  echo "状态：运行中（事件驱动，插拔接收器时自动恢复映射）"
else
  echo "状态：未在运行，请检查 $PLIST"
fi
echo
echo "当前映射："
"$SUPPORT_DIR/apply-map.sh" --status 2>/dev/null | sed 's/^/  /'
