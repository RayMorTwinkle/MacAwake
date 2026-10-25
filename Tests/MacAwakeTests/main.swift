import Foundation
import MacAwakeCore

// 极简断言 harness：CLT 环境无 XCTest，核心解析是纯函数，自建够用。
var total = 0
var failed = 0

@MainActor
func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    total += 1
    if condition {
        print("✅ \(name)")
    } else {
        failed += 1
        print("❌ \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }
}

// MARK: parseSleepDisabled

check("tab 分隔 SleepDisabled=1 → on",
      PowerParsing.parseSleepDisabled("SleepDisabled\t\t1") == .on)
check("空格分隔 SleepDisabled=0 → off",
      PowerParsing.parseSleepDisabled(" SleepDisabled 0") == .off)
check("多行输出取 SleepDisabled 所在行",
      PowerParsing.parseSleepDisabled("displaysleep 5\nSleepDisabled 1\nsleep 10") == .on)
check("无 SleepDisabled → unknown",
      PowerParsing.parseSleepDisabled("sleep 10") == .unknown)
check("非法值 → unknown",
      PowerParsing.parseSleepDisabled("SleepDisabled 2") == .unknown)
check("空输出 → unknown",
      PowerParsing.parseSleepDisabled("") == .unknown)

// MARK: chargingState

check("not charging 不误判为 charging",
      PowerParsing.chargingState(in: "-InternalBattery-0 (id=1) 100%; not charging; 0:00 remaining") == "not charging")
check("charging 正常识别",
      PowerParsing.chargingState(in: "42%; charging; 2:46 remaining") == "charging")
check("discharging 正常识别",
      PowerParsing.chargingState(in: "58%; discharging; 1:07 remaining") == "discharging")
check("charged 正常识别",
      PowerParsing.chargingState(in: "100%; charged; 0:00 remaining") == "charged")
check("finishing charge 正常识别",
      PowerParsing.chargingState(in: "95%; finishing charge; 0:20 remaining") == "finishing charge")
check("无状态词 → nil",
      PowerParsing.chargingState(in: "42%; 2:46 remaining") == nil)

// MARK: KeepAwakeSession

let now = Date(timeIntervalSince1970: 1_000_000)
let timed = KeepAwakeSession(startedAt: now, deadline: now.addingTimeInterval(1800))

check("定时会话剩余 1800 秒", timed.remaining(now: now) == 1800)
check("定时会话未到期", !timed.isExpired(now: now))
check("定时会话到期判定（等号也算到期）", timed.isExpired(now: now.addingTimeInterval(1800)))
check("不限时会话剩余为 nil", KeepAwakeSession(startedAt: now).remaining(now: now) == nil)
check("不限时会话永不到期",
      !KeepAwakeSession(startedAt: now).isExpired(now: now.addingTimeInterval(86400 * 365)))

// MARK: SessionEngine.plan（周期性收敛）

check("无会话 → 期望关闭，且不算会话结束",
      SessionEngine.plan(session: nil, now: now, forceSleepOnExpiry: true)
      == SessionPlan(desiredSleepDisabled: false))
check("未到期的定时会话 → 期望开启",
      SessionEngine.plan(session: timed, now: now, forceSleepOnExpiry: true)
      == SessionPlan(desiredSleepDisabled: true))
check("到期 + 开启强制睡眠 → 结束会话并强制睡眠",
      SessionEngine.plan(session: timed, now: now.addingTimeInterval(1801), forceSleepOnExpiry: true)
      == SessionPlan(desiredSleepDisabled: false, endsSession: true, forceSleep: true, reason: .timerExpired))
check("到期 + 关闭强制睡眠 → 只解除",
      SessionEngine.plan(session: timed, now: now.addingTimeInterval(1801), forceSleepOnExpiry: false)
      == SessionPlan(desiredSleepDisabled: false, endsSession: true, forceSleep: false, reason: .timerExpired))
check("不限时会话不受 forceSleep 影响",
      SessionEngine.plan(session: KeepAwakeSession(startedAt: now),
                         now: now.addingTimeInterval(99999),
                         forceSleepOnExpiry: true)
      == SessionPlan(desiredSleepDisabled: true))

// MARK: SessionEngine.adopt（启动接管）

check("启动接管：系统关闭 → 结束会话且无原因（不提示用户）",
      SessionEngine.adopt(systemOn: false, persistedDeadline: nil, now: now)
      == SessionPlan(desiredSleepDisabled: false, endsSession: true))
check("启动接管：系统开启 + 无到期时间 → 不限时沿用",
      SessionEngine.adopt(systemOn: true, persistedDeadline: nil, now: now)
      == SessionPlan(desiredSleepDisabled: true))
check("启动接管：系统开启 + 到期时间未到 → 沿用",
      SessionEngine.adopt(systemOn: true, persistedDeadline: now.addingTimeInterval(600), now: now)
      == SessionPlan(desiredSleepDisabled: true))
check("启动接管：系统开启 + 到期时间已过 → 立刻释放（原因 missed）",
      SessionEngine.adopt(systemOn: true, persistedDeadline: now.addingTimeInterval(-1), now: now)
      == SessionPlan(desiredSleepDisabled: false, endsSession: true, reason: .missedDeadline))
check("启动接管：系统读取失败（unknown）按关闭处理，不会误开",
      SessionEngine.adopt(systemOn: false, persistedDeadline: now.addingTimeInterval(600), now: now)
      == SessionPlan(desiredSleepDisabled: false, endsSession: true))

// MARK: 漂移判定（外部改写自愈的核心条件）

check("期望 1 / 实际 1 → 已符合", SessionEngine.isSatisfied(true, actual: .on))
check("期望 1 / 实际 0 → 判定为漂移，需要重新施加", !SessionEngine.isSatisfied(true, actual: .off))
check("期望 0 / 实际 0 → 已符合", SessionEngine.isSatisfied(false, actual: .off))
check("期望 0 / 实际 1 → 需要释放", !SessionEngine.isSatisfied(false, actual: .on))
check("读不到状态 → 一律视为不符合（触发一次写+回读校验）",
      !SessionEngine.isSatisfied(true, actual: .unknown))

// MARK: RebootDetector

check("首次运行不算重启", !RebootDetector.hasRebooted(storedBootTime: nil, currentBootTime: 1000))
check("开机时间相同 → 未重启", !RebootDetector.hasRebooted(storedBootTime: 1000, currentBootTime: 1000))
check("开机时间差 < 1s 视为抖动", !RebootDetector.hasRebooted(storedBootTime: 1000, currentBootTime: 1000.5))
check("开机时间不同 → 重启", RebootDetector.hasRebooted(storedBootTime: 1000, currentBootTime: 2000))
check("开机时间为 0（读取失败）→ 不误判为重启",
      !RebootDetector.hasRebooted(storedBootTime: 0, currentBootTime: 2000))

// MARK: DurationFormat.parse

check("纯数字 = 分钟", DurationFormat.parse("90") == 5400)
check("30m", DurationFormat.parse("30m") == 1800)
check("1h", DurationFormat.parse("1h") == 3600)
check("1h30m", DurationFormat.parse("1h30m") == 5400)
check("1.5h", DurationFormat.parse("1.5h") == 5400)
check("中文单位", DurationFormat.parse("1 小时 30 分钟") == 5400)
check("大写单位", DurationFormat.parse("2H") == 7200)
check("首尾空白忽略", DurationFormat.parse("  45m  ") == 2700)
check("下限：1 分钟合法", DurationFormat.parse("1") == 60)
check("上限：24 小时合法", DurationFormat.parse("24h") == 86400)
check("低于下限（0）→ nil", DurationFormat.parse("0") == nil)
check("低于下限（30 秒）→ nil", DurationFormat.parse("0.5") == nil)
check("超过上限（25h）→ nil", DurationFormat.parse("25h") == nil)
check("空输入 → nil", DurationFormat.parse("   ") == nil)
check("无法解析 → nil", DurationFormat.parse("abc") == nil)
check("末尾缺单位 → nil", DurationFormat.parse("1h30") == nil)
check("中间夹字符 → nil", DurationFormat.parse("1habc30m") == nil)
check("纯单位无数字 → nil", DurationFormat.parse("h") == nil)
check("负数 → nil", DurationFormat.parse("-30") == nil)

// MARK: DurationFormat 拆解

check("5400 秒 = 1 小时 30 分", DurationFormat.decompose(5400) == (1, 30))
check("剩余 61 秒向上取整为 2 分钟", DurationFormat.decomposeRemaining(61) == (0, 2))
check("剩余不足 1 分钟也显示 1 分钟", DurationFormat.decomposeRemaining(10) == (0, 1))
check("剩余 3600 秒 = 1 小时 0 分", DurationFormat.decomposeRemaining(3600) == (1, 0))
check("剩余 5400 秒 = 1 小时 30 分", DurationFormat.decomposeRemaining(5400) == (1, 30))

// MARK: ScanPlanner 自适应间隔

check("空转 +5s", ScanPlanner.nextInterval(current: 20, newPins: 0) == 25)
check("空转封顶 120s", ScanPlanner.nextInterval(current: 118, newPins: 0) == 120)
check("命中减半", ScanPlanner.nextInterval(current: 20, newPins: 3) == 10)
check("命中下限 5s", ScanPlanner.nextInterval(current: 8, newPins: 1) == 5)
check("初始间隔 15s", ScanPlanner.initialInterval == 15)

// MARK: CoreRules 匹配

let rules = CoreRules(customPatterns: ["RayBlog"], useDefaultRules: true)
check("默认规则命中 Renderer", rules.matches("/Applications/Chromium.app/Contents/Frameworks/Renderer") == true)
check("自定义关键词命中", rules.matches("/Users/ray/dev/RayBlog/worker") == true)
check("不相关路径不命中", rules.matches("/System/Library/CoreServices/Finder") == false)
check("大小写不敏感", rules.matches("/opt/bilibili-helper") == true)
let noDefault = CoreRules(customPatterns: ["RayBlog"], useDefaultRules: false)
check("关默认规则后只剩自定义", noDefault.matches("Renderer") == false && noDefault.matches("RayBlog") == true)
let emptyRules = CoreRules(customPatterns: [], useDefaultRules: false)
check("无规则不匹配任何", emptyRules.matches("anything") == false)

// MARK: BalancePlanner 平衡决策

check("小核进程 CPU 超阈值 → 大核",
      BalancePlanner.decide(cpuPercent: 150, isOnEfficiency: true,
                            threshold: 100, systemGatePercent: 20, systemCpuPercent: 50) == .toPerformance)
check("小核进程 CPU 不高 → 保持",
      BalancePlanner.decide(cpuPercent: 30, isOnEfficiency: true,
                            threshold: 100, systemGatePercent: 20, systemCpuPercent: 50) == .keep)
check("系统整体不忙 → 不动",
      BalancePlanner.decide(cpuPercent: 150, isOnEfficiency: true,
                            threshold: 100, systemGatePercent: 20, systemCpuPercent: 10) == .keep)
check("大核进程 CPU 降回阈值 70% 以下 → 钉回小核",
      BalancePlanner.decide(cpuPercent: 60, isOnEfficiency: false,
                            threshold: 100, systemGatePercent: 20, systemCpuPercent: 50) == .toEfficiency)
check("大核进程 CPU 在滞回区内 → 保持",
      BalancePlanner.decide(cpuPercent: 85, isOnEfficiency: false,
                            threshold: 100, systemGatePercent: 20, systemCpuPercent: 50) == .keep)

// MARK: AutomationEvaluator 触发

func ctx(_ e: AutomationContext.Event, lid: Bool = false, prev: Int? = nil, now: Int = 100) -> AutomationContext {
    AutomationContext(event: e, isLidClosed: lid, previousBatteryPercent: prev, currentBatteryPercent: now)
}

check("合盖事件命中 lidClosed",
      AutomationEvaluator.fires(.lidClosed, context: ctx(.lidChanged(closed: true))))
check("开盖事件不命中 lidClosed",
      !AutomationEvaluator.fires(.lidClosed, context: ctx(.lidChanged(closed: false))))
check("开盖事件命中 lidOpened",
      AutomationEvaluator.fires(.lidOpened, context: ctx(.lidChanged(closed: false))))
check("插电命中 pluggedIn",
      AutomationEvaluator.fires(.pluggedIn, context: ctx(.powerSourceChanged(onAC: true))))
check("拔电不命中 pluggedIn",
      !AutomationEvaluator.fires(.pluggedIn, context: ctx(.powerSourceChanged(onAC: false))))
check("电量 40→29 跌破 30 命中",
      AutomationEvaluator.fires(.batteryBelow(pct: 30, whileLidClosed: false),
                                context: ctx(.batteryTick, prev: 40, now: 29)))
check("电量 25→20 已在线下不重复触发",
      !AutomationEvaluator.fires(.batteryBelow(pct: 30, whileLidClosed: false),
                                 context: ctx(.batteryTick, prev: 25, now: 20)))
check("电量越线但盖子开着不触发（要求合盖）",
      !AutomationEvaluator.fires(.batteryBelow(pct: 30, whileLidClosed: true),
                                 context: ctx(.batteryTick, lid: false, prev: 40, now: 29)))
check("电量越线且合盖 → 触发",
      AutomationEvaluator.fires(.batteryBelow(pct: 30, whileLidClosed: true),
                                context: ctx(.batteryTick, lid: true, prev: 40, now: 29)))
check("电量 20→31 升破 30 命中 batteryAbove",
      AutomationEvaluator.fires(.batteryAbove(pct: 30, whileLidClosed: false),
                                context: ctx(.batteryTick, prev: 20, now: 31)))

let sampleRules = [
    AutomationRule(name: "禁用", enabled: false, trigger: .lidClosed, actions: [.forceSleep]),
    AutomationRule(name: "启用", enabled: true, trigger: .lidClosed, actions: [.unpinAll]),
    AutomationRule(name: "不相关", enabled: true, trigger: .lidOpened, actions: []),
]
check("matchingRules 只返回启用且命中的",
      AutomationEvaluator.matchingRules(sampleRules, context: ctx(.lidChanged(closed: true))).map(\.name) == ["启用"])

check("预置规则可解码往返",
      {
          let data = try! JSONEncoder().encode(AutomationPresets.all)
          let back = try! JSONDecoder().decode([AutomationRule].self, from: data)
          return back == AutomationPresets.all
      }())

// MARK: LidEpisode / StatsMath 统计

let base = Date(timeIntervalSince1970: 1_700_000_000)
let e1 = LidEpisode(closedAt: base,
                    endedAt: base.addingTimeInterval(3600),
                    endKind: .slept,
                    batteryAtClose: 80, batteryAtEnd: 70,
                    averageWatts: 8)
// 1 小时掉 10% → 10 %/h
let e2 = LidEpisode(closedAt: base.addingTimeInterval(7200),
                    endedAt: base.addingTimeInterval(7200 + 1800),
                    endKind: .slept,
                    batteryAtClose: 65, batteryAtEnd: 60,
                    averageWatts: 10)
// 0.5 小时掉 5% → 10 %/h
let summary = StatsMath.summarize([e1, e2])
check("合盖总时长 = 1.5h", summary.totalLidSeconds == 5400)
check("睡着合盖时长 = 1.5h", summary.sleptLidSeconds == 5400)
check("平均掉电速度 = 10 %/h", abs(summary.avgDrainPerHour! - 10) < 0.001)
check("平均功率 = 9W", abs(summary.avgWatts! - 9) < 0.001)
check("平均合盖→入睡 = 45 分钟", summary.avgCloseToSleepSeconds == 2700)

let openEpisode = LidEpisode(closedAt: base, batteryAtClose: nil)
check("未结束事件用当前时间算时长", openEpisode.duration(now: base.addingTimeInterval(120)) == 120)
check("无电量读数不出掉电速度", openEpisode.drainPerHour(now: base.addingTimeInterval(120)) == nil)
check("事件数含未结束", StatsMath.summarize([openEpisode]).episodeCount == 1)

check("StatsStore 日 key 格式", StatsStore.dayKey(for: base).count == 10)

print("")
if failed == 0 {
    print("全部通过 \(total)/\(total)")
    exit(0)
} else {
    print("失败 \(failed)/\(total)")
    exit(1)
}
