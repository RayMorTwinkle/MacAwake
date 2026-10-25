import Foundation

/// taskpolicy 执行器：把进程钉到小核（-b）/ 放回大核（-B）。
/// 记住所有被本 App 动过的 PID，停止/退出时统一恢复。
/// taskpolicy 对自己用户的进程免 root，无需 sudoers。
@MainActor
final class TaskPolicyService {

    enum Assignment: String {
        case efficiency = "b"    // 后台/能效核
        case performance = "B"   // 前台/性能核
    }

    struct Tracked: Identifiable, Equatable {
        let pid: pid_t
        let name: String
        var assignment: Assignment
        var cpuPercent: Double
        var id: Int32 { pid }
    }

    /// pid → 记录（能效引擎 + 自动化的钉核都在这里登记）
    private(set) var tracked: [pid_t: Tracked] = [:]

    var onLog: ((String) -> Void)?

    /// taskpolicy 执行失败的 pid（本轮运行内不再重试，防日志刷屏）
    private(set) var failedPids: Set<pid_t> = []

    /// 设置某 PID 的核偏好；success 返回是否真的执行了 taskpolicy
    @discardableResult
    func set(pid: pid_t, to assignment: Assignment, cpuPercent: Double = 0) -> Bool {
        let name = ProcessScanner.describe(pid: pid)

        let (code, _) = PowerManager.run("/usr/sbin/taskpolicy", args: ["-\(assignment.rawValue)", "-p", "\(pid)"])
        guard code == 0 else {
            failedPids.insert(pid)
            log("taskpolicy 失败（PID \(pid) \(name) → \(assignment)）exit=\(code)")
            return false
        }
        tracked[pid] = Tracked(pid: pid, name: name, assignment: assignment, cpuPercent: cpuPercent)
        log("已钉住 \(name) (PID \(pid)) → \(assignment == .efficiency ? "小核" : "大核")")
        return true
    }

    /// 更新已跟踪进程的 CPU 读数（平衡模式 / 表格展示用）
    func updateCPU(pid: pid_t, cpuPercent: Double) {
        tracked[pid]?.cpuPercent = cpuPercent
    }

    /// 把某 PID 恢复默认调度（放回大核），并取消跟踪
    @discardableResult
    func restore(pid: pid_t) -> Bool {
        guard tracked[pid] != nil else { return false }
        let (code, _) = PowerManager.run("/usr/sbin/taskpolicy", args: ["-B", "-p", "\(pid)"])
        let name = tracked[pid]?.name ?? "PID \(pid)"
        tracked[pid] = nil
        if code == 0 {
            log("已恢复 \(name) (PID \(pid)) → 默认调度")
        }
        return code == 0
    }

    /// 恢复所有被本 App 钉过的进程
    func restoreAll() {
        let pids = Array(tracked.keys)
        for pid in pids { restore(pid: pid) }
        if !pids.isEmpty { log("已恢复全部 \(pids.count) 个被钉进程") }
    }

    /// 清理已退出的进程记录
    func pruneDead() -> [pid_t] {
        let dead = tracked.keys.filter { !ProcessScanner.isAlive($0) }
        for pid in dead {
            log("\(tracked[pid]?.name ?? "PID \(pid)") 已退出，移出跟踪")
            tracked[pid] = nil
        }
        failedPids = failedPids.filter { ProcessScanner.isAlive($0) }
        return dead
    }

    var trackedList: [Tracked] {
        tracked.values.sorted { $0.cpuPercent > $1.cpuPercent }
    }

    private func log(_ line: String) {
        Logger.info("[能效] \(line)")
        onLog?(line)
    }
}
