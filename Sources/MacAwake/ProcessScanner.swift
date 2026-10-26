import Foundation
import AppKit
import Darwin

/// 进程扫描：libproc 枚举 + sysctl KERN_PROCARGS2 拿完整命令行 + rusage 增量算 CPU%。
/// （proc_pidpath 在本机会对一切进程返回 EOVERFLOW，sysctl 路线是可靠替代；
///   其效果与 bash 版 `ps aux` 一致：拿到的是 argv 而非解析后的可执行路径。）
/// 能效调度的目标发现、自动化的"CPU 前 N"、平衡模式的负载判断都靠它。
final class ProcessScanner {

    struct ProcInfo: Identifiable, Equatable {
        let pid: pid_t
        /// 完整命令行（argv 拼接）——规则匹配的目标文本
        let argsText: String
        /// 展示名：.app 名或可执行名
        let name: String
        var cpuPercent: Double
        var id: Int32 { pid }
    }

    /// 上次采样：pid → (累计 CPU 纳秒, 时刻)
    private var lastCPU: [pid_t: (nanos: UInt64, at: Date)] = [:]
    private var lastWall: Date?
    /// 上次系统 tick 快照（allCPU busy / total）
    private var lastTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

    init() {
        _ = systemCPUPercent() // 建立基准
    }

    /// 枚举所有可读 argv 的进程，附 CPU%（两次调用间的增量；首次调用 CPU% 为 0）
    func snapshot() -> [ProcInfo] {
        var buffer = [pid_t](repeating: 0, count: 4096)
        let count = proc_listallpids(&buffer, 4096)
        guard count > 0 else { return [] }

        let now = Date()
        let wall = lastWall.map { now.timeIntervalSince($0) }
        let myPID = ProcessInfo.processInfo.processIdentifier
        var result: [ProcInfo] = []
        var newLast: [pid_t: (UInt64, Date)] = [:]

        for i in 0..<Int(count) {
            let pid = buffer[i]
            guard pid > 0, pid != myPID else { continue }
            guard let argsText = Self.procArgs(pid: pid), !argsText.isEmpty else { continue }

            var cpuNanos: UInt64 = 0
            if let rusage = readRusage(pid) {
                cpuNanos = rusage.user + rusage.system
            }

            var percent = 0.0
            if let wall, wall > 0.05, let prev = lastCPU[pid] {
                let delta = Double(cpuNanos > prev.nanos ? cpuNanos - prev.nanos : 0)
                percent = delta / 1e9 / wall * 100
            }
            if cpuNanos > 0 { newLast[pid] = (cpuNanos, now) }

            result.append(ProcInfo(pid: pid,
                                   argsText: argsText,
                                   name: Self.displayName(of: pid, argsText: argsText),
                                   cpuPercent: percent))
        }

        lastCPU = newLast
        lastWall = now
        return result
    }

    /// CPU 占用前 N（跳过低噪音进程）
    func topCPU(_ n: Int, from procs: [ProcInfo]? = nil) -> [ProcInfo] {
        let pool = procs ?? snapshot()
        return pool
            .filter { $0.cpuPercent >= 1.0 }
            .sorted { $0.cpuPercent > $1.cpuPercent }
            .prefix(n)
            .map { $0 }
    }

    /// 系统整体 CPU%（host_processor_info tick 增量，首次调用为 0）
    func systemCPUPercent() -> Double {
        var count = natural_t(0)
        var cpuInfo: processor_info_array_t?
        var numCPUInfo = mach_msg_type_number_t(0)
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &count, &cpuInfo, &numCPUInfo)
        guard kr == KERN_SUCCESS, let ticks = cpuInfo else { return 0 }
        defer {
            let size = vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: ticks)), size)
        }

        // CPU_LOAD_INFO 每核 4 个 tick：user, system, idle, nice
        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        for core in 0..<Int(count) {
            let base = core * 4
            user += UInt64(ticks[base])
            system += UInt64(ticks[base + 1])
            idle += UInt64(ticks[base + 2])
            nice += UInt64(ticks[base + 3])
        }

        guard let prev = lastTicks else {
            lastTicks = (user, system, idle, nice)
            return 0
        }
        lastTicks = (user, system, idle, nice)

        let dBusy = Double((user - prev.user) + (system - prev.system) + (nice - prev.nice))
        let dTotal = dBusy + Double(idle - prev.idle)
        guard dTotal > 0 else { return 0 }
        return dBusy / dTotal * 100
    }

    /// 进程是否还活着
    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    /// 读某进程完整命令行（sysctl KERN_PROCARGS2，仅对同用户/自身进程有效）。
    /// 实测布局：argc(4B) + **可执行路径**␀ + 填充␀… + 真实 argv[0..]␀… + 环境变量。
    /// 可执行路径是额外多出来的一个字符串（所以收到 argc+1 个再停）；
    /// 环境变量必含 '='，遇到即停。拼串效果与 bash 版 `ps aux` 匹配口径一致。
    static func procArgs(pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var buf = [UInt8](repeating: 0, count: 65536)
        var size = buf.count
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4, size <= buf.count else { return nil }
        let n = Int(size)
        let argc = Int32(buf[0]) | (Int32(buf[1]) << 8) | (Int32(buf[2]) << 16) | (Int32(buf[3]) << 24)
        guard argc > 0, argc < 4096 else { return nil }

        var strings: [String] = []
        var i = 4
        let limit = Int(argc) + 1
        while i < n, strings.count < limit {
            while i < n && buf[i] == 0 { i += 1 }   // 跳过对齐填充
            guard i < n else { break }
            let start = i
            while i < n && buf[i] != 0 { i += 1 }
            let piece = String(decoding: buf[start..<i], as: UTF8.self)
            if piece.contains("=") { break }        // 环境变量区开始
            strings.append(piece)
            i += 1
        }
        return strings.isEmpty ? nil : strings.joined(separator: " ")
    }

    /// 展示名：从 argv[0] 提取 .app 名；不像路径时退回 proc_name
    static func displayName(of pid: pid_t, argsText: String) -> String {
        let firstArg = argsText.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? argsText
        if let appRange = firstArg.range(of: #"/([^/]+\.app)/Contents/"#, options: .regularExpression) {
            let inner = firstArg[appRange]
            return String(inner.dropFirst().dropLast("/Contents/".count + 1))
        }
        if firstArg.contains("/") {
            return (firstArg as NSString).lastPathComponent
        }
        var nameBuffer = [CChar](repeating: 0, count: 1024)
        guard proc_name(pid, &nameBuffer, 1024) > 0 else { return firstArg }
        return String(cString: nameBuffer)
    }

    /// 供钉核前拿名称用
    static func describe(pid: pid_t) -> String {
        guard let args = procArgs(pid: pid) else { return "PID \(pid)" }
        return displayName(of: pid, argsText: args)
    }

    // MARK: - 目标查找（自动化动作用）

    /// 命令行/名称包含关键词的进程 PID（大小写不敏感；可用注入的快照避免重复扫描）
    func pids(matchingKeyword keyword: String, in procs: [ProcInfo]? = nil) -> [pid_t] {
        guard !keyword.isEmpty else { return [] }
        let pool = procs ?? snapshot()
        let myPID = ProcessInfo.processInfo.processIdentifier
        return pool.compactMap { proc in
            guard proc.pid != myPID,
                  proc.argsText.localizedCaseInsensitiveContains(keyword)
                  || proc.name.localizedCaseInsensitiveContains(keyword) else { return nil }
            return proc.pid
        }
    }

    /// 指定应用名下全部进程（主进程 + 同 bundle 的 Helper/渲染进程）
    func pids(ofApp appName: String) -> [pid_t] {
        guard !appName.isEmpty else { return [] }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
            && $0.localizedName == appName
            && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        guard let app = apps.first else {
            // 找不到运行中的同名 App：退化成关键词匹配
            return pids(matchingKeyword: appName)
        }
        guard let bundlePath = app.bundleURL?.path else { return [app.processIdentifier] }
        let myPID = ProcessInfo.processInfo.processIdentifier
        return snapshot().compactMap { proc in
            guard proc.pid != myPID else { return nil }
            guard let first = proc.argsText.split(separator: " ").first,
                  first.contains("/") else { return nil }
            return first.hasPrefix(bundlePath + "/") ? proc.pid : nil
        }
    }

    // MARK: - rusage

    private struct RusagePair { let user: UInt64; let system: UInt64 }

    /// 注意（本机实测的坑，勿改回二级指针写法）：
    /// XNU 的 proc_pid_rusage 把参数值直接当 copyout 目标；Swift 导入的参数类型
    /// `UnsafeMutablePointer<rusage_info_t?>` 会诱导写法把"指向指针的栈上槽位"传进去，
    /// 内核一次写 ~296 字节直接打穿栈帧（__stack_chk_fail 必崩）。
    /// 这里必须传堆缓冲自身的地址，4KB 足够容纳任何版本的 rusage_info_v4。
    private func readRusage(_ pid: pid_t) -> RusagePair? {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var result: Int32 = -1
        buffer.withUnsafeMutableBytes { raw in
            let dst = raw.baseAddress!.assumingMemoryBound(to: rusage_info_t?.self)
            result = proc_pid_rusage(pid, RUSAGE_INFO_V4, dst)
        }
        guard result == 0, let base = buffer.withUnsafeBytes({ $0.baseAddress }) else { return nil }
        // rusage_info_v4 布局：ri_uuid[16] → ri_user_time → ri_system_time
        let user = base.load(fromByteOffset: 16, as: UInt64.self)
        let system = base.load(fromByteOffset: 24, as: UInt64.self)
        return RusagePair(user: user, system: system)
    }
}
