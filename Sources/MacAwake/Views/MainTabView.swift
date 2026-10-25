import SwiftUI
import MacAwakeCore

/// GUI 顶层模型：聚合既有引擎 + 1 秒 UI 心跳（倒计时/状态刷新）。
/// 引擎本身不因此改动 —— 视图按需 @ObservedObject 各自订阅。
@MainActor
final class AppModel: ObservableObject {

    let controller: SessionController
    let efficiency: EfficiencyEngine
    let automation: AutomationEngine
    let stats: StatsRecorder

    /// 1 秒心跳：驱动剩余时间倒计时、电量刷新等
    @Published private(set) var now = Date()
    @Published private(set) var power = PowerSnapshot.onACDesktop

    private var timer: Timer?

    init(controller: SessionController,
         efficiency: EfficiencyEngine,
         automation: AutomationEngine,
         stats: StatsRecorder) {
        self.controller = controller
        self.efficiency = efficiency
        self.automation = automation
        self.stats = stats
    }

    func startHeartbeat() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopHeartbeat() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        now = Date()
        power = PowerSnapshotService.read(now: now)
    }

    // MARK: - 电源页派生状态

    var isEffectivelyOn: Bool {
        controller.session != nil || controller.systemState == .on
    }

    var remainingSeconds: TimeInterval? {
        controller.session?.remaining(now: now)
    }
}

// MARK: - 主窗口 TabView

struct MainTabView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            PowerTabView(model: model)
                .tabItem { Label("合盖不休眠", systemImage: "moon.zzz.fill") }
            EfficiencyTabView(model: model)
                .tabItem { Label("能效调度", systemImage: "cpu") }
            AutomationTabView(model: model)
                .tabItem { Label("自动化", systemImage: "puzzlepiece.fill") }
            StatsTabView(model: model)
                .tabItem { Label("统计", systemImage: "chart.bar.xaxis") }
        }
        .padding()
        .frame(minWidth: 620, minHeight: 520)
    }
}

// MARK: - Tab 1：合盖不休眠

private struct PowerTabView: View {
    @ObservedObject var model: AppModel

    @State private var customText = ""
    @State private var loginToggleFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                if PowerManager.isDevBuild {
                    Label("DEV 构建：pmset 写操作为干跑，不影响正式版会话", systemImage: "testtube.2")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                }

                // 状态大卡片
                HStack(spacing: 20) {
                    Image(systemName: model.isEffectivelyOn ? "moon.fill" : "moon")
                        .font(.system(size: 44))
                        .foregroundStyle(model.isEffectivelyOn ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.isEffectivelyOn ? "合盖不休眠 已开启" : "合盖休眠（默认）")
                            .font(.title2.bold())
                        if let remain = model.remainingSeconds {
                            Text("剩余 \(formatDuration(remain))")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else if model.isEffectivelyOn {
                            Text("不限时")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                        if model.controller.driftRepairCount > 0 {
                            Text("⚠️ 已被外部修改 \(model.controller.driftRepairCount) 次，均已自动恢复")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    Button(model.isEffectivelyOn ? "关闭" : "开启") {
                        if model.isEffectivelyOn {
                            model.controller.turnOff()
                        } else {
                            model.controller.turnOn(duration: nil)
                        }
                    }
                    .controlSize(.large)
                    .keyboardShortcut(.space, modifiers: [])
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))

                // 定时恢复休眠
                GroupBox("定时恢复休眠") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("预设", selection: Binding<Int?>(
                            get: { nil },
                            set: { seconds in
                                guard let seconds else { return }
                                model.controller.turnOn(duration: Double(seconds))
                            })) {
                            Text("30 分钟").tag(Optional(Int(30 * 60)))
                            Text("1 小时").tag(Optional(Int(60 * 60)))
                            Text("2 小时").tag(Optional(Int(2 * 60 * 60)))
                            Text("4 小时").tag(Optional(Int(4 * 60 * 60)))
                            Text("不限时").tag(Optional(-1))
                        }
                        .pickerStyle(.segmented)

                        HStack {
                            TextField("自定义（如 45m / 1h30m）", text: $customText)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(startCustom)
                            Button("开始", action: startCustom)
                            if model.controller.session?.isTimed == true {
                                Button("延长 30 分钟") {
                                    model.controller.extend(by: 30 * 60)
                                }
                            }
                        }

                        Toggle("到点后强制睡眠（而不是等系统空闲）", isOn: Binding(
                            get: { model.controller.forceSleepOnExpiry },
                            set: { model.controller.forceSleepOnExpiry = $0 }
                        ))
                    }
                    .padding(.vertical, 4)
                }

                // 电源状态
                GroupBox("电源") {
                    HStack {
                        Image(systemName: model.power.isOnAC ? "plug.fill" : "battery.100")
                            .foregroundStyle(model.power.isOnAC ? .green : .orange)
                        Text(batteryLine)
                        Spacer()
                        if let watts = model.power.watts, watts > 0 {
                            Text(String(format: "%.1f W", model.power.isCharging ? watts : -watts))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // 启动项
                GroupBox("通用") {
                    Toggle("开机启动", isOn: Binding(
                        get: { SMAppServiceUtil.isEnabled },
                        set: { _ in
                            do { try SMAppServiceUtil.toggle() } catch { loginToggleFailed = true }
                        }
                    ))
                    .padding(.vertical, 4)
                }

                if loginToggleFailed {
                    Label("开机启动切换失败，请重试", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var batteryLine: String {
        var parts: [String] = []
        if let pct = model.power.capacityPercent { parts.append("电量 \(pct)%") }
        parts.append(model.power.isOnAC ? "外接电源" : "电池")
        if model.power.isCharging { parts.append("充电中") }
        return parts.joined(separator: " · ")
    }

    private func startCustom() {
        guard let seconds = DurationFormat.parse(customText) else {
            NSSound.beep()
            return
        }
        model.controller.turnOn(duration: seconds)
        customText = ""
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let (h, m) = DurationFormat.decomposeRemaining(seconds)
        return h > 0 ? "\(h) 小时 \(m) 分" : "\(m) 分钟"
    }
}
