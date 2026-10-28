#!/bin/bash
# 一键编译全部工具。需要 Xcode Command Line Tools（swiftc + clang）。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p bin

echo "[1/4] usbmapd（事件驱动映射守护）"
clang -O2 -Wall -o bin/usbmapd src/usbmapd.c \
  -framework IOKit -framework CoreFoundation

echo "[2/4] hidwatch"
swiftc -O -o bin/hidwatch src/hidwatch.swift -framework IOKit

echo "[3/4] serialkeyd"
swiftc -O -o bin/serialkeyd src/serialkeyd.swift \
  -framework CoreGraphics -framework ApplicationServices

echo "[4/4] djimicd.app（CoreBluetooth 需要 Info.plist，裸二进制会被 TCC 直接终止）"
APP="bin/DJIMicKey.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp src/Info.plist "$APP/Contents/Info.plist"
swiftc -O -o "$APP/Contents/MacOS/djimicd" src/djimicd.swift \
  -framework CoreBluetooth -framework CoreGraphics -framework ApplicationServices
codesign --force --sign - --identifier com.lmf.djimicd "$APP" >/dev/null 2>&1 || true

cat > bin/djimicd <<'SH'
#!/bin/sh
# 通过 bundle 内二进制运行，保证 TCC 能读到 Info.plist
exec "$(cd "$(dirname "$0")" && pwd)/DJIMicKey.app/Contents/MacOS/djimicd" "$@"
SH
chmod +x bin/djimicd

echo
echo "完成："
ls -lh bin/usbmapd bin/hidwatch bin/serialkeyd bin/djimicd | awk '{printf "  %-28s %s\n", $9, $5}'
echo "  bin/DJIMicKey.app"
