import AppKit
import IOKit.ps
import MacAwakeCore

/// 会话控制：把「用户意图」与「系统当前值」分开管理。
///
/// - 意图由 App 持有（UserDefaults 只持久化到期时间；"是否开启"以系统值为准）
/// - 每 ~2 秒读一次系统值（IOKit，不 fork），与意图不符就重新施加 —— 这是本 App 的**漂移自愈**
/// - 定时到期 → 解除 + （可选）强制立即睡眠
/// - 退出 App 且定时未到 → 失效安全地恢复休眠
///
/// 为什么需要漂移自愈：实测本机 AlDente Pro 每 10 分钟用 `pmset` 重写整套 Energy Saver
/// 配置，把 `SleepDisabled` 清回 0（见 README「已知冲突」）。没有自愈的话，
/// 用户看到的现象就是"开启后只有第一次合盖有效，第二次又睡了"。
@MainActor
final class SessionController {

    // MARK: - 事件（由 App 层决定文案与呈现方式）

    enum Event {
        /// 检测到重启，按系统当前值接管（true = 接管为"合盖不休眠"）
        case rebootAdopted(sleepDisabled: Bool)
        /// 持久化的定时在 App 未运行期间已过期，启动时直接恢复休眠
        case missedDeadline
        /// 定时到期
        case timerExpired(forcedSleep: Bool)
        /// 检测到外部改写并已自动恢复
        case driftRepaired(count: Int)
    }

    private enum Keys {
        static let deadline = "session.deadline"
        static let forceSleepOnExpiry = "session.forceSleepOnExpiry"
        static let bootTime = "system.lastBootTime"
    }

    // MARK: - 对外状态

    private(set) var session: KeepAwakeSession?
    private(set) var systemState: SleepState = .unknown
    private(set) var driftRepairCount = 0
    private(set) var lastDriftAt: Date?
    private(set) var lastReleaseReason: ReleaseReason?

    /// 状态变化回调（App 层用它更新图标；不要在这里 fork pmset）
    var onSnapshotChange: (() -> Void)?
    /// 需要提示用户的事件
    var onEvent: ((Event) -> Void)?

    // MARK: - 依赖

    private let power = PowerManager()
    private let reader = PowerStateReader()
    private let defaults = UserDefaults.standard

    // MARK: - 定时器 / 观察者

    private var pollTimer: Timer?
    private var deadlineTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var powerSourceSource: CFRunLoopSource?
    private var lastWriteFailureLoggedAt: Date?

    /// 到点后是否强制立即睡眠（默认开：定时到点 = 马上睡，而不是"回到空闲才睡"）
    var forceSleepOnExpiry: Bool {
        get {
            guard defaults.object(forKey: Keys.forceSleepOnExpiry) != nil else { return true }
            return defaults.bool(forKey: Keys.forceSleepOnExpiry)
        }
        set { defaults.set(newValue, forKey: Keys.forceSleepOnExpiry) }
    }

    // MARK: - 生命周期

    func start() {
        adoptSystemState()
        startObservers()
        startPolling()
        reconcile(trigger: "start", countAsDrift: false)
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        cancelDeadlineTimer()
        for token in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        workspaceObservers.removeAll()
        if let powerSourceSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceSource, .commonModes)
            self.powerSourceSource = nil
        }
    }

    /// 启动时接管：系统值 = 1 说明会话仍在（`pmset` 跨重启持久），沿用系统当前设置。
    /// 重启只发一次提示，不改变设置。
    private func adoptSystemState() {
        systemState = reader.read()

        let deadline = (defaults.object(forKey: Keys.deadline) as? Double)
            .map { Date(timeIntervalSince1970: $0) }
        let boot = PowerStateReader.bootTime()
        let rebooted = RebootDetector.hasRebooted(
            storedBootTime: defaults.object(forKey: Keys.bootTime) as? Double,
            currentBootTime: boot
        )
        defaults.set(boot, forKey: Keys.bootTime)

        let plan = SessionEngine.adopt(systemOn: systemState == .on,
                                       persistedDeadline: deadline,
                                       now: Date())

        if plan.endsSession {
            session = nil
            defaults.removeObject(forKey: Keys.deadline)
            lastReleaseReason = plan.reason
            if plan.reason == .missedDeadline, let deadline {
                Logger.info("启动接管: 定时已在 \(deadline) 过期，恢复合盖休眠")
                onEvent?(.missedDeadline)
            } else {
                Logger.info("启动接管: 系统未开启合盖不休眠 (\(systemState))")
            }
        } else {
            session = KeepAwakeSession(startedAt: Date(), deadline: deadline)
            Logger.info("启动接管: 沿用系统设置 → \(deadline == nil ? "不限时" : "定时至 \(deadline!)")")
        }

        if rebooted {
            Logger.info("检测到重启: 沿用系统当前值 SleepDisabled=\(systemState == .on ? 1 : 0)")
            onEvent?(.rebootAdopted(sleepDisabled: systemState == .on))
        }
    }

    // MARK: - 用户操作

    /// 开启合盖不休眠；duration = nil 表示不限时
    func turnOn(duration: TimeInterval?) {
        let now = Date()
        session = KeepAwakeSession(startedAt: now, deadline: duration.map { now.addingTimeInterval($0) })
        persistDeadline()
        driftRepairCount = 0
        lastDriftAt = nil
        lastReleaseReason = nil
        Logger.info("用户开启合盖不休眠: \(duration.map { "定时 \(Int($0)) 秒" } ?? "不限时")")
        reconcile(trigger: "userOn", countAsDrift: false)
    }

    /// 关闭合盖不休眠
    func turnOff() {
        session = nil
        defaults.removeObject(forKey: Keys.deadline)
        cancelDeadlineTimer()
        lastReleaseReason = .userOff
        Logger.info("用户关闭合盖不休眠")
        reconcile(trigger: "userOff", countAsDrift: false)
    }

    /// 延长（不限时会话会变成从当前算起的定时会话）
    func extend(by interval: TimeInterval) {
        guard let current = session else {
            turnOn(duration: interval)
            return
        }
        let base = max(Date(), current.deadline ?? Date())
        session = KeepAwakeSession(startedAt: current.startedAt,
                                  deadline: base.addingTimeInterval(interval))
        persistDeadline()
        Logger.info("延长会话 \(Int(interval)) 秒 → 新截止 \(session?.deadline.map(String.init(describing:)) ?? "-")")
        reconcile(trigger: "extend", countAsDrift: false)
    }

    /// 菜单打开 / 手动刷新时收敛一次（发现漂移立即修复，不必等下一次轮询）
    func reconcileNow() {
        reconcile(trigger: "menuOpen")
    }

    /// 退出 App 的失效安全：定时会话的承诺无法兑现（进程和定时器都没了），所以释放；
    /// 不限时会话保持 —— `pmset` 本来就跨重启持久，用户要的是"开着就一直开着"。
    /// - Returns: 是否真的执行了释放
    @discardableResult
    func releaseOnQuit() -> Bool {
        guard let current = session, current.isTimed else { return false }
        Logger.info("退出 App 且定时未到 → 恢复合盖休眠（失效安全）")
        session = nil
        defaults.removeObject(forKey: Keys.deadline)
        cancelDeadlineTimer()
        lastReleaseReason = .userOff
        if case .failure(let error) = power.setSleepDisabled(false) {
            Logger.error("退出时释放失败: \(error.localizedDescription)")
        } else {
            systemState = .off
        }
        return true
    }

    // MARK: - 收敛

    /// 收敛：算出期望值 → 与实际不符就写入；然后处理会话结束 / 定时器。
    /// - Parameter countAsDrift: 轮询与事件触发为 true（外部改写要计数并提示）；
    ///   用户操作与启动为 false，避免把"自己刚写的"当成漂移。
    private func reconcile(trigger: String, countAsDrift: Bool = true) {
        systemState = reader.read()
        let plan = SessionEngine.plan(session: session,
                                      now: Date(),
                                      forceSleepOnExpiry: forceSleepOnExpiry)

        if !SessionEngine.isSatisfied(plan.desiredSleepDisabled, actual: systemState) {
            let isDrift = countAsDrift && plan.desiredSleepDisabled && session != nil
            if isDrift {
                Logger.info("检测到外部改写(漂移) trigger=\(trigger)：期望 1 实际 \(systemState)，准备重新施加")
            }
            switch power.setSleepDisabled(plan.desiredSleepDisabled) {
            case .success:
                systemState = plan.desiredSleepDisabled ? .on : .off
                if isDrift {
                    driftRepairCount += 1
                    lastDriftAt = Date()
                    Logger.info("漂移已自愈(#\(driftRepairCount)) trigger=\(trigger) → SleepDisabled=\(plan.desiredSleepDisabled ? 1 : 0)")
                    onEvent?(.driftRepaired(count: driftRepairCount))
                }
            case .failure(let error):
                logWriteFailureOnce("收敛失败 trigger=\(trigger): \(error.localizedDescription)")
            }
        }

        if plan.endsSession {
            endSession(plan: plan, trigger: trigger)
        } else if session != nil {
            scheduleDeadline()
        }

        onSnapshotChange?()
    }

    private func endSession(plan: SessionPlan, trigger: String) {
        session = nil
        defaults.removeObject(forKey: Keys.deadline)
        cancelDeadlineTimer()
        lastReleaseReason = plan.reason
        if let reason = plan.reason {
            Logger.info("会话结束: \(reason.rawValue) trigger=\(trigger)")
        }
        guard plan.reason == .timerExpired else { return }

        if plan.forceSleep {
            if case .failure(let error) = power.forceSleepNow() {
                logWriteFailureOnce("强制睡眠失败: \(error.localizedDescription)")
            }
        }
        onEvent?(.timerExpired(forcedSleep: plan.forceSleep))
    }

    /// 写操作失败只记一次/分钟，避免降级路径下刷爆日志
    private func logWriteFailureOnce(_ message: String) {
        let now = Date()
        if let last = lastWriteFailureLoggedAt, now.timeIntervalSince(last) < 60 { return }
        lastWriteFailureLoggedAt = now
        Logger.error(message)
    }

    private func persistDeadline() {
        if let deadline = session?.deadline {
            defaults.set(deadline.timeIntervalSince1970, forKey: Keys.deadline)
        } else {
            defaults.removeObject(forKey: Keys.deadline)
        }
    }

    // MARK: - 定时器

    private func startPolling() {
        let interval: TimeInterval = reader.isFast ? 2 : 10
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcile(trigger: "poll") }
        }
        timer.tolerance = interval * 0.3
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        Logger.info("漂移检测轮询间隔 \(interval)s（后端 \(reader.isFast ? "IOKit" : "pmset 降级")）")
    }

    private func scheduleDeadline() {
        cancelDeadlineTimer()
        guard let deadline = session?.deadline else { return }
        let delay = max(0.05, deadline.timeIntervalSinceNow)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.reconcile(trigger: "deadline") }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer
    }

    private func cancelDeadlineTimer() {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
    }

    // MARK: - 事件观察者（唤醒 / 即将睡眠 / 电源切换）

    private func startObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.willSleepNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reconcile(trigger: "workspace") }
            }
            workspaceObservers.append(token)
        }
        startPowerSourceObserver()
    }

    private func startPowerSourceObserver() {
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let controller = Unmanaged<SessionController>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in controller.reconcile(trigger: "powerSource") }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(
            callback, Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Logger.error("电源切换观察者注册失败（不影响轮询自愈）")
            return
        }
        let runLoopSource = source.takeRetainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        powerSourceSource = runLoopSource
    }
}
