import Foundation
import IOKit.ps

/// 电源快照：IOKit 一次读出电量 / 电源类型 / 瞬时功率（不 fork）。
/// 能效调度（电池门控）、自动化（电量触发）、统计（功率采样）共用这一个来源。
struct PowerSnapshot: Equatable, Sendable {
    /// 是否外接电源（无电池机型恒为 true）
    let isOnAC: Bool
    /// 电量 %；无电池为 nil
    let capacityPercent: Int?
    let isCharging: Bool
    /// 瞬时功率（瓦）= |电流 mA × 电压 mV| / 1e6；读不到为 nil。
    /// 电池放电时是放电功率（正值）。
    let watts: Double?
    let timestamp: Date

    static let onACDesktop = PowerSnapshot(isOnAC: true, capacityPercent: nil,
                                           isCharging: false, watts: nil, timestamp: .distantPast)
}

enum PowerSnapshotService {

    /// 读一次系统电源状态（微秒级，IOKit，无子进程）。
    /// 注意：IOPSCopyPowerSourcesList 返回的数组元素是未 retain 的句柄，
    /// 不能桥接成 Swift Array（析构会过度 release 直接段错误），必须走 CFArray C API。
    static func read(now: Date = Date()) -> PowerSnapshot {
        guard let infoRaw = IOPSCopyPowerSourcesInfo() else {
            return .onACDesktop
        }
        let info = infoRaw.takeRetainedValue()

        guard let listRaw = IOPSCopyPowerSourcesList(info) else {
            return .onACDesktop
        }
        let list = listRaw.takeRetainedValue() as CFArray

        var isOnAC = true
        var capacity: Int?
        var isCharging = false
        var watts: Double?

        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let handle = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
            // Get 规则：返回值不持有，用 takeUnretainedValue
            guard let desc = IOPSGetPowerSourceDescription(info, handle)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            guard (desc[kIOPSIsPresentKey as String] as? Bool) ?? true else { continue }

            let state = desc[kIOPSPowerSourceStateKey as String] as? String
            if state == kIOPSBatteryPowerValue {
                isOnAC = false
                capacity = desc[kIOPSCurrentCapacityKey as String] as? Int ?? capacity
                isCharging = (desc[kIOPSIsChargingKey as String] as? Bool) ?? false
                if let amps = desc["Amperage"] as? Int,
                   let volts = desc["Voltage"] as? Int, volts > 0 {
                    watts = Double(abs(amps)) * Double(volts) / 1_000_000
                }
            }
        }
        return PowerSnapshot(isOnAC: isOnAC, capacityPercent: capacity,
                             isCharging: isCharging, watts: watts, timestamp: now)
    }
}
