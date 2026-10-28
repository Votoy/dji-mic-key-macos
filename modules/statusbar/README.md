# 状态栏电量模块

在 macOS 状态栏常驻一个 20×20 的图标：**绿色圆环 + DJI 字样**，圆环的弧长表示发射器电量，点击展开详情菜单。

```
   ╭─────╮
  ╱  DJI  ╲      ← 圆环 = 电量弧，中间是 DJI
  ╲       ╱
   ╰─────╯
```

## 特性

| 项 | 说明 |
|---|---|
| 图标 | 20×20，圆环线宽 2.0，中心 DJI 5.4pt Heavy |
| 电量映射 | 1 档（满电）= 整圈，7 档（极低）= 1/7 圈 |
| 数据来源 | 调用 `scripts/mic-battery.sh --json` |
| 刷新 | 每 5 分钟一次，读取耗时 2–3 秒，期间保持上次状态 |
| 深浅色 | DJI 字样用 `labelColor`，跟随系统外观自动重绘 |
| Dock | 无（`LSUIElement`） |
| 资源占用 | 常驻约 8 MB，空闲 0% CPU |

菜单内容：

```
DJI Mic Mini 2 · 满电（1/7）
输入电平 42
固件 02.03.17.00
──────────────
立即刷新        ⌘R
每 5 分钟自动刷新
──────────────
退出            ⌘Q
```

## 构建与安装

```bash
# 在仓库根目录执行
./modules/statusbar/scripts/build-status.sh

open "$HOME/Applications/DJI Mic Status.app"
```

构建脚本会：

1. 用 `swiftc` 编译 `src/statusbattery.swift`（只需命令行工具，不需要 Xcode）
2. 生成 `.app` 包，写入 `LSUIElement` 等 Info.plist 字段
3. 把 `scripts/mic-battery.sh` 复制进 `Contents/Resources`（应用自包含）
4. ad-hoc 签名，安装到 `~/Applications`
5. 顺手清理旧的桌面悬浮版（如果有）

## 开机自启

```bash
./modules/statusbar/scripts/install-autostart.sh          # 安装
./modules/statusbar/scripts/install-autostart.sh --remove # 移除
```

安装后写入 `~/Library/LaunchAgents/com.lmf.djimicstatus.plist`，登录时自动拉起。注意这里用 `RunAtLoad` 而非 `KeepAlive`——你手动退出后不应该被系统重新拉起。

## 卸载

```bash
./modules/statusbar/scripts/install-autostart.sh --remove
rm -rf ~/Applications/"DJI Mic Status.app"
```

## 调参

要改外观，直接改 `src/statusbattery.swift` 里 `makeIcon()` 的几个常量：

| 常量 | 当前值 | 作用 |
|---|---|---|
| `side` | 20 | 图标边长，可加到 22 让字更清楚 |
| `radius` | 7.6 | 圆环半径 |
| `width` | 2.0 | 圆环线宽，降到 1.5 可给字更多空间 |
| 字号 | 5.4 | DJI 字样大小 |
| `fraction` | `(8 - level) / 7` | 电量到弧长的映射，改这里可调整低电时的最小弧 |

改完重新执行 `build-status.sh` 即可。

## 实现要点

**为什么不用 WidgetKit**：系统小组件需要 Xcode 工程、App Extension 与签名，且时间线刷新有 5 分钟起步的硬限制。状态栏图标用 `NSStatusItem` + `NSImage(size:flipped:drawingHandler:)` 绘制，零依赖、可实时刷新。

**为什么图标不是 template image**：`isTemplate = true` 会让系统把图标染成单色，绿色就没了。这里用 `isTemplate = false`，并让 DJI 字样取 `labelColor`，在深浅色菜单栏下都能读。

**为什么取数要起子进程**：电量来自接收器的 USB 厂商自定义接口（DUML 协议），Swift 侧直接实现需要处理 libusb 与协议细节；复用已验证的 Python 读取器更稳，代价是每次 2–3 秒——对 5 分钟一次的刷新可以接受。

**刷新期间不闪空白**：新数据回来之前保留旧值，只有解析失败时才把图标变灰。

## 排错

| 现象 | 原因 | 处理 |
|---|---|---|
| 图标变灰 | 接收器没插，或读取失败 | 检查接收器；菜单里点「立即刷新」 |
| 菜单显示「未检测到接收器」 | 同上 | 同上 |
| 图标不出现 | 应用未启动 | `open "$HOME/Applications/DJI Mic Status.app"` |
| DJI 字样模糊 | 5.4pt 在 20×20 下偏小 | 把 `side` 调到 22、字号调到 6.0 |
| 电量长期不变 | 刷新定时器被系统挂起 | 菜单点「立即刷新」确认；必要时重启应用 |
