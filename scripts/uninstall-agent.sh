#!/bin/bash
# uninstall-agent.sh — 卸载开机自启，并恢复音量键原始行为

set -u
LABEL="com.lmf.djimic-hidutil"
SUPPORT_DIR="$HOME/Library/Application Support/DJIMicKey"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

# 恢复音量键原始行为（设备在线时才有意义）
hidutil property --matching '{"VendorID":11427,"ProductID":16401}' \
  --set '{"UserKeyMapping":[]}' >/dev/null 2>&1 || true

rm -f "$PLIST"
rm -rf "$SUPPORT_DIR"

echo "已卸载自启，映射已清除。"
echo "若接收器仍插着，音量键已恢复为原功能。"
