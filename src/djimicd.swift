// djimicd.swift
// DJI Mic Mini 2 发射器：BLE 按键探测 + 键盘事件注入
//
// 三个子命令：
//   scan   扫描附近 BLE 设备，确认发射器是否在广播
//   dump   连接并订阅所有 notify/indicate 特征，十六进制打印收到的每一帧
//          （用于确认"按连接键时 FFF4 上有没有数据变化"）
//   run    常驻：连接后按规则匹配通知帧，命中即注入键盘事件；断线自动重连
//
// 编译：swiftc -O -o ../bin/djimicd djimicd.swift \
//         -framework CoreBluetooth -framework CoreGraphics -framework ApplicationServices
//
// 示例：
//   ./bin/djimicd scan --seconds 8
//   ./bin/djimicd dump --name "DJI Mic"
//   ./bin/djimicd run --match "5A 5B 01" --key right_command
//   ./bin/djimicd run --any --key f13 --debounce 400      # 调试：任何通知都触发
//
// 权限：
//   · 蓝牙：首次运行系统会弹窗，需允许终端使用蓝牙
//   · 辅助功能：注入键盘事件必需（系统设置 → 隐私与安全性 → 辅助功能）

import Foundation
import CoreBluetooth
import CoreGraphics
import ApplicationServices

setvbuf(stdout, nil, _IONBF, 0)

// MARK: - 配置

struct Config {
    var command = "scan"
    var namePrefix = "DJI Mic"
    var targetUUID: UUID?
    var seconds: Double = 8
    var matchHex: [UInt8]?
    var matchOffset = 0
    var keyName = "right_command"
    var mods: CGEventFlags = []
    var debounceMS = 400
    var anyNotify = false
    var logPath: String?
}

var cfg = Config()

// MARK: - 按键表

struct KeySpec {
    let code: CGKeyCode
    let modifierFlag: CGEventFlags?   // 非 nil 表示这是修饰键，需要用 flagsChanged
}

let keyTable: [String: KeySpec] = [
    "right_command": KeySpec(code: 54, modifierFlag: .maskCommand),
    "left_command":  KeySpec(code: 55, modifierFlag: .maskCommand),
    "right_option":  KeySpec(code: 61, modifierFlag: .maskAlternate),
    "left_option":   KeySpec(code: 58, modifierFlag: .maskAlternate),
    "right_control": KeySpec(code: 62, modifierFlag: .maskControl),
    "left_control":  KeySpec(code: 59, modifierFlag: .maskControl),
    "right_shift":   KeySpec(code: 60, modifierFlag: .maskShift),
    "left_shift":    KeySpec(code: 56, modifierFlag: .maskShift),
    "f13": KeySpec(code: 105, modifierFlag: nil),
    "f14": KeySpec(code: 107, modifierFlag: nil),
    "f15": KeySpec(code: 113, modifierFlag: nil),
    "f16": KeySpec(code: 106, modifierFlag: nil),
    "f17": KeySpec(code: 64,  modifierFlag: nil),
    "f18": KeySpec(code: 79,  modifierFlag: nil),
    "f19": KeySpec(code: 80,  modifierFlag: nil),
    "escape": KeySpec(code: 53, modifierFlag: nil),
    "space":  KeySpec(code: 49, modifierFlag: nil),
    "return": KeySpec(code: 36, modifierFlag: nil),
    "tab":    KeySpec(code: 48, modifierFlag: nil)
]

func ts() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    return f.string(from: Date())
}

var logHandle: FileHandle?

func log(_ s: String) {
    let line = "[\(ts())] \(s)\n"
    print(line, terminator: "")
    if let h = logHandle, let d = line.data(using: .utf8) {
        h.write(d)
    }
}

func hexString(_ data: Data) -> String {
    data.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func parseHex(_ s: String) -> [UInt8]? {
    let cleaned = s.replacingOccurrences(of: "0x", with: "")
        .replacingOccurrences(of: ",", with: " ")
        .replacingOccurrences(of: "-", with: " ")
    let parts = cleaned.split(separator: " ")
    var out: [UInt8] = []
    if parts.count == 1, let single = parts.first {
        // 允许 "5A5B01" 这种连写
        let str = String(single)
        if str.count % 2 == 0, str.count >= 2 {
            var i = str.startIndex
            while i < str.endIndex {
                let j = str.index(i, offsetBy: 2)
                guard let b = UInt8(str[i..<j], radix: 16) else { return nil }
                out.append(b)
                i = j
            }
            return out
        }
        if let b = UInt8(str, radix: 16) { return [b] }
        return nil
    }
    for p in parts {
        guard let b = UInt8(p, radix: 16) else { return nil }
        out.append(b)
    }
    return out
}

// MARK: - 键盘注入

func postKey(_ spec: KeySpec, mods: CGEventFlags) {
    let src = CGEventSource(stateID: .hidSystemState)

    if let flag = spec.modifierFlag {
        if let down = CGEvent(keyboardEventSource: src, virtualKey: spec.code, keyDown: true) {
            down.type = .flagsChanged
            down.flags = flag
            down.post(tap: .cghidEventTap)
        }
        usleep(25_000)
        if let up = CGEvent(keyboardEventSource: src, virtualKey: spec.code, keyDown: false) {
            up.type = .flagsChanged
            up.flags = []
            up.post(tap: .cghidEventTap)
        }
    } else {
        if let down = CGEvent(keyboardEventSource: src, virtualKey: spec.code, keyDown: true) {
            down.flags = mods
            down.post(tap: .cghidEventTap)
        }
        usleep(15_000)
        if let up = CGEvent(keyboardEventSource: src, virtualKey: spec.code, keyDown: false) {
            up.flags = mods
            up.post(tap: .cghidEventTap)
        }
    }
}

func checkAccessibility(prompt: Bool) {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let opts = [key: prompt] as CFDictionary
    let trusted = AXIsProcessTrustedWithOptions(opts)
    if !trusted {
        log("⚠️ 辅助功能未授权：注入键盘事件会静默失败。请到 系统设置 → 隐私与安全性 → 辅助功能 勾选终端 App。")
    } else {
        log("辅助功能：已授权")
    }
}

// MARK: - BLE Agent

final class Agent: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var keySpec: KeySpec!
    var lastFire = Date.distantPast
    var reconnectScheduled = false
    var discoveredCount = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log("蓝牙已就绪，开始扫描（按名称前缀 \"\(cfg.namePrefix)\" 过滤）")
            central.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            if cfg.command == "scan" {
                DispatchQueue.main.asyncAfter(deadline: .now() + cfg.seconds) {
                    central.stopScan()
                    log("扫描结束")
                    exit(0)
                }
            }
        case .unauthorized:
            log("❌ 蓝牙权限被拒绝：系统设置 → 隐私与安全性 → 蓝牙，勾选终端 App")
            exit(2)
        case .poweredOff:
            log("❌ 蓝牙已关闭")
        default:
            log("蓝牙状态：\(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        let name = advName.isEmpty ? (peripheral.name ?? "") : advName
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []

        if cfg.command == "scan" {
            discoveredCount += 1
            log("发现: \(name.isEmpty ? "<无名>" : name)  RSSI=\(RSSI)  id=\(peripheral.identifier.uuidString)  "
                + "services=\(services.map { $0.uuidString }.joined(separator: ","))")
            return
        }

        let matched: Bool
        if let want = cfg.targetUUID {
            matched = peripheral.identifier == want
        } else {
            matched = name.localizedCaseInsensitiveContains(cfg.namePrefix)
        }
        guard matched, peripheral.state == .disconnected else { return }

        log("命中目标: \(name)  id=\(peripheral.identifier.uuidString)")
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self

        var opts: [String: Any] = [:]
        if #available(macOS 14.0, *) {
            opts[CBConnectPeripheralOptionEnableAutoReconnect] = true
        }
        central.connect(peripheral, options: opts)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("已连接，开始枚举 GATT")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("连接失败: \(error?.localizedDescription ?? "未知")")
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        timestamp: CFAbsoluteTime,
                        isReconnecting: Bool,
                        error: Error?) {
        log("连接断开（系统自动重连中=\(isReconnecting)）: \(error?.localizedDescription ?? "-")")
        if !isReconnecting { scheduleReconnect() }
    }

    func scheduleReconnect() {
        guard cfg.command == "run", !reconnectScheduled else { return }
        reconnectScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.reconnectScheduled = false
            self.logAndRescan()
        }
    }

    func logAndRescan() {
        guard let central else { return }
        log("重新扫描…")
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, let p = self.peripheral, p.state != .connected else { return }
            self.logAndRescan()
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { log("枚举服务失败: \(error.localizedDescription)"); return }
        for s in peripheral.services ?? [] {
            log("service \(s.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: s)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { log("枚举特征失败: \(error.localizedDescription)"); return }
        for c in service.characteristics ?? [] {
            var props: [String] = []
            if c.properties.contains(.read) { props.append("read") }
            if c.properties.contains(.write) { props.append("write") }
            if c.properties.contains(.writeWithoutResponse) { props.append("writeNR") }
            if c.properties.contains(.notify) { props.append("notify") }
            if c.properties.contains(.indicate) { props.append("indicate") }
            log("  char \(c.uuid.uuidString)  [\(props.joined(separator: ","))]")

            if c.properties.contains(.notify) || c.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: c)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log("订阅 \(characteristic.uuid.uuidString) 失败: \(error.localizedDescription)")
        } else {
            log("已订阅 \(characteristic.uuid.uuidString)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let hex = hexString(data)
        log("← \(characteristic.uuid.uuidString.prefix(8)) (\(data.count)B) \(hex)")

        guard cfg.command == "run" else { return }

        let hit: Bool
        if cfg.anyNotify {
            hit = true
        } else if let m = cfg.matchHex {
            if data.count >= cfg.matchOffset + m.count {
                let start = data.startIndex + cfg.matchOffset
                let slice = Array(data[start..<(start + m.count)])
                hit = slice == m
            } else {
                hit = false
            }
        } else {
            hit = false
        }

        guard hit else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFire) * 1000 >= Double(cfg.debounceMS) else { return }
        lastFire = now
        log("★ 命中规则，注入 \(cfg.keyName)")
        postKey(keySpec, mods: cfg.mods)
    }
}

// MARK: - 参数解析

func printUsage() {
    print("""
    djimicd — DJI Mic 发射器 BLE 探测 / 按键映射

    用法:
      djimicd scan  [--seconds 8]                 扫描并列出附近 BLE 设备
      djimicd dump  [--name "DJI Mic"] [--uuid X] 连接并打印所有通知帧（不注入按键）
      djimicd run   [--match "AA BB"] [--any] [--key right_command] [--debounce 400]

    参数:
      --name <前缀>     按设备名前缀匹配（默认 "DJI Mic"）
      --uuid <UUID>     按 CoreBluetooth 的 peripheral UUID 匹配（更稳定，推荐先用 dump 拿到）
      --match <HEX>     命中规则：通知帧在该偏移处的字节序列
      --offset <n>      --match 的字节偏移，默认 0
      --any             任何通知都触发（仅调试用）
      --key <名字>      注入的按键，默认 right_command
                        可选: right_command/left_command/right_option/left_option/
                              right_control/left_control/right_shift/left_shift/
                              f13..f19/escape/space/return/tab
      --mods <组合>     附加修饰键，逗号分隔: cmd,opt,ctrl,shift
      --debounce <ms>   去抖，默认 400
      --log <路径>      同时写入日志文件

    退出: Ctrl-C
    """)
}

let argv = CommandLine.arguments
if argv.count > 1 {
    if argv[1] == "--help" || argv[1] == "-h" { printUsage(); exit(0) }
    cfg.command = argv[1]
}

var i = 2
while i < argv.count {
    switch argv[i] {
    case "--name":
        if i + 1 < argv.count { i += 1; cfg.namePrefix = argv[i] }
    case "--uuid":
        if i + 1 < argv.count { i += 1; cfg.targetUUID = UUID(uuidString: argv[i]) }
    case "--seconds":
        if i + 1 < argv.count { i += 1; cfg.seconds = Double(argv[i]) ?? 8 }
    case "--match":
        if i + 1 < argv.count {
            i += 1
            guard let bytes = parseHex(argv[i]) else {
                print("--match 解析失败: \(argv[i])"); exit(1)
            }
            cfg.matchHex = bytes
        }
    case "--offset":
        if i + 1 < argv.count { i += 1; cfg.matchOffset = Int(argv[i]) ?? 0 }
    case "--key":
        if i + 1 < argv.count { i += 1; cfg.keyName = argv[i] }
    case "--mods":
        if i + 1 < argv.count {
            i += 1
            for m in argv[i].split(separator: ",") {
                switch m.trimmingCharacters(in: .whitespaces) {
                case "cmd": cfg.mods.insert(.maskCommand)
                case "opt": cfg.mods.insert(.maskAlternate)
                case "ctrl": cfg.mods.insert(.maskControl)
                case "shift": cfg.mods.insert(.maskShift)
                default: break
                }
            }
        }
    case "--debounce":
        if i + 1 < argv.count { i += 1; cfg.debounceMS = Int(argv[i]) ?? 400 }
    case "--any":
        cfg.anyNotify = true
    case "--log":
        if i + 1 < argv.count { i += 1; cfg.logPath = argv[i] }
    case "-h", "--help":
        printUsage(); exit(0)
    default:
        break
    }
    i += 1
}

guard cfg.matchOffset >= 0, cfg.matchOffset <= Int.max - (cfg.matchHex?.count ?? 0) else {
    print("--offset 必须是非负且不会溢出的整数"); exit(1)
}

guard let spec = keyTable[cfg.keyName] else {
    print("未知按键名: \(cfg.keyName)");
    printUsage();
    exit(1)
}

if let p = cfg.logPath {
    if !FileManager.default.fileExists(atPath: p) {
        FileManager.default.createFile(atPath: p, contents: nil)
    }
    logHandle = FileHandle(forWritingAtPath: p)
    logHandle?.seekToEndOfFile()
}

log("djimicd 启动: command=\(cfg.command) name=\(cfg.namePrefix) key=\(cfg.keyName)"
    + (cfg.matchHex.map { " match=\(hexString(Data($0)))" } ?? (cfg.anyNotify ? " match=ANY" : "")))

if cfg.command == "run" {
    checkAccessibility(prompt: true)
}

let agent = Agent()
RunLoop.current.run()
