import Foundation
import AppKit
import MacAwakeCore

/// 自动化引擎：事件源（合盖/开盖/插拔电/电量采样）→ 规则匹配 → 顺序执行动作块。
///
/// 事件检测靠 2 秒轮询（IOKit 直读，不 fork）：合盖状态、电源类型、电量。
/// 电量触发是"越线"语义（从 ≥X 跌到 <X 才发一次），不会反复刷。
@MainActor
final class AutomationEngine: ObservableObject {

    @Published private(set) var rules: [AutomationRule] = [] {
        didSet { persist() }
    }
    /// 运行记录（环形 100 条，UI 展示）
    @Published private(set) var runLog: [String] = []

    private let defaults = UserDefaults.standard
    private let scanner: ProcessScanner
    private let taskPolicy: TaskPolicyService
    private let power: PowerManager
    private let controller: SessionController
    /// 复用同一个 reader：init 会 dlopen + 写日志，不能每 tick 新建
    private let lidReader = PowerStateReader()
    private var pollTimer: Timer?

    // 事件检测的上一次状态
    private var lastLidClosed: Bool?
    private var lastOnAC: Bool?
    private var lastBatteryPercent: Int?
    /// sticky 钉核（开盖自动解除的那批）
    private var stickyPIDs: Set<pid_t> = []

    init(scanner: ProcessScanner,
         taskPolicy: TaskPolicyService,
         power: PowerManager,
         controller: SessionController) {
        self.scanner = scanner
        self.taskPolicy = taskPolicy
        self.power = power
        self.controller = controller

        if let data = defaults.data(forKey: "automation.rules"),
           let decoded = try? JSONDecoder().decode([AutomationRule].self, from: data), !decoded.isEmpty {
            rules = decoded
        } else {
            rules = AutomationPresets.all // 首次启动灌预置
            persist()
        }
    }

    func start() {
        guard pollTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        log("自动化引擎启动（\(rules.filter(\.enabled).count) 条规则启用）")
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        releaseSticky(reason: "引擎停止")
    }

    // MARK: - 规则 CRUD（UI 调用）

    func update(_ rule: AutomationRule) {
        guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[idx] = rule
    }

    func add(_ rule: AutomationRule) {
        rules.append(rule)
    }

    func addPresets() {
        for preset in AutomationPresets.all where !rules.contains(where: { $0.name == preset.name }) {
            rules.append(preset)
        }
    }

    func remove(id: UUID) {
        rules.removeAll { $0.id == id }
    }

    /// 手动触发一条规则（测试/演示用：不走触发器判断）
    func runManually(_ rule: AutomationRule) {
        log("手动触发「\(rule.name)」")
        execute(rule.actions, ruleName: rule.name)
    }

    // MARK: - 事件轮询

    private func tick() {
        let snapshot = PowerSnapshotService.read()
        let lidClosed = lidReader.isLidClosed ?? false

        var events: [AutomationContext.Event] = []

        if let prev = lastLidClosed, prev != lidClosed {
            events.append(.lidChanged(closed: lidClosed))
            if lidClosed { onLidClosed() } else { onLidOpened() }
        }
        if let prev = lastOnAC, prev != snapshot.isOnAC {
            events.append(.powerSourceChanged(onAC: snapshot.isOnAC))
        }
        // 电量采样事件每轮都发（求值器自己判断"越线"）
        events.append(.batteryTick)

        lastLidClosed = lidClosed
        lastOnAC = snapshot.isOnAC

        for event in events {
            let context = AutomationContext(event: event,
                                            isLidClosed: lidClosed,
                                            previousBatteryPercent: lastBatteryPercent,
                                            currentBatteryPercent: snapshot.capacityPercent ?? lastBatteryPercent ?? 100)
            for rule in AutomationEvaluator.matchingRules(rules, context: context) {
                log("触发「\(rule.name)」← \(describe(event))")
                execute(rule.actions, ruleName: rule.name)
            }
        }

        lastBatteryPercent = snapshot.capacityPercent ?? lastBatteryPercent
    }

    private func describe(_ event: AutomationContext.Event) -> String {
        switch event {
        case .lidChanged(let closed): return closed ? "合盖" : "开盖"
        case .powerSourceChanged(let onAC): return onAC ? "接入电源" : "拔掉电源"
        case .batteryTick: return "电量变化"
        }
    }

    // MARK: - 动作执行

    private func execute(_ actions: [AutomationAction], ruleName: String) {
        for action in actions {
            switch action {
            case .setBrightness(let level):
                if BrightnessService.set(level) {
                    log("「\(ruleName)」亮度 → \(Int(level * 100))%")
                } else {
                    log("「\(ruleName)」亮度设置不可用")
                }

            case .pinTopCPU(let n, let sticky):
                let top = scanner.topCPU(n)
                for proc in top where taskPolicy.tracked[proc.pid] == nil {
                    if taskPolicy.set(pid: proc.pid, to: .efficiency, cpuPercent: proc.cpuPercent),
                       sticky {
                        stickyPIDs.insert(proc.pid)
                    }
                }
                log("「\(ruleName)」CPU 前 \(n) 已钉小核：\(top.map { "\($0.name)(\(Int($0.cpuPercent))%)" }.joined(separator: "、"))")

            case .unpinAll:
                taskPolicy.restoreAll()
                stickyPIDs.removeAll()
                log("「\(ruleName)」已解除全部钉核")

            case .forceSleep:
                log("「\(ruleName)」强制睡眠")
                Notifier.post(title: "MacAwake 自动化", body: "规则「\(ruleName)」触发强制睡眠")
                if case .failure(let error) = power.forceSleepNow() {
                    log("强制睡眠失败: \(error.localizedDescription)")
                }

            case .keepAwakeOn(let seconds):
                log("「\(ruleName)」开启合盖不休眠\(seconds.map { " \($0 / 60) 分钟" } ?? "（不限时）")")
                controller.turnOn(duration: seconds.map { Double($0) })

            case .keepAwakeOff:
                log("「\(ruleName)」关闭合盖不休眠")
                controller.turnOff()

            case .notify(let message):
                Notifier.post(title: "MacAwake 自动化", body: message)
                log("「\(ruleName)」通知：\(message)")
            }
        }
    }

    // MARK: - sticky 钉核生命周期

    private func onLidClosed() {
        log("检测到合盖")
    }

    private func onLidOpened() {
        log("检测到开盖")
        releaseSticky(reason: "开盖")
    }

    private func releaseSticky(reason: String) {
        guard !stickyPIDs.isEmpty else { return }
        for pid in stickyPIDs {
            taskPolicy.restore(pid: pid)
        }
        log("\(reason)：解除 \(stickyPIDs.count) 个 sticky 钉核")
        stickyPIDs.removeAll()
    }

    // MARK: - 持久化 / 日志

    private func persist() {
        if let data = try? JSONEncoder().encode(rules) {
            defaults.set(data, forKey: "automation.rules")
        }
    }

    private func log(_ line: String) {
        let stamped = "\(Date().formatted(.dateTime.hour().minute().second())) \(line)"
        runLog.append(stamped)
        if runLog.count > 100 { runLog.removeFirst(runLog.count - 100) }
        Logger.info("[自动化] \(line)")
    }
}
