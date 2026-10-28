// serialkeyd.swift
// 蓝牙串口（SPP / RFCOMM）按键守护进程
//
// 背景：DJI Mic Mini 2 发射器连上 Mac 后，除 HFP 音频外还会建立一个蓝牙串口，
//       在 /dev/cu.DJIMicMini2-XXXXXX 上以 125/129 字节定长帧持续输出数据。
//       本工具读取该端口，检测"帧型异常"或指定字节序列，命中即注入键盘事件。
//
// 编译：swiftc -O -o ../bin/serialkeyd serialkeyd.swift \
//         -framework CoreGraphics -framework ApplicationServices
//
// 用法：
//   ./bin/serialkeyd monitor                       # 只观察：每秒统计帧率，打印新出现的帧型
//   ./bin/serialkeyd run --match "AA 14 00"        # 命中即触发
//   ./bin/serialkeyd run --match "AA 14 00" --key f13 --debounce 500
//   ./bin/serialkeyd monitor --port /dev/cu.DJIMicMini2-C8701B
//
// 判读：monitor 模式下按下发射器连接键，若在按键瞬间出现一行 [NEW SIG]，
//       就说明按键事件混在这条流里，把该帧的前几个字节填进 --match 即可。

import Foundation
import CoreGraphics
import ApplicationServices

setvbuf(stdout, nil, _IONBF, 0)

// MARK: - 配置

struct Config {
    var command = "monitor"
    var port: String?
    var matchHex: [UInt8]?
    var keyName = "right_command"
    var mods: CGEventFlags = []
    var debounceMS = 500
    var logPath: String?
}

var cfg = Config()

struct KeySpec {
    let code: CGKeyCode
    let modifierFlag: CGEventFlags?
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
    if let h = logHandle, let d = line.data(using: .utf8) { h.write(d) }
}

func hexString(_ bytes: ArraySlice<UInt8>) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
}

func parseHex(_ s: String) -> [UInt8]? {
    let cleaned = s.replacingOccurrences(of: "0x", with: "")
        .replacingOccurrences(of: ",", with: " ")
        .replacingOccurrences(of: "-", with: " ")
    let parts = cleaned.split(separator: " ")
    if parts.count == 1, let only = parts.first {
        let str = String(only)
        guard str.count % 2 == 0, str.count >= 2 else { return nil }
        var out: [UInt8] = []
        var i = str.startIndex
        while i < str.endIndex {
            let j = str.index(i, offsetBy: 2)
            guard let b = UInt8(str[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }
    var out: [UInt8] = []
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

func checkAccessibility() {
    let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let trusted = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    log(trusted ? "辅助功能：已授权" : "⚠️ 辅助功能未授权，注入按键会静默失败（系统设置 → 隐私与安全性 → 辅助功能）")
}

// MARK: - 串口

func findPort() -> String? {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(atPath: "/dev") else { return nil }
    let candidates = items.filter {
        $0.hasPrefix("cu.") && ($0.lowercased().contains("djimic") || $0.lowercased().contains("dji"))
    }.sorted()
    return candidates.first.map { "/dev/" + $0 }
}

func openPort(_ path: String) -> Int32 {
    let fd = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK)
    if fd < 0 { return -1 }
    var tio = termios()
    if tcgetattr(fd, &tio) == 0 {
        cfmakeraw(&tio)
        tio.c_cflag |= tcflag_t(CLOCAL | CREAD)
        _ = tcsetattr(fd, TCSANOW, &tio)
    }
    return fd
}

// MARK: - 主循环

final class Watcher {
    var fd: Int32 = -1
    var portPath: String
    var buffer: [UInt8] = []
    var knownSignatures = Set<String>()
    var warmupUntil = Date().addingTimeInterval(3)
    var lastFire = Date.distantPast

    // 统计
    var bytesWindow = 0
    var packetsWindow = 0
    var lastReport = Date()

    init(port: String) { self.portPath = port }

    func connect() -> Bool {
        fd = openPort(portPath)
        if fd < 0 {
            log("打开 \(portPath) 失败：\(String(cString: strerror(errno)))")
            return false
        }
        buffer.removeAll(keepingCapacity: true)
        log("已打开 \(portPath)")
        return true
    }

    func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    func run() {
        if !connect() { scheduleReconnect(); return }
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                bytesWindow += n
                scan()
                reportIfNeeded()
            } else if n == 0 {
                log("端口关闭，准备重连")
                close(); scheduleReconnect(); return
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    usleep(2_000)
                    reportIfNeeded()
                } else {
                    log("读取错误 \(errno)，准备重连")
                    close(); scheduleReconnect(); return
                }
            }
            if buffer.count > 1 << 20 { buffer.removeFirst(buffer.count - (1 << 19)) }
        }
    }

    func scheduleReconnect() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            if let p = cfg.port ?? findPort() {
                self.portPath = p
                self.run()
            } else {
                log("未找到 DJI 串口，2 秒后重试")
                self.scheduleReconnect()
            }
        }
    }

    /// 以 55 77 05 作为子帧同步头切分，统计帧型；同时做 --match 匹配
    func scan() {
        let sync: [UInt8] = [0x55, 0x77, 0x05]
        var cursor = 0
        while true {
            guard let start = find(sync, from: cursor) else { break }
            // 下一帧起点
            let next = find(sync, from: start + sync.count) ?? buffer.count
            let frameLen = next - start
            let sig = signature(at: start, length: frameLen)
            packetsWindow += 1
            if Date() > warmupUntil && !knownSignatures.contains(sig) {
                let preview = hexString(buffer[start..<min(start + 16, buffer.count)])
                log("[NEW SIG] len=\(frameLen)  \(preview)")
                knownSignatures.insert(sig)
            } else if !knownSignatures.contains(sig) {
                knownSignatures.insert(sig)
            }
            checkMatch(at: start)
            cursor = next
        }
        // 丢弃已处理数据，保留尾部可能不完整的帧
        if cursor > 0 { buffer.removeFirst(min(cursor, buffer.count)) }
    }

    func find(_ needle: [UInt8], from: Int) -> Int? {
        guard buffer.count >= needle.count, from <= buffer.count - needle.count else { return nil }
        var i = from
        while i <= buffer.count - needle.count {
            if buffer[i] == needle[0] {
                var ok = true
                for k in 1..<needle.count where buffer[i + k] != needle[k] { ok = false; break }
                if ok { return i }
            }
            i += 1
        }
        return nil
    }

    func signature(at start: Int, length: Int) -> String {
        let head = buffer[start..<min(start + 3, buffer.count)]
        let lenBucket = length <= 140 ? String(length) : ">140"
        return "\(hexString(head))/\(lenBucket)"
    }

    func checkMatch(at start: Int) {
        guard cfg.command == "run", let m = cfg.matchHex else { return }
        guard start + m.count <= buffer.count else { return }
        guard Array(buffer[start..<(start + m.count)]) == m else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFire) * 1000 >= Double(cfg.debounceMS) else { return }
        lastFire = now
        log("★ 命中 \(hexString(m[0..<m.count]))，注入 \(cfg.keyName)")
        postKey(keyTable[cfg.keyName]!, mods: cfg.mods)
    }

    func reportIfNeeded() {
        let now = Date()
        let dt = now.timeIntervalSince(lastReport)
        guard dt >= 1.0 else { return }
        let pps = Double(packetsWindow) / dt
        let kbps = Double(bytesWindow) / dt / 1024
        let sigs = knownSignatures.sorted().joined(separator: "  ")
        log(String(format: "%.0f 帧/s  %.1f KB/s  已知帧型: %@", pps, kbps, sigs))
        bytesWindow = 0
        packetsWindow = 0
        lastReport = now
    }
}

// MARK: - 参数

func printUsage() {
    print("""
    serialkeyd — 蓝牙串口按键守护进程

    用法:
      serialkeyd monitor [--port /dev/cu.xxx]
      serialkeyd run --match "AA 14 00" [--key right_command] [--debounce 500]

    参数:
      --port <路径>    串口设备，默认自动查找名字含 DJI 的 /dev/cu.*
      --match <HEX>    命中序列（按帧起点对齐比较）
      --key <名字>     right_command / f13 / escape ... 默认 right_command
      --mods <组合>    cmd,opt,ctrl,shift
      --debounce <ms>  默认 500
      --log <路径>     同时写日志文件
    """)
}

let argv = CommandLine.arguments
if argv.count > 1 { cfg.command = argv[1] }
var i = 2
while i < argv.count {
    switch argv[i] {
    case "--port": if i + 1 < argv.count { i += 1; cfg.port = argv[i] }
    case "--match":
        if i + 1 < argv.count {
            i += 1
            guard let b = parseHex(argv[i]) else { print("--match 解析失败"); exit(1) }
            cfg.matchHex = b
        }
    case "--key": if i + 1 < argv.count { i += 1; cfg.keyName = argv[i] }
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
    case "--debounce": if i + 1 < argv.count { i += 1; cfg.debounceMS = Int(argv[i]) ?? 500 }
    case "--log": if i + 1 < argv.count { i += 1; cfg.logPath = argv[i] }
    case "-h", "--help": printUsage(); exit(0)
    default: break
    }
    i += 1
}

if let p = cfg.logPath {
    if !FileManager.default.fileExists(atPath: p) {
        FileManager.default.createFile(atPath: p, contents: nil)
    }
    logHandle = FileHandle(forWritingAtPath: p)
    logHandle?.seekToEndOfFile()
}

guard let spec = keyTable[cfg.keyName] else {
    print("未知按键名: \(cfg.keyName)"); exit(1)
}
_ = spec

let port = cfg.port ?? findPort()
guard let port else {
    log("没有找到 DJI 蓝牙串口。请先在系统设置 → 蓝牙 中连接 DJI Mic 发射器。")
    exit(2)
}

log("serialkeyd 启动: command=\(cfg.command) port=\(port) key=\(cfg.keyName)"
    + (cfg.matchHex.map { " match=\(hexString($0[0..<$0.count]))" } ?? ""))

if cfg.command == "run" { checkAccessibility() }

let watcher = Watcher(port: port)
watcher.run()
