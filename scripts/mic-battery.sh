#!/bin/bash
# mic-battery.sh — 在 Mac 上直接读取 DJI Mic 发射器电量
#
# 原理：接收器通过 USB 暴露一个厂商自定义接口，DJI 的 DUML 协议在其上
#       上报各发射器的状态（电量、充电状态、输入电平）。
#       本脚本调用开源项目 usokawa/dji-mic-mo 读取并解析。
#
# 用法：
#   ./scripts/mic-battery.sh           # 人类可读
#   ./scripts/mic-battery.sh --json    # 输出 JSON（供小组件调用）
#
# 首次运行会自动创建 venv 并安装 pyusb（约 5 MB），并缓存读取脚本。

set -u
MODE="${1:-text}"
[ "$MODE" = "--json" ] && MODE="json"

SUPPORT="$HOME/Library/Application Support/DJIMicKey"
VENV="$SUPPORT/venv"
READER="$SUPPORT/dji-mic-mo.py"
TMP=$(mktemp -t micbat) || exit 1
PID=""
cleanup() {
    if [ -n "$PID" ]; then
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    rm -f "$TMP" "${TMP}.reader"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 进度信息一律走 stderr，保证 stdout 只有结果
say() { echo "$@" >&2; }

mkdir -p "$SUPPORT"

# 1. 准备 Python 环境
if [ ! -x "$VENV/bin/python3" ]; then
    say "首次运行，正在准备环境…"
    python3 -m venv "$VENV" >/dev/null 2>&1 || { say "创建 venv 失败"; exit 1; }
    "$VENV/bin/pip" -q install pyusb >/dev/null 2>&1 || { say "安装 pyusb 失败"; exit 1; }
fi

# 2. 准备读取脚本（BSD-2-Clause，见 usokawa/dji-mic-mo）
if [ ! -f "$READER" ]; then
    say "下载读取脚本…"
    curl -fsSL --connect-timeout 10 --max-time 60 -o "${TMP}.reader" \
        https://raw.githubusercontent.com/usokawa/dji-mic-mo/7c2dd5b0262f35b475193224fca2681d75987e9c/dji-mic-mo.py \
        || { say "下载失败，请检查网络"; exit 1; }
    READER_SOURCE="${TMP}.reader"
else
    READER_SOURCE="$READER"
fi
EXPECTED_SHA256="df29abdf2344a880863f1f55ec61cbb8ca59302cecbdc4724258833d99a601d4"
ACTUAL_SHA256=$(shasum -a 256 "$READER_SOURCE" | cut -d ' ' -f 1)
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
    say "读取脚本校验失败；已保留现有缓存，请检查第三方版本。"
    exit 1
fi
if [ "$READER_SOURCE" != "$READER" ]; then
    mv "$READER_SOURCE" "$READER" || exit 1
fi

# 3. 接收器在不在
if ! ioreg -r -c IOHIDDevice -l -w0 2>/dev/null | grep -q '"ProductID" = 16401'; then
    say "未检测到接收器。请先把 DJI 接收器插到 Mac 上。"
    exit 1
fi

# 4. 采集状态：等电量字段出现，最多 12 秒；进程提前退出则立即结束
# 上游支持从 stdin 接收设备配置；禁用该输入，且只管理本次创建的子进程。
# 上游仍可能设置 USB 配置、声明接口，不能视为绝对只读。
"$VENV/bin/python3" "$READER" < /dev/null > "$TMP" 2>/dev/null &
PID=$!
for _ in $(seq 1 24); do
    grep -Eq '"batteryLevel"[[:space:]]*:[[:space:]]*[1-7]([,[:space:]]|$)' "$TMP" 2>/dev/null && break
    kill -0 $PID 2>/dev/null || break
    sleep 0.5
done
kill $PID 2>/dev/null
wait $PID 2>/dev/null
PID=""

# 5. 取最近的、带电量字段的快照并解析
"$VENV/bin/python3" - "$TMP" "$MODE" <<'PY'
import json, sys

path, mode = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "text")

raw = open(path).read()
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

snap = None
for o in reversed(objs):
    if isinstance(o, dict) and any(
        isinstance(o.get(k), dict) and type(o[k].get("batteryLevel")) is int
        and 1 <= o[k]["batteryLevel"] <= 7 for k in ("tx1", "tx2", "tx")
    ):
        snap = o
        break

if snap is None:
    if mode != "json":
        print("拿到状态，但还没有收到电量。请确认发射器已开机并与接收器连接（绿灯常亮）。")
    sys.exit(1)

node = None
for k in ("tx1", "tx2", "tx"):
    n = snap.get(k)
    if (isinstance(n, dict) and type(n.get("batteryLevel")) is int
            and 1 <= n["batteryLevel"] <= 7):
        node = n
        break

LABEL = {1: "满电", 2: "良好", 3: "中等", 4: "一半", 5: "偏低", 6: "低", 7: "极低"}
level = node["batteryLevel"]
name = node.get("deviceName", "发射器")

if mode == "json":
    print(json.dumps({
        "level": level,
        "label": LABEL.get(level, "未知"),
        "charging": bool(node.get("charging")),
        "name": name,
        "serial": node.get("serialNumber", ""),
        "firmware": node.get("firmwareVersion", ""),
        "inputLevel": node.get("inputLevel"),
    }, ensure_ascii=False))
    sys.exit(0)

charge = "充电中" if node.get("charging") else "未充电"
print(f"  {name}  电量 {level}/7（{LABEL.get(level, '未知')}）  {charge}")
if node.get("serialNumber"):
    print(f"    序列号 {node['serialNumber']}  ·  固件 {node.get('firmwareVersion', '-')}")
if "inputLevel" in node:
    print(f"    当前输入电平 {node['inputLevel']}")
PY

STATUS=$?
rm -f "$TMP"
exit $STATUS
