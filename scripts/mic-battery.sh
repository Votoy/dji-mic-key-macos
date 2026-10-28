#!/bin/bash
# mic-battery.sh — 在 Mac 上直接读取 DJI Mic 发射器电量
#
# 原理：接收器通过 USB 暴露一个厂商自定义接口，DJI 的 DUML 协议在其上
#       上报各发射器的状态（电量、充电状态、输入电平）。
#       本脚本调用开源项目 usokawa/dji-mic-mo 读取并解析。
#
# 用法：
#   ./scripts/mic-battery.sh
#
# 首次运行会自动创建 venv 并安装 pyusb（约 5 MB），并缓存读取脚本。

set -u
cd "$(dirname "$0")/.."

SUPPORT="$HOME/Library/Application Support/DJIMicKey"
VENV="$SUPPORT/venv"
READER="$SUPPORT/dji-mic-mo.py"
TMP=$(mktemp -t micbat)

mkdir -p "$SUPPORT"

# 1. 准备 Python 环境
if [ ! -x "$VENV/bin/python3" ]; then
    echo "首次运行，正在准备环境…"
    python3 -m venv "$VENV" >/dev/null 2>&1 || { echo "创建 venv 失败"; exit 1; }
    "$VENV/bin/pip" -q install pyusb >/dev/null 2>&1 || { echo "安装 pyusb 失败"; exit 1; }
fi

# 2. 准备读取脚本（BSD-2-Clause，见 usokawa/dji-mic-mo）
if [ ! -f "$READER" ]; then
    echo "下载读取脚本…"
    curl -fsSL -o "$READER" \
        https://raw.githubusercontent.com/usokawa/dji-mic-mo/main/dji-mic-mo.py \
        || { echo "下载失败，请检查网络"; exit 1; }
fi

# 3. 接收器在不在
if ! ioreg -r -c IOHIDDevice -l -w0 2>/dev/null | grep -q '"ProductID" = 16401'; then
    echo "未检测到接收器。请先把 DJI 接收器插到 Mac 上。"
    exit 1
fi

# 4. 采集 10 秒状态（脚本只在状态变化时输出，发射器状态通常要几秒才上报）
"$VENV/bin/python3" "$READER" > "$TMP" 2>/dev/null &
PID=$!
sleep 5
kill $PID 2>/dev/null
wait $PID 2>/dev/null

# 5. 取最后一个完整快照并解析
"$VENV/bin/python3" - "$TMP" <<'PY'
import json, sys

raw = open(sys.argv[1]).read()
dec = json.JSONDecoder()
i, objs = 0, []
while i < len(raw):
    while i < len(raw) and raw[i].isspace():
        i += 1
    if i >= len(raw):
        break
    try:
        o, j = dec.raw_decode(raw, i)
        objs.append(o)
        i = j
    except json.JSONDecodeError:
        break

if not objs:
    print("没有读到状态。可能是接收器正被其他程序占用，稍后再试。")
    sys.exit(1)

snap = None
for o in reversed(objs):
    if any(isinstance(o.get(k), dict) and "batteryLevel" in o[k]
           for k in ("tx1", "tx2", "tx")):
        snap = o
        break

if snap is None:
    print("拿到状态，但还没有收到电量。请确认发射器已开机并与接收器连接（绿灯常亮）。")
    sys.exit(1)
LABEL = {1: "满电", 2: "良好", 3: "中等", 4: "一半", 5: "偏低", 6: "低", 7: "极低"}

found = False
for key in ("tx1", "tx2", "tx"):
    node = snap.get(key)
    if not isinstance(node, dict) or "batteryLevel" not in node:
        continue
    found = True
    lvl = node["batteryLevel"]
    name = node.get("deviceName", "发射器")
    sn = node.get("serialNumber", "")
    charge = "充电中" if node.get("charging") else "未充电"
    label = LABEL.get(lvl, "未知")
    print(f"  {name}  电量 {lvl}/7（{label}）  {charge}")
    if sn:
        print(f"    序列号 {sn}  ·  固件 {node.get('firmwareVersion', '-')}")
    if "inputLevel" in node:
        print(f"    当前输入电平 {node['inputLevel']}")

if not found:
    print("解析到了电量之外的状态，但没有可用字段。")
    sys.exit(1)
PY

rm -f "$TMP"
