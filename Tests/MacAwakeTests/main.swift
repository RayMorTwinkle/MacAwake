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

print("")
if failed == 0 {
    print("全部通过 \(total)/\(total)")
    exit(0)
} else {
    print("失败 \(failed)/\(total)")
    exit(1)
}
