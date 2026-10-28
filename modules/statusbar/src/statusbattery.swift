// statusbattery.swift — 状态栏电量图标
//
// 外观：20×20 绿色圆环示意 7 档电量，非精确百分比；DJI 为字体文本，非官方 logo
// 交互：点击展开菜单（电量、固件、序列号、输入电平、立即刷新、退出）
// 数据：调用同目录 Resources/mic-battery.sh --json
//
// 编译见 scripts/build-status.sh

import AppKit

// MARK: - 数据

struct Battery {
    var level: Int          // 1 = 满电, 7 = 极低
    var charging: Bool
    var name: String
    var serial: String
    var firmware: String
    var inputLevel: Int?
}

func levelLabel(_ level: Int) -> String {
    switch level {
    case 1: return "满电"
    case 2: return "良好"
    case 3: return "中等"
    case 4: return "一半"
    case 5: return "偏低"
    case 6: return "低"
    default: return "极低"
    }
}

// MARK: - 应用

final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var battery: Battery?
    var lastError: String?
    var timer: Timer?
    var refreshing = false

    let refreshInterval: TimeInterval = 300

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.imagePosition = .imageOnly
        item.button?.image = makeIcon()

        rebuildMenu()
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }

        // 深浅色切换时重绘，保证 DJI 字样始终可读
        DistributedNotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
    }

    @objc func themeChanged() {
        DispatchQueue.main.async {
            self.item.button?.image = self.makeIcon()
        }
    }

    // MARK: 图标

    /// 绿色圆环 + 中心 DJI 字样。弧长表示电量：满电为整圈，极低为一小段。
    func makeIcon() -> NSImage {
        let side: CGFloat = 20
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius: CGFloat = 7.6
            let width: CGFloat = 2.0

            // 底环
            let base = NSBezierPath()
            base.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            base.lineWidth = width
            NSColor.tertiaryLabelColor.withAlphaComponent(0.30).setStroke()
            base.stroke()

            // 电量弧：level 1 → 整圈；level 7 → 1/7 圈
            let level = self.battery?.level ?? 7
            let fraction = max(0.08, CGFloat(8 - level) / 7.0)
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center,
                          radius: radius,
                          startAngle: 90,
                          endAngle: 90 - fraction * 360,
                          clockwise: true)
            arc.lineWidth = width
            arc.lineCapStyle = .round
            (self.battery == nil ? NSColor.tertiaryLabelColor : NSColor.systemGreen).setStroke()
            arc.stroke()

            // 中心 DJI
            let text = "DJI" as NSString
            let font = NSFont.systemFont(ofSize: 5.4, weight: .heavy)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ]
            let size = text.size(withAttributes: attrs)
            let textRect = NSRect(x: center.x - size.width / 2,
                                  y: center.y - size.height / 2,
                                  width: size.width,
                                  height: size.height)
            text.draw(in: textRect, withAttributes: attrs)

            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: 菜单

    func rebuildMenu() {
        let menu = NSMenu()

        if let b = battery {
            let title = NSMenuItem(title: "\(b.name)  ·  \(levelLabel(b.level))（\(b.level)/7）",
                                   action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)

            if b.charging {
                let c = NSMenuItem(title: "正在充电", action: nil, keyEquivalent: "")
                c.isEnabled = false
                menu.addItem(c)
            }
            if let input = b.inputLevel {
                let i = NSMenuItem(title: "输入电平 \(input)", action: nil, keyEquivalent: "")
                i.isEnabled = false
                menu.addItem(i)
            }
            if !b.firmware.isEmpty {
                let f = NSMenuItem(title: "固件 \(b.firmware)", action: nil, keyEquivalent: "")
                f.isEnabled = false
                menu.addItem(f)
            }
        } else {
            let t = NSMenuItem(title: lastError ?? "未检测到接收器", action: nil, keyEquivalent: "")
            t.isEnabled = false
            menu.addItem(t)
        }

        menu.addItem(NSMenuItem.separator())
        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(menuRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let auto = NSMenuItem(title: "每 5 分钟自动刷新", action: nil, keyEquivalent: "")
        auto.isEnabled = false
        menu.addItem(auto)

        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
    }

    @objc func menuRefresh() { refresh() }
    @objc func menuQuit() { NSApp.terminate(nil) }

    // MARK: 数据

    func refresh() {
        guard !refreshing else { return }
        guard let script = Bundle.main.path(forResource: "mic-battery", ofType: "sh") else {
            lastError = "缺少读取脚本"
            rebuildMenu()
            item.button?.image = makeIcon()
            return
        }

        refreshing = true
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script, "--json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            var parsed: Battery?
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   process.terminationStatus == 0,
                   let level = obj["level"] as? Int, (1...7).contains(level) {
                    parsed = Battery(level: level,
                                     charging: obj["charging"] as? Bool ?? false,
                                     name: obj["name"] as? String ?? "DJI Mic",
                                     serial: obj["serial"] as? String ?? "",
                                     firmware: obj["firmware"] as? String ?? "",
                                     inputLevel: obj["inputLevel"] as? Int)
                }
            } catch {
                parsed = nil
            }

            DispatchQueue.main.async {
                self.refreshing = false
                self.battery = parsed
                self.lastError = parsed == nil ? "读取失败，检查接收器是否插好" : nil
                self.item.button?.image = self.makeIcon()
                self.rebuildMenu()
            }
        }
    }
}

// MARK: - 启动

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
