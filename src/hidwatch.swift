// hidwatch.swift
// 诊断工具：列出 macOS 当前枚举到的所有 HID 设备，并实时打印 Keyboard(0x07) /
// Consumer(0x0C) 输入事件。用于回答一个关键问题：
//   "DJI Mic Mini 2 发射器通过蓝牙连上 Mac 后，macOS 到底有没有把它当成 HID 设备？"
//
// 编译：swiftc -O -o ../bin/hidwatch hidwatch.swift -framework IOKit
// 运行：./bin/hidwatch --list        # 只列设备
//       ./bin/hidwatch --filter DJI  # 只打印名字含 DJI 的设备事件
//       ./bin/hidwatch               # 打印全部设备事件（噪音大，适合排查）
//
// 注意：需要在 系统设置 → 隐私与安全性 → 输入监控 中给终端 App 授权，
//       否则 IOHIDManager 可能拿不到任何设备（本程序会明确提示）。

import Foundation
import IOKit.hid

struct Opts {
    var filter: String?
    var listOnly = false
    var allUsages = false
}

var gOpts = Opts()
var gManager: IOHIDManager?

func hx(_ v: UInt32) -> String { String(format: "%02X", v) }

func pad(_ s: String, _ n: Int) -> String {
    if s.count >= n { return String(s.prefix(n)) }
    return s + String(repeating: " ", count: n - s.count)
}

func prop(_ d: IOHIDDevice, _ key: String) -> Any? {
    return IOHIDDeviceGetProperty(d, key as CFString)
}

func productName(_ d: IOHIDDevice) -> String {
    return (prop(d, kIOHIDProductKey) as? String) ?? "<unknown>"
}

func describe(_ d: IOHIDDevice) -> String {
    let name = productName(d)
    let vendor = (prop(d, kIOHIDVendorIDKey) as? Int) ?? -1
    let product = (prop(d, kIOHIDProductIDKey) as? Int) ?? -1
    let transport = (prop(d, kIOHIDTransportKey) as? String) ?? "?"
    let serial = (prop(d, kIOHIDSerialNumberKey) as? String) ?? "-"
    let location = (prop(d, kIOHIDLocationIDKey) as? Int) ?? -1
    return "\(pad(name, 34)) vendor=0x\(String(format: "%04X", vendor)) "
        + "product=0x\(String(format: "%04X", product)) "
        + "transport=\(pad(transport, 10)) serial=\(serial) location=0x\(String(format: "%08X", location))"
}

func usagePageName(_ page: UInt32) -> String {
    switch page {
    case 0x01: return "Generic Desktop"
    case 0x07: return "Keyboard"
    case 0x0B: return "Telephony"
    case 0x0C: return "Consumer"
    default:   return "Page\(hx(page))"
    }
}

func usageName(_ page: UInt32, _ usage: UInt32) -> String {
    if page == 0x0C {
        switch usage {
        case 0xE9: return "Volume Increment"
        case 0xEA: return "Volume Decrement"
        case 0xCD: return "Play/Pause"
        case 0xB5: return "Scan Next Track"
        case 0xB6: return "Scan Previous Track"
        case 0xE2: return "Mute"
        default:   return ""
        }
    }
    if page == 0x07 {
        switch usage {
        case 0xE7: return "Right GUI (Right Command)"
        case 0xE3: return "Left GUI (Left Command)"
        default:   return ""
        }
    }
    return ""
}

// MARK: - C 回调

func deviceCallback(context: UnsafeMutableRawPointer?,
                    result: IOReturn,
                    sender: UnsafeMutableRawPointer?,
                    device: IOHIDDevice) {
    print("[+device] \(describe(device))")
}

func valueCallback(context: UnsafeMutableRawPointer?,
                   result: IOReturn,
                   sender: UnsafeMutableRawPointer?,
                   value: IOHIDValue) {
    let element = IOHIDValueGetElement(value)
    let page = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)

    if !gOpts.allUsages && page != 0x07 && page != 0x0C { return }

    let device = IOHIDElementGetDevice(element)
    let name = productName(device)

    if let f = gOpts.filter, !f.isEmpty,
       !name.localizedCaseInsensitiveContains(f) { return }

    let intValue = IOHIDValueGetIntegerValue(value)
    let ts = String(format: "%.3f", Date().timeIntervalSince1970)
    let extra = usageName(page, usage)
    print("\(ts)  \(pad(name, 28)) page=0x\(hx(page)) usage=0x\(hx(usage)) "
        + "value=\(intValue)  \(usagePageName(page))\(extra.isEmpty ? "" : " / " + extra)")
}

func allDevices() -> [IOHIDDevice] {
    guard let manager = gManager, let set = IOHIDManagerCopyDevices(manager) else { return [] }
    let count = CFSetGetCount(set)
    guard count > 0 else { return [] }
    var ptrs = [UnsafeRawPointer?](repeating: nil, count: count)
    CFSetGetValues(set, &ptrs)
    return ptrs.compactMap { raw in
        guard let raw else { return nil }
        return unsafeBitCast(raw, to: IOHIDDevice.self)
    }
}

func printUsage() {
    print("""
    hidwatch — 查看 macOS 枚举到的 HID 设备与按键事件

    用法:
      hidwatch --list            只列出当前所有 HID 设备
      hidwatch --filter DJI      只打印名字含 "DJI" 的设备事件
      hidwatch --all-usages      打印所有 usage page（默认只看键盘/消费者页）
      hidwatch                   打印全部设备事件

    判读:
      · --list 里出现 DJI 设备但 transport=Bluetooth  → macOS 把它当 HID，按键有机会直接映射
      · --list 里完全没有 DJI                          → 只作为音频设备接入，按键走不通 HID
      · 按下连接键时出现 page=0x0C usage=0xE9          → 就是"音量+"，可直接用 Karabiner 映射
    """)
}

// MARK: - main

let argv = CommandLine.arguments
var idx = 1
while idx < argv.count {
    switch argv[idx] {
    case "--filter":
        if idx + 1 < argv.count { idx += 1; gOpts.filter = argv[idx] }
    case "--list":
        gOpts.listOnly = true
    case "--all-usages":
        gOpts.allUsages = true
    case "-h", "--help":
        printUsage(); exit(0)
    default:
        break
    }
    idx += 1
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
gManager = manager

IOHIDManagerSetDeviceMatching(manager, nil)
IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceCallback, nil)
IOHIDManagerRegisterInputValueCallback(manager, valueCallback, nil)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
if openResult != kIOReturnSuccess {
    FileHandle.standardError.write(
        "IOHIDManagerOpen 失败: 0x\(String(format: "%08X", openResult))\n"
        .data(using: .utf8)!)
    FileHandle.standardError.write(
        "→ 多半是缺少「输入监控」权限：系统设置 → 隐私与安全性 → 输入监控，加入并勾选你的终端 App。\n"
        .data(using: .utf8)!)
    exit(2)
}

print("== 当前 HID 设备（\(allDevices().count) 个）==")
for d in allDevices() {
    print(describe(d))
}
print("== 设备列表结束 ==\n")

if gOpts.listOnly {
    exit(0)
}

if let f = gOpts.filter {
    print("只显示名称含 \"\(f)\" 的设备事件；按 Ctrl-C 退出。\n")
} else {
    print("显示全部设备的键盘/消费者事件；按 Ctrl-C 退出。\n")
}

RunLoop.current.run()
