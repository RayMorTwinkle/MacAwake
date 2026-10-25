import SwiftUI
import MacAwakeCore

/// Tab 3：自动化 —— 拼图块式规则编辑器。
/// 一条规则 = 顶部触发块 + 顺序堆叠的动作块（支持上移/下移/删除，形似 Scratch 积木）。
struct AutomationTabView: View {
    @ObservedObject var model: AppModel

    @State private var editingRule: AutomationRule?

    var body: some View {
        @ObservedObject var automation = model.automation
        VStack(alignment: .leading, spacing: 14) {

            HStack {
                Text("\(automation.rules.filter(\.enabled).count)/\(automation.rules.count) 条规则启用")
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    let rule = AutomationRule(name: "新规则",
                                              trigger: .lidClosed,
                                              actions: [.notify(message: "Hello MacAwake")])
                    automation.add(rule)
                    editingRule = rule
                } label: {
                    Label("新建规则", systemImage: "plus")
                }
                Menu {
                    ForEach(Array(AutomationPresets.all.enumerated()), id: \.offset) { _, preset in
                        Button(preset.name) { automation.add(preset) }
                    }
                } label: {
                    Label("加入预置", systemImage: "square.stack.3d.up")
                }
            }

            // 规则列表（触发块样式的行）
            List {
                ForEach(automation.rules) { rule in
                    HStack(spacing: 10) {
                        Toggle("", isOn: bindingFor(rule)).labelsHidden()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rule.name).bold()
                            HStack(spacing: 6) {
                                triggerBadge(rule.trigger)
                                Image(systemName: "arrow.down").font(.caption2).foregroundStyle(.secondary)
                                ForEach(Array(rule.actions.enumerated()), id: \.offset) { _, action in
                                    actionBadge(action)
                                }
                            }
                        }
                        Spacer()
                        Button {
                            automation.runManually(rule)
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("手动执行一次")
                        Button {
                            editingRule = rule
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        .buttonStyle(.borderless)
                        Button(role: .destructive) {
                            automation.remove(id: rule.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.inset)
            .frame(maxHeight: .infinity)

            // 运行记录
            GroupBox("运行记录") {
                ScrollView {
                    Text(automation.runLog.suffix(30).reversed().joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 100)
            }
        }
        .sheet(item: $editingRule) { rule in
            RuleEditorView(automation: model.automation, rule: rule)
                .frame(minWidth: 460, minHeight: 460)
        }
    }

    private func bindingFor(_ rule: AutomationRule) -> Binding<Bool> {
        Binding(
            get: { model.automation.rules.first(where: { $0.id == rule.id })?.enabled ?? false },
            set: { newValue in
                var updated = rule
                updated.enabled = newValue
                model.automation.update(updated)
            }
        )
    }

    // MARK: - 拼图块小部件

    private func triggerBadge(_ trigger: AutomationTrigger) -> some View {
        block(color: .blue, icon: "bolt.fill", text: describeTrigger(trigger))
    }

    @ViewBuilder
    private func actionBadge(_ action: AutomationAction) -> some View {
        switch action {
        case .setBrightness(let level):
            block(color: .yellow, icon: "sun.min", text: "亮度 \(Int(level * 100))%")
        case .pinTopCPU(let n, _):
            block(color: .purple, icon: "cpu", text: "CPU前\(n)钉小核")
        case .unpinAll:
            block(color: .purple, icon: "cpu.badge.clock", text: "解除钉核")
        case .forceSleep:
            block(color: .red, icon: "powersleep", text: "强制睡眠")
        case .keepAwakeOn(let seconds):
            block(color: .indigo, icon: "moon.zzz", text: seconds.map { "不休眠 \($0/60)分" } ?? "不休眠 不限时")
        case .keepAwakeOff:
            block(color: .indigo, icon: "moon", text: "恢复休眠")
        case .notify(let message):
            block(color: .green, icon: "bubble.right", text: message)
        }
    }

    private func block(color: Color, icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2)
            Text(text).font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(color == .yellow ? .black : .white)
        .background(color.gradient, in: Capsule())
    }

    private func describeTrigger(_ trigger: AutomationTrigger) -> String {
        switch trigger {
        case .lidClosed: return "合盖时"
        case .lidOpened: return "开盖时"
        case .pluggedIn: return "接入电源时"
        case .unplugged: return "拔掉电源时"
        case .batteryBelow(let pct, let lid): return "电量<\(pct)%\(lid ? " 且合盖" : "")"
        case .batteryAbove(let pct, let lid): return "电量>\(pct)%\(lid ? " 且合盖" : "")"
        }
    }
}

// MARK: - 规则编辑器（拼图堆叠）

private struct RuleEditorView: View {
    @ObservedObject var automation: AutomationEngine
    @State var rule: AutomationRule
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            triggerSection
            actionsSection
            Spacer()
            footer
        }
        .padding()
    }

    private var header: some View {
        HStack {
            TextField("规则名称", text: $rule.name)
                .textFieldStyle(.roundedBorder)
                .font(.title3.bold())
            Button("保存并关闭") {
                automation.update(rule)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    // 触发块（蓝色，拼图顶座）
    private var triggerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            puzzleLabel("触发")
            HStack(spacing: 10) {
                Picker("", selection: triggerTypeBinding) {
                    Text("合盖").tag("lidClosed")
                    Text("开盖").tag("lidOpened")
                    Text("接入电源").tag("pluggedIn")
                    Text("拔掉电源").tag("unplugged")
                    Text("电量低于").tag("batteryBelow")
                    Text("电量高于").tag("batteryAbove")
                }
                .labelsHidden()
                .frame(maxWidth: 200)

                triggerParameterControls
            }
            .padding(10)
            .background(Color.blue.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private var triggerParameterControls: some View {
        switch rule.trigger {
        case .batteryBelow(let pct, let lid):
            Stepper("电量 < \(pct)%", value: batteryPct, in: 5...95)
            if lid {
                Toggle("仅合盖时", isOn: requiresLid)
            }
        case .batteryAbove(let pct, let lid):
            Stepper("电量 > \(pct)%", value: batteryPct, in: 5...95)
            if lid {
                Toggle("仅合盖时", isOn: requiresLid)
            }
        default:
            EmptyView()
        }
    }

    // 动作块堆叠
    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            puzzleLabel("动作（从上到下依次执行）")
            ForEach(Array(rule.actions.indices), id: \.self) { index in
                ActionBlockRow(action: bindingForAction(index)) {
                    withAnimation { rule.actions.remove(at: index); return () }
                } onMoveUp: {
                    guard index > 0 else { return }
                    withAnimation { rule.actions.swapAt(index, index - 1) }
                } onMoveDown: {
                    guard index < rule.actions.count - 1 else { return }
                    withAnimation { rule.actions.swapAt(index, index + 1) }
                }
            }

            Menu {
                Button("设置屏幕亮度") { rule.actions.append(.setBrightness(level: 0)) }
                Button("CPU 前 N 钉小核") { rule.actions.append(.pinTopCPU(n: 5, stickyUntilLidOpen: true)) }
                Button("解除全部钉核") { rule.actions.append(.unpinAll) }
                Button("强制睡眠") { rule.actions.append(.forceSleep) }
                Button("开启合盖不休眠") { rule.actions.append(.keepAwakeOn(seconds: nil)) }
                Button("关闭合盖不休眠") { rule.actions.append(.keepAwakeOff) }
                Button("发送通知") { rule.actions.append(.notify(message: "通知内容")) }
            } label: {
                Label("添加动作块", systemImage: "plus.square.dashed")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var footer: some View {
        HStack {
            Toggle("启用此规则", isOn: $rule.enabled)
            Spacer()
            Button {
                automation.update(rule)
                automation.runManually(rule)
            } label: {
                Label("保存并试运行", systemImage: "play")
            }
        }
    }

    private func puzzleLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
    }

    // MARK: 触发器绑定辅助

    private var triggerTypeBinding: Binding<String> {
        Binding(
            get: {
                switch rule.trigger {
                case .lidClosed: return "lidClosed"
                case .lidOpened: return "lidOpened"
                case .pluggedIn: return "pluggedIn"
                case .unplugged: return "unplugged"
                case .batteryBelow: return "batteryBelow"
                case .batteryAbove: return "batteryAbove"
                }
            },
            set: { raw in
                switch raw {
                case "lidClosed": rule.trigger = .lidClosed
                case "lidOpened": rule.trigger = .lidOpened
                case "pluggedIn": rule.trigger = .pluggedIn
                case "unplugged": rule.trigger = .unplugged
                case "batteryBelow": rule.trigger = .batteryBelow(pct: batteryPct.wrappedValue, whileLidClosed: rule.trigger.requiresLidClosed)
                case "batteryAbove": rule.trigger = .batteryAbove(pct: batteryPct.wrappedValue, whileLidClosed: rule.trigger.requiresLidClosed)
                default: break
                }
            }
        )
    }

    /// 电量参数的读写（batteryBelow / batteryAbove 共用）
    private var batteryPct: Binding<Int> {
        Binding(
            get: {
                switch rule.trigger {
                case .batteryBelow(let pct, _), .batteryAbove(let pct, _): return pct
                default: return 30
                }
            },
            set: { newValue in
                switch rule.trigger {
                case .batteryBelow(_, let lid): rule.trigger = .batteryBelow(pct: newValue, whileLidClosed: lid)
                case .batteryAbove(_, let lid): rule.trigger = .batteryAbove(pct: newValue, whileLidClosed: lid)
                default: break
                }
            }
        )
    }

    private var requiresLid: Binding<Bool> {
        Binding(
            get: {
                if case .batteryBelow(_, let lid) = rule.trigger { return lid }
                if case .batteryAbove(_, let lid) = rule.trigger { return lid }
                return false
            },
            set: { newValue in
                switch rule.trigger {
                case .batteryBelow(let pct, _): rule.trigger = .batteryBelow(pct: pct, whileLidClosed: newValue)
                case .batteryAbove(let pct, _): rule.trigger = .batteryAbove(pct: pct, whileLidClosed: newValue)
                default: break
                }
            }
        )
    }

    private func bindingForAction(_ index: Int) -> Binding<AutomationAction> {
        Binding(
            get: { rule.actions[index] },
            set: { rule.actions[index] = $0 }
        )
    }
}

/// 单个动作块：彩色块 + 参数控件 + 排序/删除按钮
private struct ActionBlockRow: View {
    @Binding var action: AutomationAction
    var onDelete: () -> Void
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 2) {
                Button(action: onMoveUp) { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                Button(action: onMoveDown) { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
            }

            switch action {
            case .setBrightness(let level):
                blockView(color: .yellow, icon: "sun.min") {
                    Slider(value: Binding(
                        get: { level },
                        set: { action = .setBrightness(level: $0) }
                    ), in: 0...1, step: 0.05)
                    Text("亮度 \(Int(level * 100))%").monospacedDigit().frame(width: 70)
                }

            case .pinTopCPU(let n, let sticky):
                blockView(color: .purple, icon: "cpu") {
                    Stepper("前 \(n) 名", value: Binding(
                        get: { n },
                        set: { action = .pinTopCPU(n: $0, stickyUntilLidOpen: sticky) }
                    ), in: 1...20)
                    Toggle("开盖解除", isOn: Binding(
                        get: { sticky },
                        set: { action = .pinTopCPU(n: n, stickyUntilLidOpen: $0) }
                    ))
                }

            case .unpinAll:
                blockView(color: .purple, icon: "cpu.badge.clock") {
                    Text("解除本应用全部钉核")
                }

            case .forceSleep:
                blockView(color: .red, icon: "powersleep") {
                    Text("立即强制睡眠")
                }

            case .keepAwakeOn(let seconds):
                blockView(color: .indigo, icon: "moon.zzz") {
                    Picker("时长", selection: Binding(
                        get: { seconds ?? -1 },
                        set: { action = .keepAwakeOn(seconds: $0 == -1 ? nil : $0) }
                    )) {
                        Text("不限时").tag(-1)
                        Text("30 分钟").tag(1800)
                        Text("1 小时").tag(3600)
                        Text("2 小时").tag(7200)
                    }
                }

            case .keepAwakeOff:
                blockView(color: .indigo, icon: "moon") {
                    Text("恢复合盖休眠")
                }

            case .notify(let message):
                blockView(color: .green, icon: "bubble.right") {
                    TextField("通知内容", text: Binding(
                        get: { message },
                        set: { action = .notify(message: $0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }

            Spacer()
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(colorFor(action).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }

    private func blockView<Content: View>(color: Color, icon: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            content()
        }
    }

    private func colorFor(_ action: AutomationAction) -> Color {
        switch action {
        case .setBrightness: return .yellow
        case .pinTopCPU, .unpinAll: return .purple
        case .forceSleep: return .red
        case .keepAwakeOn, .keepAwakeOff: return .indigo
        case .notify: return .green
        }
    }
}
