import Foundation

/// 时长解析与拆解。
/// 放在 Core 里是为了可单测：解析规则（尤其是"什么算非法输入"）必须有测试锁住。
public enum DurationFormat {

    /// 允许的最短时长：1 分钟
    public static let minimum: TimeInterval = 60

    /// 允许的最长时长：24 小时（再长就用"不限时"）
    public static let maximum: TimeInterval = 24 * 60 * 60

    /// 解析用户输入或预设时长的文本。
    ///
    /// 支持：`90`（纯数字 = 分钟）、`90m`、`1h`、`1h30m`、`1.5h`、`1 小时 30 分钟`。
    /// 返回 nil 表示非法、无法解析，或超出 1 分钟 – 24 小时。
    /// 注意 `1h30`（末段缺单位）会被拒绝 —— 宁可报错也不猜。
    public static func parse(_ text: String) -> TimeInterval? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: " ", with: "")
        s = s.replacingOccurrences(of: "\t", with: "")
        s = s.replacingOccurrences(of: ",", with: "")
        s = s.replacingOccurrences(of: "，", with: "")

        // 纯数字 = 分钟
        if let minutes = Double(s) {
            return clamp(minutes * 60)
        }

        let pattern = try! NSRegularExpression(pattern: "([0-9]*\\.?[0-9]+)(小时|时|h|分钟|分|m)")
        let ns = s as NSString
        let matches = pattern.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return nil }

        var consumed = 0
        var total: TimeInterval = 0
        for match in matches {
            // 匹配之间出现空洞（如 "1habc30m"）→ 直接判定非法
            guard match.range.location == consumed else { return nil }
            consumed = match.range.location + match.range.length
            guard let value = Double(ns.substring(with: match.range(at: 1))) else { return nil }
            let unit = ns.substring(with: match.range(at: 2))
            total += (unit == "h" || unit == "小时" || unit == "时") ? value * 3600 : value * 60
        }
        // 末尾还有没被消费的字符 → 非法
        guard consumed == ns.length else { return nil }

        return clamp(total)
    }

    /// 把秒数拆成 小时 + 分钟（向下取整，用于"设定时长"的描述，如 5400 → 1 小时 30 分）
    public static func decompose(_ seconds: TimeInterval) -> (hours: Int, minutes: Int) {
        let total = max(0, Int(seconds.rounded()))
        return (total / 3600, (total % 3600) / 60)
    }

    /// 剩余时间的拆解：向上取整到分钟，避免出现"剩余 0 分钟"。
    public static func decomposeRemaining(_ seconds: TimeInterval) -> (hours: Int, minutes: Int) {
        let totalMinutes = max(1, Int(ceil(max(0, seconds) / 60)))
        return (totalMinutes / 60, totalMinutes % 60)
    }

    private static func clamp(_ seconds: TimeInterval) -> TimeInterval? {
        guard seconds.isFinite, seconds >= minimum, seconds <= maximum else { return nil }
        return seconds
    }
}
