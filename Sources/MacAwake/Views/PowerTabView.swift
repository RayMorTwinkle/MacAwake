import SwiftUI
import MacAwakeCore

/// 「合盖不休眠」页：hero 状态卡 + 定时 + 电源信息
struct PowerTabView: View {
    @ObservedObject var model: AppModel

    @State private var customText = ""
    @State private var preset: Int?
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            if PowerManager.isDevBuild {
                Label("DEV 构建：电源写操作为干跑，不会影响正式版会话", systemImage: "testtube.2")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }

            heroCard
            timerCard
            infoCards
            generalCard

            if let loginError {
                Label(loginError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: Hero

    private var heroCard: some View {
        let on = model.isEffectivelyOn
        return HStack(spacing: 18) {
            Image(systemName: on ? "moon.fill" : "moon")
                .font(.system(size: 42))
                .foregroundStyle(on ? AnyShapeStyle(Color.indigo.gradient) : AnyShapeStyle(Color.secondary))
                .frame(width: 76, height: 76)
                .background(on ? Color.indigo.opacity(0.12) : Color.secondary.opacity(0.08),
                            in: Circle())

            VStack(alignment: .leading, spacing: 7) {
                Text(on ? "合盖不休眠" : "合盖正常休眠")
                    .font(.system(.largeTitle, design: .rounded).bold())
                if let remain = model.remainingSeconds {
                    // 剩余时间是 hero 卡的动态主角，给大号等宽数字
                    Text("剩余 \(formatDuration(remain))")
                        .font(.system(.title, design: .rounded).bold())
                        .monospacedDigit()
                        .foregroundStyle(.indigo)
                }
                HStack(spacing: 8) {
                    if on && model.remainingSeconds == nil {
                        Chip(text: "不限时", color: .indigo)
                    } else if !on {
                        Chip(text: "系统默认", color: .secondary)
                    }
                    if model.controller.driftRepairCount > 0 {
                        Chip(text: "已被外部修改 \(model.controller.driftRepairCount) 次 · 均已自动恢复", color: .orange)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .minimumScaleFactor(0.8)
                    }
                }
            }

            Spacer()

            Button {
                on ? model.controller.turnOff() : model.controller.turnOn(duration: nil)
            } label: {
                Text(on ? "关闭" : "开启")
                    .font(.headline)
                    .frame(minWidth: 76)
            }
            .controlSize(.large)
            .tint(on ? .red : .indigo)
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: on ? Color.indigo.opacity(0.12) : Color.black.opacity(0.05), radius: 10, y: 3)
    }

    // MARK: 定时

    private var timerCard: some View {
        Card(title: "定时恢复休眠", icon: "timer") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("预设", selection: $preset) {
                    Text("30 分钟").tag(Int?(30 * 60))
                    Text("1 小时").tag(Int?(60 * 60))
                    Text("2 小时").tag(Int?(2 * 60 * 60))
                    Text("4 小时").tag(Int?(4 * 60 * 60))
                    Text("不限时").tag(Int?(-1))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: preset) { newValue in
                    guard let seconds = newValue else { return }
                    model.controller.turnOn(duration: seconds == -1 ? nil : Double(seconds))
                }

                HStack(spacing: 10) {
                    TextField("自定义时长（如 45m、1h30m、90）", text: $customText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(startCustom)
                    Button("开始", action: startCustom)
                        .controlSize(.regular)
                    if model.controller.session?.isTimed == true {
                        Button("延长 30 分钟") { model.controller.extend(by: 30 * 60) }
                    }
                    Spacer()
                }

                Toggle(isOn: Binding(
                    get: { model.controller.forceSleepOnExpiry },
                    set: { model.controller.forceSleepOnExpiry = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("到点后强制睡眠")
                        Text("开启时到点立刻入睡；关闭则只恢复休眠设置，等系统空闲自然睡")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: 通用

    private var generalCard: some View {
        Card(title: "通用", icon: "gearshape") {
            Toggle("开机启动", isOn: Binding(
                get: { SMAppServiceUtil.isEnabled },
                set: { _ in
                    do {
                        try SMAppServiceUtil.toggle()
                        loginError = nil
                    } catch {
                        loginError = "开机启动切换失败：\(error.localizedDescription)"
                    }
                }
            ))
        }
    }

    // MARK: 信息

    private var infoCards: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatCard(title: "电源",
                     value: model.power.isOnAC ? "外接电源" : "电池供电",
                     sub: batteryDetail,
                     icon: model.power.isOnAC ? "plug.fill" : "battery.75")
            StatCard(title: "电量",
                     value: model.power.capacityPercent.map { "\($0)%" } ?? "—",
                     sub: model.power.isCharging ? "充电中" : nil,
                     icon: "bolt.battery")
        }
    }

    private var batteryDetail: String? {
        model.power.watts.map { String(format: "%.1f W", model.power.isCharging ? $0 : -$0) }
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
