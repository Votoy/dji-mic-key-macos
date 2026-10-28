#!/bin/bash
# volwatch.sh — 判断"按一下发射器配对键"是否被 macOS 识别为音量键
#
# 原理：如果按键真的以 HID Consumer(Volume Increment) 形式到达系统，
#       系统输出音量会变化。本脚本每 0.3 秒采样一次音量，变化即打印时间戳。
#       只用 osascript 的 StandardAdditions，不需要辅助功能/输入监控权限。
#
# 用法：./scripts/volwatch.sh 30      # 监听 30 秒，期间按一下发射器配对键

DURATION=${1:-30}
prev=$(osascript -e 'output volume of (get volume settings)' 2>/dev/null)

if [ -z "$prev" ]; then
  echo "读取音量失败（可能是 osascript 被拦截）"
  exit 1
fi

echo "起始音量：$prev"
echo "现在开始监听 ${DURATION} 秒 —— 请在此期间按一下发射器侧面的「连接/配对键」（短按一次）。"
echo "请排除其他音量来源；无音量变化仅表示本次未观测到变化，不能排除 HID 或 BLE 事件。"
echo

end=$((SECONDS + DURATION))
changes=0
while [ $SECONDS -lt $end ]; do
  cur=$(osascript -e 'output volume of (get volume settings)' 2>/dev/null)
  if [ -n "$cur" ] && [ "$cur" != "$prev" ]; then
    printf '[%s] 音量 %s → %s\n' "$(date +%H:%M:%S)" "$prev" "$cur"
    prev=$cur
    changes=$((changes + 1))
  fi
  sleep 0.3
done

echo
if [ $changes -eq 0 ]; then
  echo "结果：${DURATION} 秒内未观测到音量变化（音量上限、输出设备或映射等也可能影响结果）。"
else
  echo "结果：捕获到 ${changes} 次音量变化 —— 按键确实以音量键形式上报。"
fi
