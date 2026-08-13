import Foundation

/// 合盖休眠状态（对应系统设置 SleepDisabled）
public enum SleepState: Equatable {
    case on      // 合盖不休眠（SleepDisabled = 1）
    case off     // 合盖休眠（默认，SleepDisabled = 0）
    case unknown
}

/// 纯解析函数：把 pmset 文本输出转成结构化数据。
/// 与进程/IOKit 隔离，便于用单元测试锁定当前解析行为。
public enum PowerParsing {

    /// 解析 `pmset -g` 输出中的 SleepDisabled 值（可能用多个空格/制表符分隔）。
    /// 例: "SleepDisabled\t\t1" 或 "SleepDisabled 0"
    public static func parseSleepDisabled(_ output: String) -> SleepState {
        if let line = output.split(separator: "\n").first(where: { $0.contains("SleepDisabled") }) {
            let components = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if let idx = components.firstIndex(where: { $0 == "SleepDisabled" }),
               idx + 1 < components.count {
                switch components[idx + 1] {
                case "1": return .on
                case "0": return .off
                default: return .unknown
                }
            }
        }
        return .unknown
    }

    /// 从电池行文本提取充放电状态关键词；无匹配返回 nil。
    /// 注意 "not charging"（插电但未充电）必须先于 "charging" 匹配，
    /// 否则会被子串匹配误判成"充电中"。
    public static func chargingState(in raw: String) -> String? {
        let pattern = try! NSRegularExpression(pattern: "(not charging|charging|discharging|charged|finishing charge)")
        let ns = raw as NSString
        guard let m = pattern.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
}
