import Foundation

// MARK: - 自动化规则模型（Codable，持久化 + 纯函数求值）

/// 触发器：事件型（合盖/开盖/插电/拔电）或条件型（电量越线）。
/// 电量触发带"仅在合盖时"开关 —— 预置「合盖且电量 < 30% → 强制睡眠」靠它表达。
public enum AutomationTrigger: Codable, Equatable, Sendable {

    case lidClosed
    case lidOpened
    case pluggedIn           // 切到外接电源
    case unplugged           // 切到电池
    /// 电量从高处跌破 pct（越线才触发一次，不会反复刷）
    case batteryBelow(pct: Int, whileLidClosed: Bool)
    /// 电量从低处升破 pct
    case batteryAbove(pct: Int, whileLidClosed: Bool)

    public var requiresLidClosed: Bool {
        if case .batteryBelow(_, let lid) = self { return lid }
        if case .batteryAbove(_, let lid) = self { return lid }
        return false
    }
}

/// 动作块：一条规则 = 1 个触发器 + 顺序执行的 N 个动作。
/// 动作在 Task 里顺序异步执行（等待模块不卡界面）。
public enum AutomationAction: Codable, Equatable, Sendable {

    /// 屏幕亮度调到 0–1（0 = 最低亮度，预置"合盖省电"用 0）
    case setBrightness(level: Double)
    /// 把当前 CPU 占用前 N 的进程钉到小核；stickyUntilLidOpen = 开盖时自动解除
    case pinTopCPU(n: Int, stickyUntilLidOpen: Bool)
    /// 把命令行/名称匹配关键词的进程（当前快照）钉到小核
    case pinKeyword(keyword: String)
    /// 把指定应用（主进程 + 同 bundle 全部子进程）钉到小核
    case pinApp(appName: String)
    /// 解除本应用钉过的所有进程（回到默认调度）
    case unpinAll
    /// 立即熄屏（显示器休眠，免 root；动一下鼠标/键盘即亮）
    case displaySleep
    /// 立即强制睡眠（pmset sleepnow）
    case forceSleep
    /// 优雅退出指定应用（按应用名）
    case quitApp(appName: String)
    /// 等待 N 分钟再执行后续动作
    case wait(minutes: Double)
    /// 开启合盖不休眠（秒数，nil = 不限时）
    case keepAwakeOn(seconds: Int?)
    /// 关闭合盖不休眠
    case keepAwakeOff
    /// 发一条系统通知
    case notify(message: String)
}

public struct AutomationRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var trigger: AutomationTrigger
    public var actions: [AutomationAction]

    public init(id: UUID = UUID(),
                name: String,
                enabled: Bool = true,
                trigger: AutomationTrigger,
                actions: [AutomationAction]) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.trigger = trigger
        self.actions = actions
    }
}

/// 求值器：把"环境事件"翻译成"哪些触发器命中"。纯函数，注入全部状态。
public struct AutomationContext: Sendable {
    /// 本次事件
    public enum Event: Equatable, Sendable {
        case lidChanged(closed: Bool)
        case powerSourceChanged(onAC: Bool)
        /// 周期性电量采样（当前电量在 context.currentBatteryPercent）
        case batteryTick
    }

    public let event: Event
    public let isLidClosed: Bool
    /// 上一次电量采样（越线判断需要"之前在哪边"）
    public let previousBatteryPercent: Int?
    public let currentBatteryPercent: Int

    public init(event: Event,
                isLidClosed: Bool,
                previousBatteryPercent: Int?,
                currentBatteryPercent: Int) {
        self.event = event
        self.isLidClosed = isLidClosed
        self.previousBatteryPercent = previousBatteryPercent
        self.currentBatteryPercent = currentBatteryPercent
    }
}

public enum AutomationEvaluator {

    /// 触发器是否在当前上下文命中
    public static func fires(_ trigger: AutomationTrigger, context: AutomationContext) -> Bool {
        let lidOK = !trigger.requiresLidClosed || context.isLidClosed

        switch trigger {
        case .lidClosed:
            return context.event == .lidChanged(closed: true)
        case .lidOpened:
            return context.event == .lidChanged(closed: false)
        case .pluggedIn:
            return context.event == .powerSourceChanged(onAC: true)
        case .unplugged:
            return context.event == .powerSourceChanged(onAC: false)

        case .batteryBelow(let pct, _):
            guard lidOK,
                  case .batteryTick = context.event,
                  let prev = context.previousBatteryPercent else { return false }
            return prev >= pct && context.currentBatteryPercent < pct

        case .batteryAbove(let pct, _):
            guard lidOK,
                  case .batteryTick = context.event,
                  let prev = context.previousBatteryPercent else { return false }
            return prev <= pct && context.currentBatteryPercent > pct
        }
    }

    /// 命中的启用规则（按数组顺序）
    public static func matchingRules(_ rules: [AutomationRule], context: AutomationContext) -> [AutomationRule] {
        rules.filter { $0.enabled && fires($0.trigger, context: context) }
    }
}

/// 预置规则（首次启动时灌入，用户可改可删）
public enum AutomationPresets {

    public static let all: [AutomationRule] = [
        AutomationRule(
            name: "合盖省电模式",
            trigger: .lidClosed,
            actions: [
                .setBrightness(level: 0),
                .pinTopCPU(n: 5, stickyUntilLidOpen: true),
            ]
        ),
        AutomationRule(
            name: "合盖低电量强制睡眠",
            trigger: .batteryBelow(pct: 30, whileLidClosed: true),
            actions: [
                .notify(message: "电量低于 30%，即将强制睡眠"),
                .forceSleep,
            ]
        ),
        AutomationRule(
            name: "开盖恢复",
            trigger: .lidOpened,
            actions: [
                .unpinAll,
                .setBrightness(level: 0.7),
            ]
        ),
    ]
}
