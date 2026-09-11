import Foundation
import MacAwakeCore

/// 电源管理：读取/修改合盖休眠状态。
/// 底层使用公开的 pmset 命令；修改需要 root（通过 sudoers 白名单免密）。
final class PowerManager {

    private static let percentPattern = try! NSRegularExpression(pattern: "(\\d+)%")
    private static let timePattern = try! NSRegularExpression(pattern: "(\\d+):(\\d+) remaining")

    /// 读取当前 SleepDisabled 状态（pmset -g 普通用户可读）。
    /// 只用于写操作后的回读校验；高频轮询走 `PowerStateReader`（IOKit，不 fork）。
    var currentState: SleepState {
        PowerParsing.parseSleepDisabled(Self.run("/usr/bin/pmset", args: ["-g"]).output)
    }

    /// 设置合盖不休眠。enable = true → 禁用合盖休眠；false → 恢复。
    /// 通过 sudoers 白名单免密执行 pmset。
    /// 只操作 disablesleep 一项：它已阻止全部睡眠（含合盖），
    /// 不动用户的 sleep（系统睡眠定时）设置，避免覆盖用户原有配置。
    func setSleepDisabled(_ enable: Bool) -> Result<Void, Error> {
        Logger.info("请求切换: \(enable ? "开启合盖不休眠" : "恢复合盖休眠")")

        // 先确保 sudoers 白名单已安装
        if !SudoersManager.isInstalled {
            Logger.info("sudoers 未安装，开始引导安装")
            switch SudoersManager.install() {
            case .success:
                Logger.info("sudoers 安装成功")
            case .failure(let error):
                Logger.error("sudoers 安装失败: \(error.localizedDescription)")
                return .failure(error)
            }
        }

        // 设置值：-a 应用到所有电源场景
        // 通过 sudo -n 免密执行（依赖 /etc/sudoers.d/macawake 白名单）
        let disablesleep = enable ? "1" : "0"
        let (exitCode, output) = Self.run("/usr/bin/sudo", args: ["-n", "/usr/bin/pmset", "-a", "disablesleep", disablesleep])
        Logger.info("pmset 执行结果: disablesleep -> \(output) exit=\(exitCode)")
        if exitCode != 0 {
            let detail = "pmset 退出码 \(exitCode): \(output)"
            Logger.error(detail)
            return .failure(NSError(
                domain: "MacAwake",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: String(format: String(localized: "设置未生效：%@。请检查 sudoers 配置。"), output)]
            ))
        }

        // 校验（任何"已开启"状态都以系统回读结果为准）
        let newState = currentState
        let expected: SleepState = enable ? .on : .off
        guard newState == expected else {
            let detail = "设置未生效: 期望=\(expected), 实际=\(newState), pmset输出=\(output)"
            Logger.error(detail)
            return .failure(NSError(
                domain: "MacAwake",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: String(format: String(localized: "设置未生效：%@。请检查 sudoers 配置。"), output)]
            ))
        }
        Logger.info("切换成功: 当前 SleepDisabled = \(newState == .on ? "1" : "0")")
        return .success(())
    }

    /// 立刻让系统睡眠（`pmset sleepnow`，需 root，走 sudoers 白名单）。
    /// 定时到点且用户开启"到点后强制睡眠"时调用：只解除 disablesleep 不会让开盖使用中的
    /// 机器马上睡（那只是回到正常空闲休眠规则），这一点是有意为之的行为差异。
    @discardableResult
    func forceSleepNow() -> Result<Void, Error> {
        Logger.info("执行 pmset sleepnow（强制立即睡眠）")
        let (exitCode, output) = Self.run("/usr/bin/sudo", args: ["-n", "/usr/bin/pmset", "sleepnow"])
        guard exitCode == 0 else {
            Logger.error("sleepnow 失败: exit=\(exitCode) output=\(output)")
            return .failure(NSError(
                domain: "MacAwake",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: String(format: String(localized: "强制睡眠失败：%@"), output)]
            ))
        }
        return .success(())
    }

    /// 电池原始输出（pmset -g batt），供"原始模式"显示
    var batteryRaw: String {
        let output = Self.run("/usr/bin/pmset", args: ["-g", "batt"]).output
        if let line = output.split(separator: "\n").last(where: { $0.contains("%") }) {
            return line.trimmingCharacters(in: .whitespaces)
        }
        if output.contains("AC Power") || output.contains("AC attached") {
            return String(localized: "外接电源")
        }
        return "?"
    }

    /// 电池 / 电源信息（自然语言格式）
    var batteryInfo: String {
        let output = Self.run("/usr/bin/pmset", args: ["-g", "batt"]).output
        guard let raw = output.split(separator: "\n").last(where: { $0.contains("%") })?
            .trimmingCharacters(in: .whitespaces) else {
            // 无电池机型（台式机等）：只显示电源来源
            return (output.contains("AC Power") || output.contains("AC attached"))
                ? String(localized: "外接电源") : "?"
        }
        // 例: "-InternalBattery-0 (id=6684771)  28%; AC attached; not charging; 1:07 remaining"
        let ns = raw as NSString
        var parts: [String] = []

        if let pct = Self.percentPattern.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
            parts.append(String(format: String(localized: "电量%d%%"), Int(ns.substring(with: pct.range(at: 1)))!))
        }

        let onAC = output.contains("AC Power") || output.contains("AC attached")
        switch PowerParsing.chargingState(in: raw) {
        case "charging":
            parts.append(String(localized: "充电中"))
        case "discharging":
            parts.append(String(localized: "放电中"))
        case "charged":
            parts.append(String(localized: "已充满"))
        case "finishing charge":
            parts.append(String(localized: "即将充满"))
        case "not charging":
            // 插电未充电（充电切入前的瞬态/优化充电暂停）：显示"外接电源"，与台式机口径一致；
            // 非插电却报 not charging（电池异常/SMC 误报）时仍如实显示"未充电"（核验 V7）
            if onAC {
                parts.append(String(localized: "外接电源"))
            } else {
                parts.append(String(localized: "未充电"))
            }
        default:
            break
        }

        if let t = Self.timePattern.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
            let hours = Int(ns.substring(with: t.range(at: 1)))!
            let mins = Int(ns.substring(with: t.range(at: 2)))!
            if hours > 0 {
                parts.append(String(format: String(localized: "剩余约%d小时%d分"), hours, mins))
            } else if mins > 0 {
                parts.append(String(format: String(localized: "剩余约%d分钟"), mins))
            }
            // hours == 0 && mins == 0（如已充满 "0:00 remaining"）时不显示"剩余约0分钟"
        }

        return parts.isEmpty ? raw : parts.joined(separator: " ")
    }

    /// 执行外部命令，返回 (退出码, stdout)（不显示终端窗口）。
    /// 静态方法：`PowerStateReader` 的 pmset 回退路径也要用。
    @discardableResult
    static func run(_ path: String, args: [String]) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            Logger.error("run 启动失败: \(path) \(args) -> \(error)")
            return (-1, "")
        }
        // 先读完管道再等退出：若子进程输出超过管道缓冲(64KB)，
        // 先 waitUntilExit 会双方互相等待而死锁
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        Logger.info("run 完成: \(path) exit=\(process.terminationStatus)")

        let out = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, out)
    }
}
