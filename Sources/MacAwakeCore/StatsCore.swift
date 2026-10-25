import Foundation

// MARK: - 统计模型与聚合（纯函数）

/// 一次合盖事件的完整记录：合盖 →（睡眠 或 重新开盖）。
public struct LidEpisode: Codable, Equatable, Identifiable, Sendable {
    public enum EndKind: String, Codable, Sendable {
        case slept      // 合盖后系统入睡
        case reopened   // 没睡，重新开了盖
    }

    public var id: UUID
    /// 合盖时刻
    public var closedAt: Date
    /// 结束时刻（入睡或开盖）
    public var endedAt: Date?
    public var endKind: EndKind?
    /// 合盖瞬间电量 %
    public var batteryAtClose: Int?
    /// 结束时电量 %
    public var batteryAtEnd: Int?
    /// 期间采样得到的平均放电功率（瓦）；插电或无读数为 nil
    public var averageWatts: Double?

    public init(id: UUID = UUID(),
                closedAt: Date,
                endedAt: Date? = nil,
                endKind: EndKind? = nil,
                batteryAtClose: Int? = nil,
                batteryAtEnd: Int? = nil,
                averageWatts: Double? = nil) {
        self.id = id
        self.closedAt = closedAt
        self.endedAt = endedAt
        self.endKind = endKind
        self.batteryAtClose = batteryAtClose
        self.batteryAtEnd = batteryAtEnd
        self.averageWatts = averageWatts
    }

    /// 合盖持续秒数（未结束的用"现在"算）
    public func duration(now: Date = Date()) -> TimeInterval {
        (endedAt ?? now).timeIntervalSince(closedAt)
    }

    /// 本次掉电 %（结束才有效）
    public var drainPercent: Int? {
        guard let start = batteryAtClose, let end = batteryAtEnd else { return nil }
        return max(0, start - end)
    }

    /// 掉电速度 %/小时（结束才有效）
    public func drainPerHour(now: Date = Date()) -> Double? {
        guard let drain = drainPercent, duration(now: now) > 60 else { return nil }
        return Double(drain) / (duration(now: now) / 3600)
    }
}

/// 聚合摘要：给统计页一屏看完的数字
public struct StatsSummary: Equatable, Sendable {
    /// 样本里的合盖总时长（秒）
    public var totalLidSeconds: TimeInterval = 0
    /// 其中真正睡着的合盖时长
    public var sleptLidSeconds: TimeInterval = 0
    /// 合盖 → 入睡平均耗时（秒）
    public var avgCloseToSleepSeconds: TimeInterval?
    /// 平均掉电速度（%/小时，只统计记录了电量的已完成事件）
    public var avgDrainPerHour: Double?
    /// 平均放电功率（瓦）
    public var avgWatts: Double?
    /// 完成事件数
    public var episodeCount: Int = 0
}

public enum StatsMath {

    /// 聚合一段事件（通常传"最近 N 天"的切片）
    public static func summarize(_ episodes: [LidEpisode], now: Date = Date()) -> StatsSummary {
        var s = StatsSummary()
        s.episodeCount = episodes.count

        var closeToSleep: [TimeInterval] = []
        var drains: [Double] = []
        var watts: [Double] = []

        for e in episodes {
            let d = e.duration(now: now)
            s.totalLidSeconds += d
            if e.endKind == .slept {
                s.sleptLidSeconds += d
                closeToSleep.append(d)
            }
            if let rate = e.drainPerHour(now: now) { drains.append(rate) }
            if let w = e.averageWatts { watts.append(w) }
        }

        if !closeToSleep.isEmpty { s.avgCloseToSleepSeconds = closeToSleep.reduce(0, +) / Double(closeToSleep.count) }
        if !drains.isEmpty { s.avgDrainPerHour = drains.reduce(0, +) / Double(drains.count) }
        if !watts.isEmpty { s.avgWatts = watts.reduce(0, +) / Double(watts.count) }
        return s
    }
}

/// 持久化根：事件列表 + 每日累计（App 运行时长 / 合盖时长）
public struct StatsStore: Codable, Equatable, Sendable {

    public struct DayTotals: Codable, Equatable, Sendable {
        public var appActiveSeconds: TimeInterval = 0
        public var lidClosedSeconds: TimeInterval = 0
        public init() {}
    }

    /// 按日累计，key = "yyyy-MM-dd"（本地时区）
    public var daily: [String: DayTotals] = [:]

    /// 合盖事件（新的在后；裁剪由调用方负责）
    public var episodes: [LidEpisode] = []

    public init() {}

    /// 今天（本地时区）的 key
    public static func dayKey(for date: Date = Date()) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }
}
