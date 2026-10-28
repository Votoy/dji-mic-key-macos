#!/bin/bash
# build-status.sh — 构建并安装状态栏电量图标
#
# 产物：~/Applications/DJI Mic Status.app
# 依赖：swiftc（命令行工具即可），不需要 Xcode

set -euo pipefail
# 仓库根目录（本脚本位于 modules/statusbar/scripts/）
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"

APP_NAME="DJI Mic Status"
BUNDLE="$ROOT/bin/DJIMicStatus.app"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

echo "[1/3] 编译"
swiftc -O -o "$BUNDLE/Contents/MacOS/DJIMicStatus" \
  "$ROOT/modules/statusbar/src/statusbattery.swift" -framework AppKit

echo "[2/3] 打包"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DJIMicStatus</string>
    <key>CFBundleIdentifier</key><string>com.lmf.djimicstatus</string>
    <key>CFBundleName</key><string>DJI Mic Status</string>
    <key>CFBundleDisplayName</key><string>DJI Mic Status</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

cp scripts/mic-battery.sh "$BUNDLE/Contents/Resources/mic-battery.sh"
chmod +x "$BUNDLE/Contents/Resources/mic-battery.sh"
codesign --force --sign - --identifier com.lmf.djimicstatus "$BUNDLE" >/dev/null 2>&1 || true

echo "[3/3] 安装到 ~/Applications"
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/$APP_NAME.app"
cp -R "$BUNDLE" "$HOME/Applications/$APP_NAME.app"

# 移除旧的桌面悬浮版
pkill -f DJIMicBattery 2>/dev/null || true
rm -rf "$HOME/Applications/DJI Mic Battery.app"

echo
echo "完成：$HOME/Applications/$APP_NAME.app"
echo "启动：open \"$HOME/Applications/$APP_NAME.app\""
echo "退出：点图标 → 退出（或 pkill -f DJIMicStatus）"
