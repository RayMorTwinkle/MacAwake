import Foundation

// MARK: - 能效调度核心决策（纯函数，可单测）

/// 自适应扫描间隔：发现新进程要钉 → 快扫；一直没新目标 → 慢慢退避。
/// 移植自 EfficiencyTool 的 bash 阶梯逻辑，简化为确定性规则：
/// 命中 → 区间减半（下限 5s）；未命中 → +5s（上限 120s）。
public enum ScanPlanner {

    public static let minInterval: TimeInterval = 5
    public static let maxInterval: TimeInterval = 120
    public static let initialInterval: TimeInterval = 15

    /// 下一次扫描间隔
    /// - Parameters:
    ///   - current: 当前间隔
    ///   - newPins: 本次扫描新钉住的目标数（0 = 空转）
    public static func nextInterval(current: TimeInterval, newPins: Int) -> TimeInterval {
        if newPins > 0 {
            return max(minInterval, current / 2)
        }
        return min(maxInterval, current + 5)
    }
}

/// 进程匹配规则：自定义关键词（按子串/正则）+ 可选内置默认规则。
/// EfficiencyTool 默认规则 = `Renderer|bilibili|wine`（Chromium/Electron 渲染进程为主）。
public struct CoreRules: Equatable, Sendable {

    /// 自定义关键词（按 `|` 拼成正则交给调用方匹配）
    public var customPatterns: [String]

    /// 是否叠加内置默认规则
    public var useDefaultRules: Bool

    public init(customPatterns: [String] = [], useDefaultRules: Bool = true) {
        self.customPatterns = customPatterns
        self.useDefaultRules = useDefaultRules
    }

    public static let defaultPattern = "Renderer|bilibili|wine"

    /// 合成后的正则表达式；空串 = 不匹配任何进程
    public var combinedRegex: String {
        var parts: [String] = []
        if useDefaultRules { parts.append(Self.defaultPattern) }
        parts.append(contentsOf: customPatterns.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        return parts.joined(separator: "|")
    }

    /// 判断目标字符串（进程路径/名称）是否命中
    public func matches(_ target: String) -> Bool {
        let pattern = combinedRegex
        guard !pattern.isEmpty else { return false }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            // 正则非法时退化为逐个子串匹配，避免一条坏规则瘫痪整个引擎
            return customPatterns.contains { target.localizedCaseInsensitiveContains($0) }
        }
        let ns = target as NSString
        return regex.firstMatch(in: target, range: NSRange(location: 0, length: ns.length)) != nil
    }
}

/// 平衡模式决策：钉在小核的进程 CPU 飙高 → 放回大核；降下来（带滞回）→ 再钉回去。
/// 纯函数：调用方注入全部事实，便于用单元测试锁死行为。
public enum BalancePlanner {

    public enum Decision: Equatable, Sendable {
        case keep
        case toPerformance
        case toEfficiency
    }

    /// - Parameters:
    ///   - cpuPercent: 该进程当前 CPU 占用（%，可 > 100，多核）
    ///   - isOnEfficiency: 当前是否已钉在小核
    ///   - threshold: 放行阈值（%），默认 100
    ///   - systemGatePercent: 系统整体 CPU 门槛（%）；低于它不动任何东西（省电优先）
    ///   - systemCpuPercent: 系统当前整体 CPU（%）
    public static func decide(cpuPercent: Double,
                              isOnEfficiency: Bool,
                              threshold: Double = 100,
                              systemGatePercent: Double,
                              systemCpuPercent: Double) -> Decision {
        // 系统不忙就不折腾：小核跑得动的负载没必要搬来搬去
        guard systemCpuPercent > systemGatePercent else { return .keep }

        if isOnEfficiency {
            if cpuPercent > threshold { return .toPerformance }
            return .keep
        }
        // 已在大核的进程：降到阈值的 70%（滞回）才钉回小核，避免在阈值附近抖动
        if cpuPercent < threshold * 0.7 { return .toEfficiency }
        return .keep
    }
}
