import Foundation
import MacAwakeCore

/// 能效调度引擎（移植自 EfficiencyTool，原生重写：无 bash 子进程、无 stdout 解析）。
///
/// 主循环：自适应间隔扫描进程 → 规则匹配 → 新目标钉小核/大核。
/// 平衡循环：2 秒一次，已钉进程 CPU 飙高放回大核、降下来再钉回小核（带滞回）。
/// 电池门控：默认只在用电池时钉核（插电时性能不敏感，减少调度扰动）。
@MainActor
final class EfficiencyEngine: ObservableObject {

    enum Mode: String {
        case efficiency   // 钉小核（默认）
        case performance  // 钉大核
    }

    // MARK: - 可配置状态（UserDefaults 持久化）

    @Published var isRunning = false
    @Published var mode: Mode {
        didSet { defaults.set(mode.rawValue, forKey: "efficiency.mode") }
    }
    /// 自定义关键词（UI 上按行编辑）
    @Published var customPatternsText: String {
        didSet { defaults.set(customPatternsText, forKey: "efficiency.patterns") }
    }
    @Published var useDefaultRules: Bool {
        didSet { defaults.set(useDefaultRules, forKey: "efficiency.useDefaults") }
    }
    /// 只在电池供电时钉核
    @Published var batteryOnly: Bool {
        didSet { defaults.set(batteryOnly, forKey: "efficiency.batteryOnly") }
    }
    @Published var balanceEnabled: Bool {
        didSet { defaults.set(balanceEnabled, forKey: "efficiency.balance") }
    }
    /// 系统整体 CPU 门槛（%），低于它平衡循环不动任何东西
    @Published var cpuGatePercent: Double {
        didSet { defaults.set(cpuGatePercent, forKey: "efficiency.cpuGate") }
    }
    /// 单进程 CPU 放行阈值（%）
    @Published var balanceThreshold: Double {
        didSet { defaults.set(balanceThreshold, forKey: "efficiency.balanceThreshold") }
    }

    // MARK: - 运行时状态（UI 展示）

    @Published private(set) var nextScanAt: Date?
    @Published private(set) var lastSystemCPU: Double = 0
    @Published private(set) var logLines: [String] = []
    @Published private(set) var firedCount = 0

    private let defaults = UserDefaults.standard
    private let scanner: ProcessScanner
    let taskPolicy: TaskPolicyService
    private var scanTimer: Timer?
    private var balanceTimer: Timer?
    private var currentInterval: TimeInterval = ScanPlanner.initialInterval
    private var lastProcs: [ProcessScanner.ProcInfo] = []

    init(scanner: ProcessScanner, taskPolicy: TaskPolicyService) {
        self.scanner = scanner
        self.taskPolicy = taskPolicy

        mode = Mode(rawValue: defaults.string(forKey: "efficiency.mode") ?? "") ?? .efficiency
        customPatternsText = defaults.string(forKey: "efficiency.patterns") ?? ""
        useDefaultRules = defaults.object(forKey: "efficiency.useDefaults") as? Bool ?? true
        batteryOnly = defaults.object(forKey: "efficiency.batteryOnly") as? Bool ?? true
        balanceEnabled = defaults.object(forKey: "efficiency.balance") as? Bool ?? true
        cpuGatePercent = defaults.object(forKey: "efficiency.cpuGate") as? Double ?? 20
        balanceThreshold = defaults.object(forKey: "efficiency.balanceThreshold") as? Double ?? 100

        taskPolicy.onLog = { [weak self] line in self?.appendLog(line) }
    }

    var rules: CoreRules {
        let patterns = customPatternsText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return CoreRules(customPatterns: patterns, useDefaultRules: useDefaultRules)
    }

    var trackedList: [TaskPolicyService.Tracked] { taskPolicy.trackedList }

    // MARK: - 启停

    func start() {
        guard !isRunning else { return }
        isRunning = true
        currentInterval = ScanPlanner.initialInterval
        log("能效调度启动（\(mode == .efficiency ? "小核" : "大核") · \(rules.combinedRegex.isEmpty ? "无匹配规则" : rules.combinedRegex)）")
        scanNow() // 立即扫一次
        scheduleScan()
        startBalanceLoop()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        scanTimer?.invalidate(); scanTimer = nil
        balanceTimer?.invalidate(); balanceTimer = nil
        taskPolicy.restoreAll()
        nextScanAt = nil
        log("能效调度停止，已恢复全部被钉进程")
    }

    /// 立即扫描一次（UI 手动刷新也走这里）
    func scanNow() {
        let procs = scanner.snapshot()
        lastSystemCPU = scanner.systemCPUPercent()
        lastProcs = procs

        _ = taskPolicy.pruneDead()

        let power = PowerSnapshotService.read()
        let gated = batteryOnly && power.isOnAC

        if gated {
            log("外接电源（电池门控开启），本轮跳过钉核")
        } else {
            let matched = procs.filter { rules.matches($0.argsText) || rules.matches($0.name) }
            let newOnes = matched.filter { taskPolicy.tracked[$0.pid] == nil && !taskPolicy.failedPids.contains($0.pid) }
            for proc in newOnes {
                taskPolicy.set(pid: proc.pid,
                               to: mode == .efficiency ? .efficiency : .performance,
                               cpuPercent: proc.cpuPercent)
            }
            if newOnes.isEmpty {
                log("扫描：无新目标（匹配 \(matched.count) 个，系统 CPU \(Int(lastSystemCPU))%）")
            }
            currentInterval = ScanPlanner.nextInterval(current: currentInterval, newPins: newOnes.count)
            firedCount += newOnes.count
        }
        nextScanAt = Date().addingTimeInterval(currentInterval)
    }

    private func scheduleScan() {
        scanTimer?.invalidate()
        let timer = Timer(timeInterval: currentInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.scanNow()
                self.scheduleScan()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        scanTimer = timer
    }

    /// 平衡循环：只在效率模式 + 开启时工作
    private func startBalanceLoop() {
        balanceTimer?.invalidate()
        guard mode == .efficiency, balanceEnabled else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.balanceTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        balanceTimer = timer
    }

    private func balanceTick() {
        guard isRunning, mode == .efficiency, balanceEnabled else { return }

        let procs = scanner.snapshot()
        let systemCPU = scanner.systemCPUPercent()
        lastSystemCPU = systemCPU
        lastProcs = procs
        let byPID = Dictionary(uniqueKeysWithValues: procs.map { ($0.pid, $0.cpuPercent) })

        for (pid, record) in taskPolicy.tracked {
            let cpu = byPID[pid] ?? 0
            taskPolicy.updateCPU(pid: pid, cpuPercent: cpu)
            let decision = BalancePlanner.decide(cpuPercent: cpu,
                                                 isOnEfficiency: record.assignment == .efficiency,
                                                 threshold: balanceThreshold,
                                                 systemGatePercent: cpuGatePercent,
                                                 systemCpuPercent: systemCPU)
            switch decision {
            case .toPerformance:
                taskPolicy.set(pid: pid, to: .performance, cpuPercent: cpu)
                log("平衡：\(record.name) CPU \(Int(cpu))% 超阈值 → 放回大核")
            case .toEfficiency:
                taskPolicy.set(pid: pid, to: .efficiency, cpuPercent: cpu)
                log("平衡：\(record.name) CPU 降到 \(Int(cpu))% → 钉回小核")
            case .keep:
                break
            }
        }
    }

    // MARK: - 日志（环形 200 条，同时落文件）

    private func appendLog(_ line: String) {
        let stamped = "\(Date().formatted(.dateTime.hour().minute().second())) \(line)"
        logLines.append(stamped)
        if logLines.count > 200 { logLines.removeFirst(logLines.count - 200) }
        Logger.info("[能效] \(line)")
    }

    private func log(_ line: String) { appendLog(line) }

    /// 供 UI 定时刷新跟踪表
    func refreshPublished() {
        objectWillChange.send()
    }
}
