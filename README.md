# DJI Mic Mini 2 连接键 → macOS 右 Command

把大疆麦克风发射器侧面的连接键，变成 Mac 上的「语音输入键」。

按一下，豆包 / Wispr Flow / 任何设了快捷键的输入法就开始收音；再按一下结束。顺带在状态栏显示发射器电量。

```
发射器连接键 → 手机版接收器 → USB HID 音量键 → hidutil 设备级映射 → 右 Command
```

已在 **macOS 27.2 / Apple Silicon / DJI Mic Mini 2 发射器 + 手机版接收器** 上实测通过。其他硬件与固件需自行验证。

> 这是独立的非官方项目，与 DJI 无隶属或背书关系。状态栏里的「DJI」是系统字体绘制的文字，不是官方 logo。

<p align="center"><img src="docs/statusbar-icon.png" width="128" alt="状态栏电量图标"></p>

---

## 目录

- [它解决什么问题](#它解决什么问题)
- [为什么不用蓝牙直连](#为什么不用蓝牙直连)
- [安装](#安装)
- [换成其他按键](#换成其他按键)
- [状态栏电量（可选）](#状态栏电量可选)
- [项目结构](#项目结构)
- [排错](#排错)
- [许可](#许可)

---

## 它解决什么问题

Vibe Coding 的时候，大量时间花在「把需求讲清楚」上：描述要改什么、补充业务口径、反馈界面上哪里不对。打字慢，说话快。

问题是：抬头说话会打断思路，抬手按键盘也会。胸前那颗麦克风本来就在嘴边，如果它能当输入键，整个过程就只剩「按一下，说」。

所以这个项目的目标很窄：**让那颗连接键，等价于键盘上的一个键。**

本项目只做两件事：

1. 把接收器上报的音量键事件，在 HID 层换成右 Command；
2. 用一条事件驱动的小守护进程，保证拔插接收器后映射自动回来。

不改麦克风配置、不改固件、不占用音频通道。

---

## 为什么不用蓝牙直连

最初的方向是「发射器蓝牙直连 Mac，省掉接收器」。实测走不通，原因写在下面，给后来的人省时间。

当时测试的连接状态下：

| 检查项 | 结果 |
|---|---|
| 系统协商的蓝牙服务 | 只有 `HFP + ACL`，无 HID |
| `ioreg -c IOHIDDevice \| grep DJI` | 0 个 |
| 短按连接键时的系统音量变化 | 0 次 |
| 同时段蓝牙串口（`/dev/cu.DJIMicMini2-*`）数据 | 稳态 0 帧 |

结论：在这台机器、这个固件、这种连接模式下，按键事件没有到达系统能读到的地方。

需要强调的是**这些结果的边界**：

- 它只约束当前设备、固件、连接模式和观测窗口，**不能证明所有 BLE 方案不可行**；
- 经典蓝牙 HFP 的服务列表不能代替 BLE GATT 枚举；
- 串口无数据，不能排除其他特征通知、专有握手或角色切换；
- 音量不变也可能受音量上限、输出设备或既有映射影响。

`src/djimicd.swift` 是当时写的 BLE 扫描 / GATT 订阅实验工具，**没有**实现可用的 DJI 按键协议或相机握手，请不要把它当作可用的蓝牙方案。

顺带一提，换到 USB 接收器之后音质也变好了：蓝牙是 16 kHz 单声道（HFP），接收器是 48 kHz。

---

## 安装

需要两条命令。前提：macOS、Xcode Command Line Tools（`clang`）、已插上接收器并完成配对。

```bash
git clone https://github.com/Votoy/dji-mic-key-macos.git
cd dji-mic-key-macos

# 编译 usbmapd 并注册开机自启（会立即执行一次）
./scripts/install-agent.sh

# 确认映射已写入
./scripts/apply-map.sh --status
```

然后把输入法的语音输入快捷键设成**右 Command**，短按发射器连接键验证。

预期：豆包开始收音，系统音量**不**变化。

### 用的是哪一套机制

| 环节 | 实现 | 需要授权吗 |
|---|---|---|
| 按键事件来源 | 接收器枚举为 HID，上报 Consumer `0xE9`（音量+） | 否 |
| 按键替换 | `hidutil` 写入设备级 `UserKeyMapping` | 否 |
| 拔插恢复 | `usbmapd`，IOKit 设备出现通知 | 否 |

不装驱动扩展、不要辅助功能、不要输入监控。这是刻意选 `hidutil` 而不是 Karabiner 的原因：少一层权限，少一处会失效的地方。

### 安装位置

| 内容 | 路径 |
|---|---|
| 守护进程与脚本 | `~/Library/Application Support/DJIMicKey/` |
| 开机自启 | `~/Library/LaunchAgents/com.lmf.djimic-hidutil.plist` |

`com.lmf.*` 这个标识是兼容已安装版本保留的，不代表个人路径。

```bash
./scripts/apply-map.sh --status   # 查询
./scripts/apply-map.sh            # 手动补写一次
./scripts/apply-map.sh --reset    # 清除（守护在跑的话可能被写回）
./scripts/uninstall-agent.sh      # 彻底停用
```

### 几个必须说清楚的点

- **映射是易失的**：插拔、重新枚举、重启后都需要重写，`usbmapd` 负责这件事。
- **会覆盖该设备已有的 `UserKeyMapping`**：如果你之前给这个接收器配过别的映射，先备份。
- **`usbmapd` 不是零唤醒**：主路径是 IOKit 设备通知，另有一个 300 秒兜底定时器（应对睡眠唤醒后设备未重新枚举），RunLoop 最长每秒返回一次检查退出信号。CPU / 内存随环境变化，不承诺固定数值。
- **多个同型号接收器会被一起匹配**（按 VID/PID 匹配，不是按序列号）。

---

## 换成其他按键

目标键硬编码在三个文件里：`src/usbmapd.c`、`scripts/apply-map.sh`、`scripts/watch-map.sh`。改完重新 `./scripts/install-agent.sh`。

HID 编码规则：`usage page << 32 | usage`。

| 目标键 | Page / Usage | 完整编码 |
|---|---|---|
| 右 Command | `0x07 / 0xE7` | `0x7000000E7` |
| 右 Option | `0x07 / 0xE6` | `0x7000000E6` |
| 右 Control | `0x07 / 0xE4` | `0x7000000E4` |
| F13 | `0x07 / 0x68` | `0x700000068` |
| F14 | `0x07 / 0x69` | `0x700000069` |
| F15 | `0x07 / 0x6A` | `0x70000006A` |
| 音量 + （源） | `0x0C / 0xE9` | `0xC000000E9` |
| 音量 − （源） | `0x0C / 0xEA` | `0xC000000EA` |

> Swift 诊断工具用的是 macOS 虚拟键码，和 HID usage 不是同一套编号，改的时候别混。

另外 `karabiner/dji-mic-rx-to-right-command.json` 是 Karabiner-Elements 的可选规则。用它的话记得在 profile 的 `devices` 里加 `"is_consumer": true`，否则 Karabiner 默认不接管 Consumer 设备——这是最常见的坑。

---

## 状态栏电量（可选）

```bash
./scripts/mic-battery.sh          # 文本
./scripts/mic-battery.sh --json   # 给程序读

./modules/statusbar/scripts/build-status.sh
open "$HOME/Applications/DJI Mic Status.app"
```

输出示例（设备信息已替换为占位符）：

```text
  DJI Mic Mini 2  电量 1/7（满电）  未充电
    序列号 SERIAL_NUMBER  ·  固件 XX.XX.XX.XX
    当前输入电平 40
```

关于这份数据，三点必须说明：

- **7 档，不是百分比。** 1 最高、7 最低；标签是便于阅读的近似描述，档位 4 不保证正好 50%。
- **状态栏圆环是示意图。** 弧长按 `(8 - level) / 7` 换算，不能当精确读数用。
- **不是绝对只读。** 数据来自接收器的厂商自定义 USB 接口，运行时下载的上游脚本支持写入设备参数和同步时间；本包装脚本以 `/dev/null` 作 stdin，不主动发送参数，但上游仍可能执行 `set_configuration`、声明接口、尝试分离内核驱动。不能保证完全不影响音频。

首次运行会建 Python venv、装 PyUSB、下载固定提交的上游脚本并校验 SHA-256。需要 Python 3 和可用的 libusb 后端。

完整说明见 [状态栏模块文档](modules/statusbar/README.md)，依赖许可与设备访问行为见 [第三方声明](THIRD_PARTY_NOTICES.md)。

---

## 项目结构

```
src/usbmapd.c          IOKit 设备通知守护 + hidutil 映射（核心，约 300 行）
scripts/apply-map.sh   一次性映射 / 状态查询 / 清除
scripts/install-agent.sh   编译、安装、注册 LaunchAgent
scripts/uninstall-agent.sh 停用自启
scripts/mic-battery.sh     读电量（7 档）
modules/statusbar/     状态栏图标（AppKit，独立模块，有自己的 README）
karabiner/             Karabiner 规则（可选路线）
docs/                  文档用图
```

诊断工具（`./scripts/build.sh` 编译到 `bin/`）：

| 工具 | 用途 | 权限 |
|---|---|---|
| `hidwatch --list` / `--filter DJI` | 枚举 HID、观察输入 | 可能需要输入监控 |
| `serialkeyd monitor` | 观察蓝牙串口 | 否 |
| `djimicd scan` / `dump` | BLE 扫描 / 通知订阅 | 蓝牙 |
| `press-test.sh` | 同时采样音量 + 观察串口 | 否 |

诊断输出可能包含其他设备标识和按键事件，公开日志前先检查。

---

## 排错

按这个顺序查：

```bash
./scripts/apply-map.sh --status                          # 1. 映射在不在
launchctl print "gui/$(id -u)/com.lmf.djimic-hidutil"    # 2. 守护活没活
cat /tmp/djimic-hidutil.err                              # 3. 有没有报错
```

| 现象 | 大概率原因 |
|---|---|
| 按了还是调音量 | 映射没写进去，或被别的工具覆盖 |
| 完全没反应 | 发射器没配对 / 接收器插在了充电口而不是数据口 |
| 拔插后失效 | 守护没跑起来；`apply-map.sh` 手动补一次能立刻恢复 |
| LaunchAgent 加载失败 | 检查 plist 路径与 `plutil -lint` 输出 |

---

## 许可

本项目原创代码使用 [MIT License](LICENSE)，不覆盖第三方依赖、第三方代码及商标。

运行时下载的 `usokawa/dji-mic-mo` 使用 BSD-2-Clause，详情与核实版本见 [第三方声明](THIRD_PARTY_NOTICES.md)。

产品名称、商标归各自所有者。本项目不分发任何 DJI 固件或厂商代码。
