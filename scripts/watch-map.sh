#!/bin/bash
# watch-map.sh — 常驻循环，每秒把接收器的音量键重新映射为右 Command
#
# 为什么不用 launchd 的 StartInterval：
#   launchd 对高频 StartInterval 有节流，实测 30 秒间隔会让拔插后要等半分钟。
#   改成常驻进程自己 sleep，间隔完全可控，且单次 hidutil 仅约 11 ms。
#
# 仅供手动调试；当前 LaunchAgent 使用 usbmapd，不使用本脚本。

set -u
VENDOR=11427
PRODUCT=16401
MATCH="{\"VendorID\":$VENDOR,\"ProductID\":$PRODUCT}"
MAP='{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0xC000000E9,"HIDKeyboardModifierMappingDst":0x7000000E7},{"HIDKeyboardModifierMappingSrc":0xC000000EA,"HIDKeyboardModifierMappingDst":0x7000000E7}]}'

INTERVAL=1

# 退出时清理：保持映射即可，不需要额外动作
trap 'exit 0' TERM INT

while true; do
    # 设备不在时这条命令只是快速失败，开销可忽略
    hidutil property --matching "$MATCH" --set "$MAP" >/dev/null 2>&1
    sleep "$INTERVAL"
done
