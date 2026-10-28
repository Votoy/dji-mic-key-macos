// usbmapd.c — 事件驱动的 DJI 接收器按键映射守护进程
//
// 与 watch-map.sh 的区别：
//   watch-map.sh  常驻 + 每秒轮询，每秒唤醒一次 CPU
//   usbmapd       通过 IOKit 匹配通知应用映射，另有 300 秒定时兜底。
//                 RunLoop 最长每秒返回一次检查退出信号，并非零唤醒。
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

    CFRunLoopTimerContext ctx = {0, NULL, NULL, NULL, NULL};
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(kCFAllocatorDefault,
                                 CFAbsoluteTimeGetCurrent() + 300.0,
                                 300.0, 0, 0, safety_timer, &ctx);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopDefaultMode);
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + selftest_seconds;

    if (!g_quiet) fprintf(stderr, "usbmapd ready (event-driven)\n");

    while (!g_stop) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, true);
        if (selftest_seconds > 0 && CFAbsoluteTimeGetCurrent() >= deadline) break;
    }

    CFRunLoopTimerInvalidate(timer);
    CFRelease(timer);
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, kCFRunLoopDefaultMode);
    IOObjectRelease(iterator);
    IONotificationPortDestroy(notify_port);
    print_footprint();
    return 0;
}
