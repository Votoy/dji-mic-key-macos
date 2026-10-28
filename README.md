# DJI Mic Mini 2 连接键 → macOS 右 Command

把 DJI Mic Mini 2 发射器侧面的「连接键」变成 Mac 键盘上的「右 Command」，用于一键唤起豆包输入法等语音输入工具。按一下开始说话，再按一下结束，全程不碰键盘。

- **状态**：已在本机验证通过（macOS 27.2，Apple Silicon）
- **依赖**：只用系统自带的 `hidutil`，无内核扩展、无第三方运行库、无需任何隐私权限
- **常驻开销**：内存 5.3 MB，CPU 0.00（事件驱动，不轮询）

---

## 目录

- [1. 背景](#1-背景)
- [2. 最终方案](#2-最终方案)
- [3. 硬件与环境](#3-硬件与环境)
- [4. 快速开始](#4-快速开始)
- [5. 完整实现代码](#5-完整实现代码)
- [6. 原理说明](#6-原理说明)
- [7. 验证步骤](#7-验证步骤)
- [8. 排错](#8-排错)
- [9. 查看电量](#9-查看电量)
- [10. 为什么不能用蓝牙直连](#10-为什么不能用蓝牙直连)
- [11. 诊断工具](#11-诊断工具)
- [12. 参考资料](#12-参考资料)

---

## 1. 背景

DJI Mic Mini 2 有几种连接方式，按键的去向完全不同：

| 发射器连接对象 | 连接键的作用 | 按键走哪条链路 |
|---|---|---|
| DJI 接收器（绿灯模式） | 接收器把它转成 USB HID 音量键 | 2.4 GHz 私有协议 → 接收器 → USB |
| DJI 相机（Action / Pocket） | 开始 / 停止录制 | 蓝牙 BLE + DUML |
| 手机（蓝灯模式） | 等同于音量键，可触发快门 | 经典蓝牙 HFP + HID |
| Mac（蓝牙直连） | **什么都不发生** | 无 HID 通道，见第 9 节 |

目标是在不增加额外硬件的前提下，让这个按键在 Mac 上产生一个可用的键盘事件。经过实测，**蓝牙直连这条路走不通**，最终方案是「接收器 + 设备级 HID 映射」。

---

## 2. 最终方案

```
        ┌─────────────────┐
        │  发射器 连接键   │
        └────────┬────────┘
                 │ 2.4 GHz 私有协议（GFSK 2Mbps）
                 ▼
        ┌─────────────────┐
        │  手机版接收器     │  DMMR02
        └────────┬────────┘
                 │ USB HID Consumer: Volume Increment (0xE9)
                 ▼
        ┌─────────────────┐
        │  macOS HID 系统  │
        └────────┬────────┘
                 │ hidutil 设备级映射（仅对 VID 11427 / PID 16401 生效）
                 ▼
        ┌─────────────────┐
        │  右 Command      │  HID Keyboard 0xE7
        └────────┬────────┘
                 ▼
        ┌─────────────────┐
        │  豆包输入法       │  快捷键设为「右 Command」
        └─────────────────┘
```

关键点：

1. **映射是设备级的**，只作用于 DJI 接收器，不碰 Mac 自带键盘。
2. **守护进程是事件驱动的**，平时阻塞在 `CFRunLoop`，只在接收器插入时被内核唤醒一次。
3. **音频顺带升级**：接收器走 USB 输出 48 kHz / 2 声道，比蓝牙 HFP 的 16 kHz / 1 声道好一档。

---

## 3. 硬件与环境

| 项 | 值 |
|---|---|
| 发射器 | DJI Mic Mini 2（DMMT02） |
| 接收器 | DJI Mic 系列手机版接收器（DMMR02，USB-C 公头） |
| 接收器 HID 标识 | `Wireless Mic Rx`，VendorID `11427` (0x2CA3)，ProductID `16401` (0x4011) |
| 系统 | macOS 27.2，Apple Silicon |
| 编译 | Xcode Command Line Tools（`clang`） |

> 手机版接收器的**母口是充电口**，只支持充电和模拟 USB-C 耳机监听，不是数据口。想接电脑只能用公头直插，或用一根「USB-C 公对母延长线」把接收器引出来。

---

## 4. 快速开始

```bash
git clone <this-repo> && cd dji-mic-bt-key

# 1. 编译（只需要 clang，无第三方依赖）
./scripts/build.sh

# 2. 安装守护：写入映射 + 注册开机自启
./scripts/install-agent.sh

# 3. 确认
./scripts/apply-map.sh --status
```

然后在豆包输入法里把语音输入快捷键设为 **右 Command**，按一下发射器连接键即可。

卸载：

```bash
./scripts/uninstall-agent.sh
```

---

## 5. 完整实现代码

### 5.1 核心守护进程 `src/usbmapd.c`

用 IOKit 的 `IOServiceAddMatchingNotification` 监听指定 VID/PID 的 HID 设备，设备出现时调用一次 `hidutil` 写入映射。平时阻塞在 `CFRunLoop`，CPU 占用为 0。

```c
// usbmapd.c — 事件驱动的 DJI 接收器按键映射守护进程
//
// 与 watch-map.sh 的区别：
//   watch-map.sh  常驻 + 每秒轮询，每秒唤醒一次 CPU
//   usbmapd       注册 IOKit 匹配通知，平时在 CFRunLoop 里完全阻塞（0% CPU），
//                 只在接收器插入 / 系统唤醒后设备重新枚举时才被唤醒一次
//
// 编译：
//   clang -O2 -Wall -o ../bin/usbmapd usbmapd.c -framework IOKit -framework CoreFoundation
//
// 用法：
//   usbmapd                常驻（LaunchAgent 用这个）
//   usbmapd --apply-only   只应用一次映射后退出
//   usbmapd --selftest 5   跑 5 秒后退出，用于测量内存占用
//
// 匹配：IOHIDDevice + VendorID 11427 (0x2CA3) + ProductID 16401 (0x4011)
// 映射：Consumer 0xE9/0xEA (音量±) → Keyboard 0xE7 (右 Command)

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define VENDOR_ID  11427
#define PRODUCT_ID 16401

static const char *kMatch =
    "{\"VendorID\":11427,\"ProductID\":16401}";

static const char *kMap =
    "{\"UserKeyMapping\":["
    "{\"HIDKeyboardModifierMappingSrc\":0xC000000E9,"
    "\"HIDKeyboardModifierMappingDst\":0x7000000E7},"
    "{\"HIDKeyboardModifierMappingSrc\":0xC000000EA,"
    "\"HIDKeyboardModifierMappingDst\":0x7000000E7}]}";

static volatile sig_atomic_t g_stop = 0;
static int g_quiet = 0;

static void on_signal(int sig) { (void)sig; g_stop = 1; }

// 报告本进程真实内存占用（不含 fork 出去的 hidutil）
static void print_footprint(void) {
    struct mach_task_basic_info info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                  (task_info_t)&info, &count) == KERN_SUCCESS) {
        fprintf(stderr, "本进程内存: 常驻 %.1f MB / 峰值 %.1f MB\n",
                (double)info.resident_size / 1048576.0,
                (double)info.resident_size_max / 1048576.0);
    }
}

// 调用系统自带的 hidutil 写入映射。单次约 11 ms。
static void apply_map(void) {
    pid_t pid = fork();
    if (pid == 0) {
        execl("/usr/bin/hidutil", "hidutil",
              "property", "--matching", kMatch,
              "--set", kMap, (char *)NULL);
        _exit(127);
    }
    if (pid > 0) {
        int status = 0;
        waitpid(pid, &status, 0);
        if (!g_quiet) {
            fprintf(stderr, "apply_map: hidutil exit=%d\n",
                    WIFEXITED(status) ? WEXITSTATUS(status) : -1);
        }
    }
}

// IOKit 第一次匹配通知的回调：排空迭代器，有设备就写映射。
static void device_matched(void *refcon, io_iterator_t iterator) {
    (void)refcon;
    int found = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        IOObjectRelease(service);
        found = 1;
    }
    if (found) {
        if (!g_quiet) fprintf(stderr, "device matched, applying map\n");
        apply_map();
    }
}

// 5 分钟兜底：应对睡眠唤醒后设备未重新枚举的情况。
static void safety_timer(CFRunLoopTimerRef timer, void *info) {
    (void)timer; (void)info;
    apply_map();
}

int main(int argc, char **argv) {
    int apply_only = 0;
    int selftest_seconds = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--apply-only") == 0) {
            apply_only = 1;
        } else if (strcmp(argv[i], "--quiet") == 0) {
            g_quiet = 1;
        } else if (strcmp(argv[i], "--selftest") == 0 && i + 1 < argc) {
            selftest_seconds = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--help") == 0) {
            printf("usage: usbmapd [--apply-only] [--quiet] [--selftest N]\n");
            return 0;
        }
    }

    if (apply_only) {
        apply_map();
        return 0;
    }

    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);

    IONotificationPortRef notify_port = IONotificationPortCreate(kIOMainPortDefault);
    if (!notify_port) {
        fprintf(stderr, "IONotificationPortCreate failed\n");
        return 1;
    }
    CFRunLoopSourceRef source = IONotificationPortGetRunLoopSource(notify_port);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);

    CFMutableDictionaryRef matching = IOServiceMatching("IOHIDDevice");
    if (!matching) {
        fprintf(stderr, "IOServiceMatching failed\n");
        return 1;
    }
    int vendor = VENDOR_ID;
    int product = PRODUCT_ID;
    CFNumberRef vnum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &vendor);
    CFNumberRef pnum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &product);
    CFDictionarySetValue(matching, CFSTR("VendorID"), vnum);
    CFDictionarySetValue(matching, CFSTR("ProductID"), pnum);
    CFRelease(vnum);
    CFRelease(pnum);

    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceAddMatchingNotification(
        notify_port, kIOFirstMatchNotification, matching, device_matched, NULL, &iterator);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "IOServiceAddMatchingNotification failed: 0x%x\n", kr);
        return 1;
    }

    // 首次调用会返回当前已存在的匹配设备，需要排空；
    // 若接收器已经插着，这一步会立刻写一次映射。
    device_matched(NULL, iterator);

    CFRunLoopTimerRef timer = NULL;
    if (selftest_seconds > 0) {
        CFRunLoopTimerContext ctx = {0, NULL, NULL, NULL, NULL};
        timer = CFRunLoopTimerCreate(kCFAllocatorDefault,
                                     CFAbsoluteTimeGetCurrent() + selftest_seconds,
                                     0, 0, 0, safety_timer, &ctx);
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
    } else {
        CFRunLoopTimerContext ctx = {0, NULL, NULL, NULL, NULL};
        timer = CFRunLoopTimerCreate(kCFAllocatorDefault,
                                     CFAbsoluteTimeGetCurrent() + 300.0,
                                     300.0, 0, 0, safety_timer, &ctx);
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
    }

    if (!g_quiet) fprintf(stderr, "usbmapd ready (event-driven)\n");

    while (!g_stop) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, true);
        if (selftest_seconds > 0) {
            static int elapsed = 0;
            elapsed++;
            if (elapsed >= selftest_seconds) break;
        }
    }

    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
    IOObjectRelease(iterator);
    IONotificationPortDestroy(notify_port);
    print_footprint();
    return 0;
}
```

### 5.2 一次性应用映射 `scripts/apply-map.sh`

```bash
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
```

### 5.3 安装自启 `scripts/install-agent.sh`

```bash
#!/bin/bash
# install-agent.sh — 安装事件驱动的按键映射守护
#
# 做的事：
#   1. 编译并复制 usbmapd 到 ~/Library/Application Support/DJIMicKey/
#   2. 用实际路径渲染 LaunchAgent 到 ~/Library/LaunchAgents/
#   3. 加载并启动（事件驱动：平时 0% CPU，插拔时唤醒）
#
# 卸载：./scripts/uninstall-agent.sh

set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)

SUPPORT_DIR="$HOME/Library/Application Support/DJIMicKey"
AGENT_DIR="$HOME/Library/LaunchAgents"
LABEL="com.lmf.djimic-hidutil"
PLIST="$AGENT_DIR/$LABEL.plist"
BIN="$SUPPORT_DIR/usbmapd"

mkdir -p "$SUPPORT_DIR" "$AGENT_DIR"

# 没有二进制就先编译
if [ ! -x "$ROOT/bin/usbmapd" ]; then
  echo "编译 usbmapd…"
  clang -O2 -Wall -o "$ROOT/bin/usbmapd" "$ROOT/src/usbmapd.c" \
    -framework IOKit -framework CoreFoundation
fi

cp "$ROOT/bin/usbmapd" "$BIN"
cp "$ROOT/scripts/apply-map.sh" "$SUPPORT_DIR/apply-map.sh"
chmod +x "$BIN" "$SUPPORT_DIR/apply-map.sh"

sed "s|__BIN_PATH__|$BIN|" "$ROOT/launchd/$LABEL.plist" > "$PLIST"
plutil -lint "$PLIST" >/dev/null

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || true

sleep 2
echo "已安装："
echo "  守护  $BIN"
echo "  自启  $PLIST"
echo
if launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -q "state = running"; then
  echo "状态：运行中（事件驱动，插拔接收器时自动恢复映射）"
else
  echo "状态：未在运行，请检查 $PLIST"
fi
echo
echo "当前映射："
"$SUPPORT_DIR/apply-map.sh" --status 2>/dev/null | sed 's/^/  /'
```

### 5.4 卸载 `scripts/uninstall-agent.sh`

```bash
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
```

### 5.5 LaunchAgent 模板 `launchd/com.lmf.djimic-hidutil.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.lmf.djimic-hidutil</string>

    <key>ProgramArguments</key>
    <array>
        <string>__BIN_PATH__</string>
        <string>--quiet</string>
    </array>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>ThrottleInterval</key>
    <integer>2</integer>

    <key>ProcessType</key>
    <string>Background</string>

    <key>StandardOutPath</key>
    <string>/tmp/djimic-hidutil.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/djimic-hidutil.err</string>
</dict>
</plist>
```

### 5.6 一键编译 `scripts/build.sh`

```bash
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
```

### 5.7 其他文件

| 文件 | 用途 |
|---|---|
| `scripts/mic-battery.sh` | 读取发射器电量（7 档）、充电状态与输入电平，支持 `--json` |
| `src/statusbattery.swift` | 状态栏电量图标（绿色圆环 + DJI 字样，AppKit，无需 Xcode） |
| `scripts/build-status.sh` | 编译并安装状态栏应用到 `~/Applications` |
| `scripts/watch-map.sh` | 轮询版守护（每秒一次），调试用，日常不需要 |
| `scripts/press-test.sh` | 一次性判定「按键有没有产生信号」（音量 + 蓝牙串口双通道） |
| `scripts/volwatch.sh` | 只监听系统音量变化，判断按键是否被当成音量键 |
| `karabiner/dji-mic-rx-to-right-command.json` | 备选的 Karabiner 规则（需驱动扩展） |
| `src/hidwatch.swift` | 列出所有 HID 设备并打印按键事件 |
| `src/serialkeyd.swift` | 读取蓝牙串口并检测新帧型 |
| `src/djimicd.swift` | BLE 扫描 / GATT 订阅 / 按键注入 |
| `src/Info.plist` | CoreBluetooth 用途声明（裸二进制缺它会崩溃） |

---

## 6. 原理说明

### 6.1 HID usage 对照

接收器上报的是 HID Consumer 页的音量键，映射目标在 HID Keyboard 页：

| 含义 | HID 编码 |
|---|---|
| 音量 +（源） | `0xC000000E9` = Page `0x0C` / Usage `0xE9` |
| 音量 -（源） | `0xC000000EA` = Page `0x0C` / Usage `0xEA` |
| 右 Command（目标） | `0x7000000E7` = Page `0x07` / Usage `0xE7` |

想换成别的键，改 `src/usbmapd.c` 里的 `kMap` 字符串，重新编译安装即可：

| 目标键 | 编码 |
|---|---|
| F13 | `0x70000068` |
| F14 | `0x70000069` |
| F15 | `0x7000006B` |
| 右 Option | `0x7000000E6` |
| 右 Control | `0x7000000E4` |

### 6.2 为什么用 hidutil 而不是 Karabiner

Karabiner-Elements 也能做这件事，但需要：安装系统扩展、允许内核扩展、授予「输入监控」权限、在 `devices` 里显式声明 `is_consumer: true`（否则它默认不接管消费者设备），最后还要在 GUI 里手动加规则。

`hidutil` 是系统自带命令，直接写 HID 系统属性，**零权限、零扩展**。代价是映射是易失的，设备重新枚举后要重新写一次——这正好由 `usbmapd` 解决。

### 6.3 为什么用 IOKit 事件而不是轮询

最早用 launchd 的 `StartInterval 30`，实测拔插后要等半分钟才恢复，期间按键还是音量键。改成 `sleep 1` 轮询后缩短到 1 秒，但仍会每秒唤醒一次 CPU。

最终改为 `IOServiceAddMatchingNotification`：内核在设备发布时回调，进程其余时间完全阻塞。实测内存 5.3 MB、CPU `0.00`，拔插后毫秒级恢复。

代码里还留了一个 300 秒的兜底定时器，用于应对「睡眠唤醒后设备没有重新枚举」的极端情况。

### 6.4 关于「按第三次发送」

有些开源方案用 Karabiner 状态机把同一个按键的多次按下解释成「开始听写 / 结束听写 / 发送回车」。本项目**没有做**，原因是：

- 豆包输入法自己维护录音的开关状态，再叠一层状态机会出现两套状态互相打架；
- 实际使用不需要自动发送，单键 1:1 映射更稳定、更容易排错。

如果确实需要「说完自动回车」，优先用输入法自带的选项，其次才是外挂宏工具。

---

## 7. 验证步骤

### 7.1 确认设备被识别

```bash
# 音频设备：应出现 Wireless Mic Rx，采样率 48000
system_profiler SPAudioDataType | grep -i -A6 "Mic Rx"

# HID 设备：应有 VendorID 11427 / ProductID 16401
ioreg -r -c IOHIDDevice -l -w0 | grep -B25 '"Product" = "Wireless Mic Rx"' \
  | grep -E '"VendorID"|"ProductID"|"Product"'
```

### 7.2 确认映射写入

```bash
./scripts/apply-map.sh --status
```

应看到两条 `HIDKeyboardModifierMappingSrc`（`51539607785` / `51539607786`，即 `0xC000000E9` / `0xC000000EA`），目标都是 `30064771303`（`0x7000000E7`）。

### 7.3 端到端

1. 打开任意输入框
2. 按一下发射器侧面的连接键
3. 豆包输入法应被唤起，同时系统音量**不应**变化

### 7.4 拔插恢复

拔掉接收器再插回，**立刻**按连接键，应直接生效（无需等待）。

---

## 8. 排错

按顺序排查：

```bash
# 1. 映射还在不在
hidutil property --matching '{"VendorID":11427,"ProductID":16401}' --get UserKeyMapping

# 2. 守护进程活没活
launchctl print gui/$(id -u)/com.lmf.djimic-hidutil

# 3. 有没有报错（plist 里带了 --quiet，正常时为空）
cat /tmp/djimic-hidutil.err

# 4. 手动补一次映射，能立刻恢复
./scripts/apply-map.sh
```

常见问题：

| 现象 | 原因 | 处理 |
|---|---|---|
| 按了调音量，豆包不动 | 映射丢了（设备重新枚举后未恢复） | `./scripts/apply-map.sh`，再检查守护 |
| 完全没反应 | 接收器没连上发射器 | 看接收器指示灯，应为绿色常亮 |
| 守护起不来 | plist 路径或权限问题 | `plutil -lint` 检查，重新 `install-agent.sh` |
| 重启后失效 | LaunchAgent 未加载 | `launchctl print` 确认，必要时重新安装 |

---

## 9. 查看电量

macOS 系统层不提供麦克风电量——IO 注册表里没有电池字段，系统信息里也看不到。大疆同样没有支持 Mic 系列的电脑端 App：DJI Mimo 只有移动端，DJI Studio 面向 Osmo 相机，DJI Assistant 2 面向无人机。

所以仓库里附了一个脚本，直接通过接收器的 USB 私有接口读取：

```bash
./scripts/mic-battery.sh
```

输出示例：

```
  DJI Mic Mini 2  电量 1/7（满电）  未充电
    序列号 B3MTP8B0153T03  ·  固件 02.03.17.00
    当前输入电平 40
```

说明：

- 电量等级 1 = 满电，7 = 极低，其余为中间档
- 首次运行会自动创建 venv、安装 `pyusb`、下载 `usokawa/dji-mic-mo` 的读取脚本（BSD-2-Clause）
- 采集约 5 秒，期间不影响音频输入
- 原理：接收器通过 USB 暴露一个厂商自定义接口，DJI 的 DUML 协议在其上报各发射器的电量、充电状态与输入电平

其他查看方式：

| 方式 | 精度 | 说明 |
|---|---|---|
| 本脚本 | 7 档 | Mac 上直接读，无需拔插 |
| DJI Mimo（手机） | 百分比 | 需把接收器插到手机，或让发射器蓝牙直连手机 |
| 接收器指示灯 | 两档 | 发射器状态灯：红 = 电量 0–10%，绿 = 高于 10% |

### 9.1 状态栏电量图标

系统级 WidgetKit 小组件需要 Xcode 工程、App Extension 与签名，因此这里改为状态栏图标：20×20 的绿色圆环，弧长表示电量，中间是 DJI 字样。

```bash
./scripts/build-status.sh
open "$HOME/Applications/DJI Mic Status.app"
```

说明：

- 圆环全绿 = 满电，弧长随电量缩短；读不到数据时整体变灰
- 中间 DJI 字样使用 `labelColor`，深浅色模式切换时自动重绘
- 点击图标展开菜单：电量档位、充电状态、输入电平、固件、立即刷新、退出
- 每 5 分钟自动刷新，读取耗时约 2–3 秒，期间图标保持上一次的状态
- 无 Dock 图标（`LSUIElement`）
- 卸载：`rm -rf ~/Applications/"DJI Mic Status.app"`

---

## 10. 为什么不能用蓝牙直连

这是项目最初的目标：发射器通过蓝牙直连 Mac，按键直接触发语音输入，不占用 USB-C。**实测结论是不可行**，三条独立证据如下。

### 9.1 系统只为它协商了 HFP，没有 HID

```bash
system_profiler SPBluetoothDataType | grep -A6 "DJI Mic Mini 2"
```

```
DJI Mic Mini 2-C8701B:
    Vendor ID: 0x0001
    Product ID: 0x0001
    Minor Type: Headset
    Services: 0x800001 < HFP ACL >
```

`Services` 只有 `HFP ACL`，没有任何 HID 服务。按键要变成 `volume_increment` 必须有 HID 通道，这里根本没有建立。

### 9.2 系统里不存在 DJI 的 HID 设备

```bash
ioreg -r -c IOHIDDevice -l -w0 | grep -c DJI   # 结果：0
```

### 9.3 按按键时两条通道都没有信号

`scripts/press-test.sh` 同时监听系统音量和蓝牙串口，短按一次连接键后：

| 观测项 | 结果 |
|---|---|
| 系统音量变化 | 0 次 |
| 串口峰值速率 | 0.0 KB/s |
| 串口帧数 / 新帧型 | 0 / 0 |

### 9.4 顺带发现的蓝牙串口

连接期间发射器会创建 `/dev/cu.DJIMicMini2-XXXXXX`。首次打开排空了 137,751 字节积压数据，帧结构为 125 / 129 字节定长、子帧头 `55 77 05`、字节熵 7.9（接近加密数据），排空后 30 秒内 0 帧。

这说明该通道是事件驱动且稳态静默的，理论上很适合做按键通道——但按键时它同样没有任何输出。

### 9.5 推测原因

DJI 固件很可能只在对端是自家相机（或接收器）时才发送按键命令；连到普通电脑时，按键在协议层被直接丢弃。

### 9.6 相关协议背景

- 发射器与相机之间走 BLE，使用 DJI 的 **DUML** 帧格式：`0x55` 魔数 + 长度/版本 + CRC8 + 源/目的 + 序号 + cmdSet/cmdId + 载荷 + CRC16。
- 相机侧特征 `FFF4`（读/写/通知）与 `FFF5`（无响应写），`usokawa/dji-mic-mo` 正是通过 `FFF4` 读取发射器状态的，但它只解析设备状态（cmdSet `0x5B` / cmdId `0x03`），**没有按键解析**。
- 由于发射器是中央设备（central）、相机是外设（peripheral），Mac 想冒充相机需要广播 DJI 相机的服务并完成 DUML 握手，而且会占掉发射器唯一的链路，无法同时做 HFP 音频。方向上不划算。

---

## 11. 诊断工具

仓库里的三个 Swift 工具用于排查，日常不需要。完整源码见 `src/`。

| 工具 | 用途 | 权限 |
|---|---|---|
| `bin/hidwatch --list` | 列出所有 HID 设备，判断设备有没有以 HID 身份出现 | 输入监控 |
| `bin/serialkeyd monitor` | 监听蓝牙串口，打印帧率与新帧型 | 无 |
| `bin/djimicd scan` / `dump` | BLE 扫描与 GATT 订阅（FFF4） | 蓝牙 |

两个容易踩的坑：

1. `hidwatch` 需要「输入监控」权限，否则 `IOHIDManagerOpen` 返回 `0xE00002E2`。
2. `djimicd` 是 CoreBluetooth 程序，裸二进制缺少 `Info.plist` 会被 TCC 直接终止（退出码 134），所以构建脚本把它打包成了 `DJIMicKey.app`。

---

## 12. 参考资料

- DJI Mic Mini 2 技术参数与常见问题（DMMT02，蓝牙 5.3，GFSK 2Mbps）
- 《DJI Mic 系列手机版接收器用户手册》：USB-C 接头为数据接口，USB-C 充电接口仅用于充电与模拟耳机监听
- DJI Mic 2 用户手册：连接键在移动设备上等同于音量键，仅支持「音量键可拍照」的设备
- DJI 支持中心：发射器与 Osmo Action / Pocket 蓝牙配对后，按键可启停录制
- `usokawa/dji-mic-mo`：通过 BLE `FFF4` 读写发射器状态与参数
- `hueyluox/dji-mic-command`、`caezium/dji-mic-wispr-flow`、`Johnixr/dji-mic-dictation`：USB 接收器 → HID → Karabiner / hidutil
- `yigitkonur/lib-osmo-ble`：`FFF4` / `FFF5` 角色与 DUML 字段定义
- Schiller et al., *Drone Security and the Mysterious Case of DJI's DroneID*：DUML 帧结构
- Apple 文档：`CBConnectPeripheralOptionEnableAutoReconnect`（macOS 14+）

---

## 许可

仅供个人使用与研究。
