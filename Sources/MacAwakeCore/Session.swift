import Foundation

// MARK: - 会话模型

/// 「合盖不休眠」会话 = **用户意图** + 到期时间。
///
/// 这个模型存在的理由：系统值（`pmset` 的 `SleepDisabled`）会被外部进程改写
/// （实测：AlDente Pro 每 10 分钟用 `pmset` 重写整套 Energy Saver 配置，把它清回 0）。
/// 一旦把"系统当前值"当成"用户意图"，外部改写就等于用户自己关掉了开关。
/// 所以意图必须由 App 自己持有，系统值只是需要被持续收敛到的目标。
public struct KeepAwakeSession: Equatable, Sendable {

    /// 会话开始时间
    public let startedAt: Date

    /// 到期时间；nil = 不限时
    public let deadline: Date?

    public init(startedAt: Date, deadline: Date? = nil) {
        self.startedAt = startedAt
        self.deadline = deadline
    }

    /// 是否为定时会话
    public var isTimed: Bool { deadline != nil }

    /// 剩余秒数；不限时返回 nil；已到期返回 <= 0
    public func remaining(now: Date) -> TimeInterval? {
        guard let deadline else { return nil }
        return deadline.timeIntervalSince(now)
    }

    /// 是否已到期（不限时永远为 false）
    public func isExpired(now: Date) -> Bool {
        guard let remaining = remaining(now: now) else { return false }
        return remaining <= 0
    }
}

// MARK: - 收敛决策

/// 会话结束原因（写日志 / 通知用）
public enum ReleaseReason: String, Equatable, Sendable {
    /// 用户手动关闭
    case userOff
    /// 定时到期
    case timerExpired
    /// 定时到期时 App 不在运行（崩溃 / 被杀 / 重启后才打开）
    case missedDeadline = "missed"
}

/// 一次收敛应该做什么。纯数据，便于用单元测试锁死行为。
public struct SessionPlan: Equatable, Sendable {

    /// 期望的系统 `SleepDisabled` 值（true = 1）
    public let desiredSleepDisabled: Bool

    /// 本次收敛后会话是否应结束（清空意图）
    public let endsSession: Bool

    /// 结束后是否立刻强制系统睡眠
    public let forceSleep: Bool

    /// 结束原因；仅 `endsSession` 为 true 时非空
    public let reason: ReleaseReason?

    public init(desiredSleepDisabled: Bool,
                endsSession: Bool = false,
                forceSleep: Bool = false,
                reason: ReleaseReason? = nil) {
        self.desiredSleepDisabled = desiredSleepDisabled
        self.endsSession = endsSession
        self.forceSleep = forceSleep
        self.reason = reason
    }
}

/// 纯函数决策引擎：不读时钟、不碰系统，所有环境事实由参数注入 —— 这是可单测的关键。
public enum SessionEngine {

    /// 周期性 / 事件触发的收敛决策。
    /// 判定顺序：无会话 → 期望关闭；已到期 → 期望关闭且结束会话；否则 → 期望开启。
    public static func plan(session: KeepAwakeSession?,
                            now: Date,
                            forceSleepOnExpiry: Bool) -> SessionPlan {
        guard let session else {
            return SessionPlan(desiredSleepDisabled: false)
        }
        if session.isExpired(now: now) {
            return SessionPlan(desiredSleepDisabled: false,
                               endsSession: true,
                               forceSleep: forceSleepOnExpiry,
                               reason: .timerExpired)
        }
        return SessionPlan(desiredSleepDisabled: true)
    }

    /// 启动时接管：系统值 = 1 说明会话仍在（`pmset` 跨重启持久），沿用系统当前设置。
    /// 但**持久化的到期时间已过**时立即结束（原因 missed）——
    /// 否则 App 被 kill -9 后，一个 30 分钟的定时会变成"永远不休眠"。
    public static func adopt(systemOn: Bool, persistedDeadline: Date?, now: Date) -> SessionPlan {
        guard systemOn else {
            return SessionPlan(desiredSleepDisabled: false, endsSession: true)
        }
        if let deadline = persistedDeadline, deadline <= now {
            return SessionPlan(desiredSleepDisabled: false, endsSession: true, reason: .missedDeadline)
        }
        return SessionPlan(desiredSleepDisabled: true)
    }

    /// 系统当前值是否已符合期望。`unknown`（读不到）一律视为不符合，触发一次写入 + 回读校验。
    public static func isSatisfied(_ desired: Bool, actual: SleepState) -> Bool {
        switch actual {
        case .on: return desired
        case .off: return !desired
        case .unknown: return false
        }
    }
}

// MARK: - 重启检测

public enum RebootDetector {

    /// 开机时间是否变化（容差 1 秒，避免读数抖动）。
    /// 没有记录过（首次运行）时返回 false —— 首次启动不该被当成"重启后接管"来提示。
    public static func hasRebooted(storedBootTime: Double?, currentBootTime: Double) -> Bool {
        guard let stored = storedBootTime, stored > 0, currentBootTime > 0 else { return false }
        return abs(stored - currentBootTime) > 1
    }
}
