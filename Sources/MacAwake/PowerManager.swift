import Foundation

enum SleepState {
    case on      // 合盖不休眠（SleepDisabled = 1）
    case off     // 合盖休眠（默认，SleepDisabled = 0）
    case unknown
}

/// 电源管理：读取/修改合盖休眠状态。
/// 底层使用公开的 pmset 命令；修改需要 root（通过 sudoers 白名单免密）。
final class PowerManager {

    /// 读取当前 SleepDisabled 状态（pmset -g 普通用户可读）
    var currentState: SleepState {
        let output = run("/usr/bin/pmset", args: ["-g"])
        // 匹配 "SleepDisabled" 后的值（可能用多个空格/制表符分隔）
        if let line = output.split(separator: "\n").first(where: { $0.contains("SleepDisabled") }) {
            // 例: "SleepDisabled\t\t1" 或 "SleepDisabled 1"
            let components = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if let idx = components.firstIndex(where: { $0 == "SleepDisabled" }),
               idx + 1 < components.count {
                let value = components[idx + 1]
                if value == "1" { return .on }
                if value == "0" { return .off }
            }
        }
        return .unknown
    }

    /// 设置合盖不休眠。enable = true → 禁用合盖休眠；false → 恢复。
    /// 通过 sudoers 白名单免密执行 pmset。
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

        // 设置值：-a 应用到所有电源场景；sleep 0 配合禁用
        // 通过 sudo -n 免密执行（依赖 /etc/sudoers.d/macawake 白名单）
        let disablesleep = enable ? "1" : "0"
        let r1 = run("/usr/bin/sudo", args: ["-n", "/usr/bin/pmset", "-a", "disablesleep", disablesleep])
        let r2 = run("/usr/bin/sudo", args: ["-n", "/usr/bin/pmset", "-a", "sleep", enable ? "0" : "10"])
        Logger.info("pmset 执行结果: disablesleep -> \(r1) | sleep -> \(r2)")

        // 校验
        let newState = currentState
        let expected: SleepState = enable ? .on : .off
        guard newState == expected else {
            let detail = "设置未生效: 期望=\(expected), 实际=\(newState), pmset输出=\(r1) \(r2)"
            Logger.error(detail)
            return .failure(NSError(
                domain: "MacAwake",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: String(format: String(localized: "设置未生效：%@。请检查 sudoers 配置。"), "\(r1) \(r2)")]
            ))
        }
        Logger.info("切换成功: 当前 SleepDisabled = \(newState == .on ? "1" : "0")")
        return .success(())
    }

    /// 电池原始输出（pmset -g batt），供"原始模式"显示
    var batteryRaw: String {
        let output = run("/usr/bin/pmset", args: ["-g", "batt"])
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
        let raw = batteryRaw
        // 正则解析: "-InternalBattery-0 (id=6684771)  28%; discharging; 1:07 remaining present: true"
        let percentPattern = try! NSRegularExpression(pattern: "(\\d+)%")
        let timePattern = try! NSRegularExpression(pattern: "(\\d+):(\\d+) remaining")
        let chargingPattern = try! NSRegularExpression(pattern: "(charging|discharging|charged|finishing charge)")
        let ns = raw as NSString

        var parts: [String] = []

        if let pct = percentPattern.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
            parts.append(String(format: String(localized: "电量%d%%"), Int(ns.substring(with: pct.range(at: 1)))!))
        }

        if raw.contains("AC Power") || raw.contains("AC attached") {
            parts.append(String(localized: "外接电源"))
        }

        if let m = chargingPattern.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
            switch ns.substring(with: m.range(at: 1)) {
            case "charging":
                parts.append(String(localized: "充电中"))
            case "discharging":
                parts.append(String(localized: "放电中"))
            case "charged":
                parts.append(String(localized: "已充满"))
            case "finishing charge":
                parts.append(String(localized: "即将充满"))
            default:
                break
            }
        }

        if let t = timePattern.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) {
            let hours = Int(ns.substring(with: t.range(at: 1)))!
            let mins = Int(ns.substring(with: t.range(at: 2)))!
            if hours > 0 {
                parts.append(String(format: String(localized: "剩余约%d小时%d分"), hours, mins))
            } else {
                parts.append(String(format: String(localized: "剩余约%d分钟"), mins))
            }
        }

        return parts.isEmpty ? raw : parts.joined(separator: " ")
    }

    /// 执行外部命令，返回 stdout（不显示终端窗口）
    @discardableResult
    private func run(_ path: String, args: [String]) -> String {
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
            return ""
        }
        process.waitUntilExit()
        Logger.info("run 完成: \(path) exit=\(process.terminationStatus)")

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return out
    }
}
