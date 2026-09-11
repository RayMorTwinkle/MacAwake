import Foundation
import IOKit
import MacAwakeCore

/// 系统 `SleepDisabled` 的**进程内**读取。
///
/// 走 IOKit 私有符号 `IOPMCopySystemPowerSettings`（`pmset` 内部同一条路，
/// 本机实测非 root 可读）：微秒级、不 fork。这是"每 2 秒检测一次外部改写"能成立的前提 ——
/// 用 `/usr/bin/pmset -g` 轮询的话每 2 秒 fork 一次，代价完全不能接受。
///
/// 符号不存在时降级到 `pmset -g`（fork，~20ms），并把调用方的轮询间隔拉长。
final class PowerStateReader {

    private typealias CopySystemPowerSettingsFn = @convention(c) () -> CFDictionary?

    private let copyFn: CopySystemPowerSettingsFn?

    init() {
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
        if let handle, let symbol = dlsym(handle, "IOPMCopySystemPowerSettings") {
            copyFn = unsafeBitCast(symbol, to: CopySystemPowerSettingsFn.self)
            Logger.info("PowerStateReader: IOKit 快路径可用")
        } else {
            copyFn = nil
            Logger.error("PowerStateReader: IOPMCopySystemPowerSettings 不可用，降级 pmset -g")
        }
    }

    /// true = 走 IOKit（可高频轮询）；false = 降级路径（调用方应降低轮询频率）
    var isFast: Bool { copyFn != nil }

    /// 读取当前 `SleepDisabled`
    func read() -> SleepState {
        if let copyFn, let dict = copyFn() as? [String: Any] {
            guard let value = dict["SleepDisabled"] as? NSNumber else { return .unknown }
            return value.boolValue ? .on : .off
        }
        let (exitCode, output) = PowerManager.run("/usr/bin/pmset", args: ["-g"])
        guard exitCode == 0 else { return .unknown }
        return PowerParsing.parseSleepDisabled(output)
    }

    /// 合盖状态：true = 已合盖；nil = 读不到（非笔记本机型等）。
    /// 仅用于日志/诊断，收敛本身不依赖它（有 2 秒轮询兜底）。
    var isLidClosed: Bool? {
        guard let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPMrootDomain")
        ) as io_service_t?, service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(
            service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        return (property.takeRetainedValue() as? NSNumber)?.boolValue
    }

    /// 系统开机时间（秒，epoch）。用于"重启后接管"的提示。
    static func bootTime() -> Double {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return 0 }
        return Double(boot.tv_sec)
    }
}
