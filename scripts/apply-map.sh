#!/bin/bash
# apply-map.sh — 把 DJI Mic 接收器（Wireless Mic Rx）的音量键映射为右 Command
#
# 设备：VendorID 11427 (0x2CA3) / ProductID 16401 (0x4011)
# 源：HID Consumer 0xE9 (Volume Increment) / 0xEA (Volume Decrement)
# 目标：HID Keyboard 0xE7 (Right GUI = 右 Command)
#
# 用法：
#   ./scripts/apply-map.sh            # 应用映射（设备不在时静默跳过）
#   ./scripts/apply-map.sh --status   # 查看当前映射
#   ./scripts/apply-map.sh --reset    # 清除映射，恢复音量键原始行为
#
# 说明：hidutil 的映射是易失的，设备重新插拔或重启后需要重新应用。
#       长期使用请加载 launchd/com.lmf.djimic-hidutil.plist。

set -u
VENDOR=11427
PRODUCT=16401
MATCH="{\"VendorID\":$VENDOR,\"ProductID\":$PRODUCT}"
MAP='{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":0xC000000E9,"HIDKeyboardModifierMappingDst":0x7000000E7},{"HIDKeyboardModifierMappingSrc":0xC000000EA,"HIDKeyboardModifierMappingDst":0x7000000E7}]}'

case "${1:-}" in
  --reset)
    hidutil property --matching "$MATCH" --set '{"UserKeyMapping":[]}' >/dev/null 2>&1
    echo "已清除映射，音量键恢复原始行为。"
    exit 0
    ;;
  --status)
    hidutil property --matching "$MATCH" --get UserKeyMapping 2>&1
    exit 0
    ;;
esac

# 设备是否在线（用十进制 ProductID 判断，注册表里不写十六进制）
if ! ioreg -r -c IOHIDDevice -l -w0 2>/dev/null | grep -q "\"ProductID\" = $PRODUCT"; then
  exit 0   # 接收器没插，直接跳过，不报错
fi

hidutil property --matching "$MATCH" --set "$MAP" >/dev/null 2>&1 && exit 0 || exit 1
