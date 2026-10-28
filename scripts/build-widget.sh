#!/bin/bash
# build-widget.sh — 构建并安装桌面悬浮电量小组件
#
# 产物：~/Applications/DJI Mic Battery.app
# 依赖：clang / swiftc（命令行工具即可），不需要 Xcode

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="DJI Mic Battery"
BUNDLE="bin/DJIMicBattery.app"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

echo "[1/3] 编译"
swiftc -O -o "$BUNDLE/Contents/MacOS/DJIMicBattery" src/batterywidget.swift \
  -framework AppKit

echo "[2/3] 打包"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>DJIMicBattery</string>
    <key>CFBundleIdentifier</key><string>com.lmf.djimicbattery</string>
    <key>CFBundleName</key><string>DJI Mic Battery</string>
    <key>CFBundleDisplayName</key><string>DJI Mic Battery</string>
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
codesign --force --sign - --identifier com.lmf.djimicbattery "$BUNDLE" >/dev/null 2>&1 || true

echo "[3/3] 安装到 ~/Applications"
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/$APP_NAME.app"
cp -R "$BUNDLE" "$HOME/Applications/$APP_NAME.app"

echo
echo "完成：$HOME/Applications/$APP_NAME.app"
echo
echo "启动：open \"$HOME/Applications/$APP_NAME.app\""
echo "退出：右键小组件 → 退出（或 pkill -f DJIMicBattery）"
