# 状态栏电量模块

在 macOS 状态栏显示绿色圆环与系统字体绘制的 DJI 字样。该字样并非官方 logo，本模块不是 DJI 官方应用。

电量来自接收器协议的 7 档状态：1 档最高、7 档最低。圆环按 `(8 - level) / 7` 映射成弧长，只表达相对档位，**不是精确电量百分比**。菜单中的“满电”“一半”等也是近似标签。

## 构建与更新

需要 Xcode Command Line Tools（`swiftc`）。在仓库根目录执行：

```bash
# 只构建，产物位于 bin/DJIMicStatus.app，不修改已安装应用
./modules/statusbar/scripts/build-status.sh --build-only

# 构建并安装；已有同名应用会移至带时间戳和进程号的备份路径
./modules/statusbar/scripts/build-status.sh
open "$HOME/Applications/DJI Mic Status.app"
```

更新前先从菜单退出旧状态栏应用。脚本保留旧应用备份；若复制失败，可在 Finder 检查目标并恢复备份。旧的桌面悬浮版不会被清理或终止，需自行管理。

应用由 [statusbattery.swift](src/statusbattery.swift) 编译，使用 `NSStatusItem` 绘图、`LSUIElement` 隐藏 Dock 图标，并做本地 ad-hoc 签名。打包脚本将仓库根目录的 [mic-battery.sh](../../scripts/mic-battery.sh) 复制进 Resources；Python、PyUSB、libusb 及运行时下载的读取器仍是外部依赖，并非完全自包含。

## 使用与设备访问

- 每 5 分钟刷新，可在菜单中立即刷新；同一应用进程内避免重叠采集。
- 采集期间保留上次结果；失败后变灰。每次采集最多等待约 12 秒，另有退出开销；首次环境安装和下载可能更久。
- 菜单显示设备名、电量档位、充电状态、输入电平及固件。读取器仅选取第一个含电量的发射器。
- 中心字样采用 `labelColor`，随系统外观重绘。
- 上游读取器支持设备参数写入及时间同步；本包装脚本断开 stdin 配置输入，但底层仍可能设置 USB 配置、声明接口或尝试分离驱动。不能保证绝对只读或无音频影响。

依赖准备、缓存路径、隐私与许可证见 [主 README](../../README.md) 和 [第三方声明](../../THIRD_PARTY_NOTICES.md)。

## 自启与卸载

```bash
./modules/statusbar/scripts/install-autostart.sh
./modules/statusbar/scripts/install-autostart.sh --remove
```

自启写入 `~/Library/LaunchAgents/com.lmf.djimicstatus.plist`，使用 `RunAtLoad` 且不设置持续保活，手动退出后不会被反复拉起。标识为兼容既有安装保留。

卸载时先移除自启，再从状态栏菜单退出。在 Finder 的 `~/Applications` 中核对 `DJI Mic Status.app`，按需移到废纸篓；备份和旧悬浮应用也由用户核对后管理。支持目录可能由按键模块和电量模块共用，不自动清空。

## 调参与排错

外观参数在 [makeIcon()](src/statusbattery.swift)：`side = 20`、`radius = 7.6`、`width = 2.0`、中心字号 `5.4`。刷新间隔为 `refreshInterval = 300` 秒，修改后重新构建安装。

| 现象 | 检查 |
|---|---|
| 图标灰色 / 读取失败 | 接收器连接、发射器配对、Python 及 libusb 后端；在终端运行 `./scripts/mic-battery.sh` 查看错误 |
| 图标不出现 | `open "$HOME/Applications/DJI Mic Status.app"`，确认运行的是更新后的应用 |
| 电量长期不变 | 先立即刷新；7 档数据可能长时间保持同一档 |
| 读取器校验失败 | 查看第三方声明中的固定版本；保留并检查已有缓存，不自动覆盖个人修改 |
| DJI 字样太小 | 调整 `side` 和字号，再构建 |

读取日志可能包含设备序列号和设备名，分享前请脱敏。
