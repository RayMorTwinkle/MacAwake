import AppKit
import Combine
import Foundation

/// 正在运行的应用商店（移植自 EfficiencyTool feat/easy-mode-process-picker）：
/// NSWorkspace 列 GUI App（图标/名称/bundle 路径），ProcessScanner 数据按
/// bundle 路径前缀归并 CPU 与进程数（自动覆盖 Helper / 渲染进程）。
/// 每行提供：整组钉小核 / 整组恢复 / 把 App 名加入持续监控规则。
@MainActor
final class AppPickerStore: ObservableObject {

    struct RunningApp: Identifiable {
        let id: String            // bundleIdentifier（兜底名字）
        let name: String
        let pid: pid_t
        let icon: NSImage
        let bundlePath: String?   // "/Applications/Google Chrome.app"
        var cpu: Double = 0
        var procCount: Int = 0
    }

    @Published private(set) var apps: [RunningApp] = []
    @Published var lastLog: String?

    private var timer: Timer?
    private let scanner: ProcessScanner
    private let taskPolicy: TaskPolicyService
    private weak var engine: EfficiencyEngine?
    /// 最近一次扫描结果（行内按钮直接复用，避免重扫打乱 CPU 采样基线）
    private var lastProcs: [ProcessScanner.ProcInfo] = []

    init(scanner: ProcessScanner, taskPolicy: TaskPolicyService, engine: EfficiencyEngine) {
        self.scanner = scanner
        self.taskPolicy = taskPolicy
        self.engine = engine
    }

    func startAutoRefresh(every interval: TimeInterval = 4) {
        guard timer == nil else { return }
        refresh()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
    }

    /// 刷新 App 列表 + CPU 归并（scanner 数据在同一次 tick 内自洽）
    func refresh(with procs: [ProcessScanner.ProcInfo]? = nil) {
        let wsApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
            && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        guard !wsApps.isEmpty else {
            apps = []
            return
        }

        var entries: [RunningApp] = wsApps.map { ra in
            RunningApp(id: ra.bundleIdentifier ?? (ra.localizedName ?? String(ra.processIdentifier)),
                       name: ra.localizedName ?? "PID \(ra.processIdentifier)",
                       pid: ra.processIdentifier,
                       icon: ra.icon ?? NSImage(),
                       bundlePath: ra.bundleURL?.path)
        }

        // 进程归并：argv 里的可执行路径以 "<bundlePath>/" 开头即属于该 App
        let pool = procs ?? scanner.snapshot()
        lastProcs = pool
        for proc in pool {
            guard let path = firstPathToken(proc.argsText) else { continue }
            for i in entries.indices {
                if let bp = entries[i].bundlePath, path.hasPrefix(bp + "/") {
                    entries[i].cpu += proc.cpuPercent
                    entries[i].procCount += 1
                    break
                }
            }
        }

        entries.sort {
            if $0.cpu != $1.cpu { return $0.cpu > $1.cpu }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        apps = entries
    }

    private func firstPathToken(_ argsText: String) -> String? {
        guard let token = argsText.split(separator: " ").first else { return nil }
        return token.contains("/") ? String(token) : nil
    }

    // MARK: - 行内动作（整组生效）

    /// 该 App 名下当前所有进程的 PID（主进程 + 同 bundle 的 Helper）
    func pidsOf(_ app: RunningApp) -> [pid_t] {
        guard let bp = app.bundlePath else { return [app.pid] }
        return lastProcs.compactMap { proc in
            guard let path = firstPathToken(proc.argsText), path.hasPrefix(bp + "/") else { return nil }
            return proc.pid
        }
    }

    /// 整组钉小核（即使监控引擎没开也立即生效）
    func limitNow(_ app: RunningApp) {
        let pids = pidsOf(app)
        guard !pids.isEmpty else { log("「\(app.name)」没有可操作的进程"); return }
        var ok = 0
        for pid in pids where taskPolicy.set(pid: pid, to: .efficiency) { ok += 1 }
        log(ok > 0 ? "已把「\(app.name)」的 \(ok) 个进程钉到小核" : "「\(app.name)」操作失败")
    }

    /// 整组恢复默认调度
    func restoreNow(_ app: RunningApp) {
        let pids = pidsOf(app)
        var ok = 0
        for pid in pids { if taskPolicy.restore(pid: pid) { ok += 1 } }
        log("「\(app.name)」已恢复 \(ok) 个进程")
    }

    /// 把 App 名加入持续监控关键词（引擎开着就自动管它的所有新进程）
    func addToRules(_ app: RunningApp) {
        guard var patterns = engine?.customPatternsLines, !patterns.contains(app.name) else {
            log("「\(app.name)」已在监控规则里")
            return
        }
        patterns.append(app.name)
        engine?.customPatternsText = patterns.joined(separator: "\n")
        log("「\(app.name)」已加入监控规则")
    }

    func isWatched(_ app: RunningApp) -> Bool {
        engine?.customPatternsLines.contains(app.name) ?? false
    }

    /// 该 App 是否已被本应用钉核（至少一个进程在跟踪）
    func isLimited(_ app: RunningApp) -> Bool {
        pidsOf(app).contains { taskPolicy.tracked[$0] != nil }
    }

    private func log(_ line: String) {
        Logger.info("[应用选择器] \(line)")
        lastLog = line
    }
}
