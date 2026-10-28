// batterywidget.swift — 桌面悬浮电量小组件
//
// 外观：圆角半透明面板，7 段环形电量指示 + 状态文字
// 交互：拖动移动，右键菜单（立即刷新 / 退出），每 5 分钟自动刷新
// 数据：调用同目录 Resources/mic-battery.sh --json
//
// 编译见 scripts/build-widget.sh

import AppKit

// MARK: - 数据

struct Battery {
    var level: Int        // 1 = 满电, 7 = 极低
    var charging: Bool
    var name: String
}

func label(for level: Int) -> String {
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

func accentColor(for level: Int) -> NSColor {
    switch level {
    case 1, 2, 3: return .systemGreen
    case 4, 5:    return .systemYellow
    default:      return .systemRed
    }
}

// MARK: - 绘制

final class GaugeView: NSView {
    var battery: Battery?
    var message: String = "读取中…"
    var onMenu: ((NSPoint) -> Void)?

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY + 14)
        let radius: CGFloat = min(bounds.width, bounds.height) * 0.32
        let lineWidth: CGFloat = 9
        let segments = 7
        let gap: CGFloat = 4.0

        // 7 段环形：level 1 = 满（7 段全亮），level 7 = 空（0 段）
        let lit = battery.map { max(0, segments - $0.level + 1) } ?? 0

        for i in 0..<segments {
            let startDeg = 90.0 - Double(i) * (360.0 / Double(segments))
            let endDeg = startDeg - (360.0 / Double(segments)) + Double(gap)
            let path = NSBezierPath()
            path.appendArc(withCenter: center,
                           radius: radius,
                           startAngle: CGFloat(endDeg),
                           endAngle: CGFloat(startDeg),
                           clockwise: false)
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            let on = i < lit
            (on ? (battery.map { accentColor(for: $0.level) } ?? .systemGray) : NSColor.tertiaryLabelColor)
                .withAlphaComponent(on ? 1.0 : 0.25)
                .setStroke()
            path.stroke()
        }

        // 主文字
        let main: String
        if let b = battery {
            main = b.charging ? "\(label(for: b.level)) · 充电" : label(for: b.level)
        } else {
            main = "—"
        }
        draw(text: main,
             font: .systemFont(ofSize: 17, weight: .semibold),
             color: .labelColor,
             centerY: center.y - 2)

        // 副文字
        let sub: String
        if let b = battery {
            sub = "\(b.name)  L\(b.level)/7"
        } else {
            sub = message
        }
        draw(text: sub,
             font: .systemFont(ofSize: 10, weight: .regular),
             color: .secondaryLabelColor,
             centerY: center.y - 24)
    }

    private func draw(text: String, font: NSFont, color: NSColor, centerY: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let rect = NSRect(x: bounds.midX - size.width / 2,
                          y: centerY - size.height / 2,
                          width: size.width,
                          height: size.height)
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?(convert(event.locationInWindow, from: nil))
    }
}

// MARK: - 应用

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var gauge: GaugeView!
    var timer: Timer?

    let refreshInterval: TimeInterval = 300

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildPanel()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func buildPanel() {
        let size = NSSize(width: 176, height: 176)

        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered,
                        defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 18
        effect.layer?.masksToBounds = true

        gauge = GaugeView(frame: NSRect(origin: .zero, size: size))
        gauge.autoresizingMask = [.width, .height]
        gauge.onMenu = { [weak self] point in self?.showMenu(at: point) }
        effect.addSubview(gauge)
        panel.contentView = effect

        if let saved = UserDefaults.standard.string(forKey: "panelOrigin") {
            let parts = saved.split(separator: ",").compactMap { Double($0) }
            if parts.count == 2 {
                panel.setFrameOrigin(NSPoint(x: parts[0], y: parts[1]))
            } else {
                positionTopRight()
            }
        } else {
            positionTopRight()
        }

        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidMove),
            name: NSWindow.didMoveNotification, object: panel)
    }

    func positionTopRight() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.maxX - size.width - 36,
                                     y: visible.maxY - size.height - 36))
    }

    @objc func windowDidMove() {
        let origin = panel.frame.origin
        UserDefaults.standard.set("\(origin.x),\(origin.y)", forKey: "panelOrigin")
    }

    func showMenu(at point: NSPoint) {
        let menu = NSMenu()
        menu.addItem(withTitle: "立即刷新", action: #selector(menuRefresh), keyEquivalent: "")
            .target = self
        menu.addItem(NSMenuItem.separator())
        let info = NSMenuItem(title: "每 5 分钟自动刷新", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出", action: #selector(menuQuit), keyEquivalent: "")
            .target = self
        menu.popUp(positioning: nil, at: point, in: gauge)
    }

    @objc func menuRefresh() { refresh() }
    @objc func menuQuit() { NSApp.terminate(nil) }

    // MARK: 数据

    func refresh() {
        guard let script = Bundle.main.path(forResource: "mic-battery", ofType: "sh") else {
            gauge.battery = nil
            gauge.message = "缺少脚本"
            gauge.needsDisplay = true
            return
        }

        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script, "--json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            var battery: Battery?
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let level = obj["level"] as? Int {
                    battery = Battery(level: level,
                                      charging: obj["charging"] as? Bool ?? false,
                                      name: obj["name"] as? String ?? "DJI Mic")
                }
            } catch {
                battery = nil
            }

            DispatchQueue.main.async {
                self.gauge.battery = battery
                self.gauge.message = battery == nil ? "未连接" : ""
                self.gauge.needsDisplay = true
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
