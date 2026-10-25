import Foundation
import CoreGraphics

/// 内建屏幕亮度控制：私有 DisplayServices 框架，dlsym 动态探测。
/// 拿不到符号时优雅降级（动作记日志"亮度控制不可用"），绝不影响其它功能。
@MainActor
enum BrightnessService {

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)

    private static var setFn: (@convention(c) (CGDirectDisplayID, Double) -> Int32)? = {
        guard let handle else { return nil }
        for name in ["DisplayServicesSetLinearBrightness", "DisplayServicesSetBrightness"] {
            if let symbol = dlsym(handle, name) {
                Logger.info("BrightnessService: 使用 \(name)")
                return unsafeBitCast(symbol, to: (@convention(c) (CGDirectDisplayID, Double) -> Int32).self)
            }
        }
        Logger.error("BrightnessService: DisplayServices 无可用亮度符号")
        return nil
    }()

    private static var getFn: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Double>) -> Int32)? = {
        guard let handle else { return nil }
        for name in ["DisplayServicesGetLinearBrightness", "DisplayServicesGetBrightness"] {
            if let symbol = dlsym(handle, name) {
                return unsafeBitCast(symbol, to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Double>) -> Int32).self)
            }
        }
        return nil
    }()

    static var isAvailable: Bool { setFn != nil }

    /// 当前主屏亮度（0–1）；不可用返回 nil
    static func get() -> Double? {
        guard let getFn else { return nil }
        var value = 0.0
        guard getFn(CGMainDisplayID(), &value) == 0 else { return nil }
        return min(1, max(0, value))
    }

    /// 设置主屏亮度（0–1，0 = 最低）。成功返回 true。
    @discardableResult
    static func set(_ level: Double) -> Bool {
        guard let setFn else {
            Logger.error("亮度控制不可用（DisplayServices 符号缺失），跳过 set(\(level))")
            return false
        }
        let clamped = min(1, max(0, level))
        let result = setFn(CGMainDisplayID(), clamped)
        if result != 0 {
            Logger.error("设置亮度失败: exit=\(result) level=\(clamped)")
            return false
        }
        Logger.info("屏幕亮度 → \(Int(clamped * 100))%")
        return true
    }
}
