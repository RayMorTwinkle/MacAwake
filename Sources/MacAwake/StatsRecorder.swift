import Foundation
import AppKit
import MacAwakeCore

/// 统计记录器：10 秒采样电量/功率/合盖状态，累计每日运行时长与合盖时长，
/// 记录"合盖 → 入睡/开盖"完整事件（含掉电、平均功率）。
/// 持久化到 Application Support/<bundle id>/stats.json —— dev 构建天然与正式版隔离。
@MainActor
final class StatsRecorder: ObservableObject {

    @Published private(set) var store = StatsStore()
    @Published private(set) var current = PowerSnapshot.onACDesktop
    @Published private(set) var isLidClosed = false

    private var pollTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var wattSamples: [Double] = []          // 当前合盖事件内的功率采样
    private var lastPersistAt = Date.distantPast
    private let fileURL: URL
    /// 复用同一个 reader：init 会 dlopen + 写日志，不能每 tick 新建
    private let lidReader = PowerStateReader()

    static let tickInterval: TimeInterval = 10

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let bundleID = Bundle.main.bundleIdentifier ?? "MacAwake"
        let dir = support.appendingPathComponent(bundleID, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("stats.json")
        load()
    }

    func start() {
        guard pollTimer == nil else { return }
        current = PowerSnapshotService.read()
        isLidClosed = lidReader.isLidClosed ?? false

        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleSystemSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick(forcePersist: true) }
        })
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        for token in observers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        observers.removeAll()
        persist()
    }

    /// 清空全部统计（UI 确认后调用）
    func clearAll() {
        store = StatsStore()
        wattSamples.removeAll()
        persist()
    }

    // MARK: - 采样

    private func tick(forcePersist: Bool = false) {
        let now = Date()
        current = PowerSnapshotService.read()

        // 合盖状态迁移（10 秒粒度；比 2 秒自动化轮询粗，但统计够用）
        let lidNow = lidReader.isLidClosed ?? false
        if lidNow != isLidClosed {
            if lidNow { openEpisode(at: now) } else { closeEpisode(end: .reopened, at: now) }
            isLidClosed = lidNow
        }

        // 累计
        accumulate()

        // 功率采样（仅电池放电时计入事件）
        if isLidClosed, !current.isOnAC, let watts = current.watts, watts > 0 {
            wattSamples.append(watts)
        }

        if forcePersist || now.timeIntervalSince(lastPersistAt) > 60 {
            persist()
        }
    }

    /// 系统即将睡眠：若正处合盖事件 → 以"入睡"收口（这是唯一能精确知道入睡时刻的机会）
    private func handleSystemSleep() {
        if isLidClosed {
            closeEpisode(end: .slept, at: Date())
        }
        persist()
    }

    // MARK: - 事件

    private func openEpisode(at date: Date) {
        // 上一条还没收口（异常路径），先补一个 reopened
        if let last = store.episodes.last, last.endedAt == nil {
            closeEpisode(end: .reopened, at: date)
        }
        var episode = LidEpisode(closedAt: date)
        episode.batteryAtClose = current.capacityPercent
        store.episodes.append(episode)
        wattSamples.removeAll()
        Logger.info("[统计] 合盖事件开始 电量=\(current.capacityPercent.map(String.init) ?? "-")%")
    }

    private func closeEpisode(end kind: LidEpisode.EndKind, at date: Date) {
        guard var episode = store.episodes.popLast(), episode.endedAt == nil else { return }
        episode.endedAt = date
        episode.endKind = kind
        episode.batteryAtEnd = current.capacityPercent
        if !wattSamples.isEmpty {
            episode.averageWatts = wattSamples.reduce(0, +) / Double(wattSamples.count)
        }
        store.episodes.append(episode)
        Logger.info("[统计] 合盖事件结束 \(kind.rawValue) 时长=\(Int(episode.duration(now: date)))s 掉电=\(episode.drainPercent.map(String.init) ?? "-")% 平均功率=\(episode.averageWatts.map { String(format: "%.1f", $0) } ?? "-")W")
        wattSamples.removeAll()
    }

    // MARK: - 聚合输出（UI 直读）

    /// 最近 N 天摘要
    func summary(days: Int = 7) -> StatsSummary {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        let window = store.episodes.filter { $0.closedAt >= cutoff }
        return StatsMath.summarize(window)
    }

    /// 区间内累计运行/合盖秒数
    func totals(days: Int = 7) -> (appSeconds: TimeInterval, lidSeconds: TimeInterval) {
        let keys = recentDayKeys(days: days)
        let app = keys.reduce(0.0) { $0 + (store.daily[$1]?.appActiveSeconds ?? 0) }
        let lid = keys.reduce(0.0) { $0 + (store.daily[$1]?.lidClosedSeconds ?? 0) }
        return (app, lid)
    }

    private func recentDayKeys(days: Int) -> [String] {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return (0..<days).compactMap { Calendar.current.date(byAdding: .day, value: -$0, to: Date()) }
            .map { fmt.string(from: $0) }
    }

    // MARK: - 持久化

    private func accumulate() {
        let key = StatsStore.dayKey()
        var day = store.daily[key] ?? StatsStore.DayTotals()
        day.appActiveSeconds += Self.tickInterval
        day.lidClosedSeconds += isLidClosed ? Self.tickInterval : 0
        store.daily[key] = day
    }

    private func persist() {
        lastPersistAt = Date()
        // 每日累计按 tick 已实时累加（accumulate 在 persist 前调用），无需补差
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let loaded = try? JSONDecoder().decode(StatsStore.self, from: data) else { return }
        store = loaded
        // 收口上次异常退出遗留的未结束事件
        if var last = store.episodes.last, last.endedAt == nil {
            last.endedAt = last.closedAt
            last.endKind = .reopened
            store.episodes[store.episodes.count - 1] = last
        }
        // 控制体积
        if store.episodes.count > 400 {
            store.episodes.removeFirst(store.episodes.count - 400)
        }
    }
}
