#!/bin/bash
# press-test.sh — 一次性判定「蓝牙直连时，连接键到底有没有产生任何信号」
#
# 同时监测两条路：
#   1) 系统音量是否跳变（=按键被当成 HID 音量键）
#   2) 蓝牙串口是否冒出新的帧型（=按键走了 SPP 控制通道）
#
# 用法：
#   ./scripts/press-test.sh          # 默认 20 秒
#   ./scripts/press-test.sh 30
#
# 期间请短按一次发射器侧面的连接键（不要长按，长按 2 秒会进配对模式）。

set -u
cd "$(dirname "$0")/.."
DURATION=${1:-20}
ROOT=$(pwd)
SERIAL="$ROOT/bin/serialkeyd"
LOG=$(mktemp -t press-test 2>/dev/null) || LOG="/tmp/press-test-$$.log"
: > "$LOG"

if [ ! -x "$SERIAL" ]; then
  echo "缺少 bin/serialkeyd，先执行 ./scripts/build.sh"
  exit 1
fi

PORT=$(ls /dev/cu.* 2>/dev/null | grep -i dji | head -1)
if [ -z "$PORT" ]; then
  echo "没找到 DJI 蓝牙串口。请先在 系统设置 → 蓝牙 里确认发射器已连接。"
  exit 1
fi

BASE_VOL=$(osascript -e 'output volume of (get volume settings)' 2>/dev/null)
echo "串口：$PORT"
echo "音量基线：$BASE_VOL"
echo

"$SERIAL" monitor --port "$PORT" > "$LOG" 2>&1 &
MON_PID=$!
sleep 1

echo "=============================================="
echo " 现在开始 ${DURATION} 秒计时"
echo " 请短按一次发射器侧面的「连接/配对键」"
echo " 按完就等着，不要重复按"
echo "=============================================="
echo

END=$((SECONDS + DURATION))
CHANGES=0
prev=$BASE_VOL
last_left=-1
while [ $SECONDS -lt $END ]; do
  left=$((END - SECONDS))
  cur=$(osascript -e 'output volume of (get volume settings)' 2>/dev/null)
  if [ -n "$cur" ] && [ "$cur" != "$prev" ]; then
    printf '\r  [%s] 音量 %s → %s   <<< 按键被识别\n' "$(date +%H:%M:%S)" "$prev" "$cur"
    prev=$cur
    CHANGES=$((CHANGES + 1))
  fi
  if [ "$left" != "$last_left" ]; then
    printf '\r  剩余 %2d 秒…' "$left"
    last_left=$left
  fi
  sleep 0.3
done
printf '\r                              \r'

sleep 1
kill $MON_PID 2>/dev/null
wait $MON_PID 2>/dev/null

echo
echo "================ 判定 ================"
NEWSIG=$(grep -c "NEW SIG" "$LOG" 2>/dev/null)
NEWSIG=${NEWSIG:-0}
MAXKB=$(grep -o "[0-9.]* KB/s" "$LOG" 2>/dev/null | awk '{print $1}' | sort -rn | head -1)
MAXKB=${MAXKB:-0}
MAXPPS=$(grep -o "[0-9]* 帧/s" "$LOG" 2>/dev/null | awk '{print $1}' | sort -rn | head -1)
MAXPPS=${MAXPPS:-0}

echo "音量变化次数：$CHANGES"
echo "串口峰值速率：${MAXKB} KB/s，${MAXPPS} 帧/s"
echo "串口新帧型  ：${NEWSIG} 个"
if [ "$NEWSIG" -gt 0 ]; then
  echo "--- 新帧型明细 ---"
  grep "NEW SIG" "$LOG"
fi
echo

if [ "$CHANGES" -gt 0 ]; then
  echo "结论 A：按键以「音量键」形式到达了系统。"
  echo "        → 可以直接用 Karabiner 映射为右 Command。"
elif [ "$NEWSIG" -gt 0 ]; then
  echo "结论 B：串口出现新帧型，按键很可能走了蓝牙串口控制通道。"
  echo "        → 把上面 [NEW SIG] 那行的前几个字节发我，我给你写死匹配规则。"
elif awk "BEGIN{exit !($MAXKB+0 > 0 || $MAXPPS+0 > 0)}"; then
  echo "结论 C：串口有数据但不是新帧型，需要进一步比对。"
  echo "        → 把 $LOG 发我。"
else
  echo "结论 D：本次测试未观察到系统音量变化或串口数据。"
  echo "        → 仅覆盖当前连接状态和这两条通道，不能排除其他 BLE/GATT 或握手方案。"
  echo "        → 已验证的替代方案是 USB 接收器映射。"
fi

echo
echo "完整日志：$LOG"
