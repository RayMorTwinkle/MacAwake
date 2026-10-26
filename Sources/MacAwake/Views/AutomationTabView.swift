import SwiftUI
import MacAwakeCore

/// 「自动化」页：规则卡片列表 + 拼图块编辑器 + 运行记录
struct AutomationTabView: View {
    @ObservedObject var model: AppModel

    @State private var editingRule: AutomationRule?

    var body: some View {
        @ObservedObject var automation = model.automation
        VStack(alignment: .leading, spacing: 14) {

            HStack(spacing: 10) {
                Text("\(automation.rules.filter(\.enabled).count)/\(automation.rules.count) 条规则启用")
                    .font(.callout)
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

            ruleCards(automation)

            runLogCard(automation)
        }
        .sheet(item: $editingRule) { rule in
            RuleEditorView(automation: model.automation, rule: rule)
                .frame(minWidth: 520, minHeight: 540)
        }
    }

    // MARK: 规则卡片

    private func ruleCards(_ automation: AutomationEngine) -> some View {
        VStack(spacing: 10) {
            if automation.rules.isEmpty {
                Text("还没有规则。点「加入预置」快速开始。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
            ForEach(automation.rules) { rule in
                RuleCard(rule: rule,
                         onToggle: { on in
                             var r = rule; r.enabled = on; automation.update(r)
                         },
                         onRun: { automation.runManually(rule) },
                         onEdit: { editingRule = rule },
                         onDelete: { automation.remove(id: rule.id) })
            }
        }
    }

    private func runLogCard(_ automation: AutomationEngine) -> some View {
        Card(title: "运行记录", icon: "clock.arrow.circlepath") {
            if automation.runLog.isEmpty {
                Text("规则触发后会在这里留痕")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(automation.runLog.suffix(30).reversed().joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 110)
            }
        }
    }
}

// MARK: - 规则卡片

private struct RuleCard: View {
    let rule: AutomationRule
    var onToggle: (Bool) -> Void
    var onRun: () -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: onToggle))
                .labelsHidden()
                .tint(.orange)

            // 触发 → 动作 流程链
            VStack(alignment: .leading, spacing: 6) {
                Text(rule.name).font(.headline)
                HStack(spacing: 7) {
                    triggerBadge(rule.trigger)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                    ForEach(Array(rule.actions.enumerated()), id: \.offset) { _, action in
                        actionBadge(action)
                    }
                }
            }
            Spacer()
            Button(action: onRun) { Image(systemName: "play.circle.fill").font(.system(size: 19)) }
                .buttonStyle(.borderless).help("手动执行一次")
            Button(action: onEdit) { Image(systemName: "slider.horizontal.3").font(.system(size: 15)) }
                .buttonStyle(.borderless).help("编辑")
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash").font(.system(size: 14)) }
                .buttonStyle(.borderless).help("删除")
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.04), radius: 5, y: 1)
        .opacity(rule.enabled ? 1 : 0.55)
    }

    private func triggerBadge(_ trigger: AutomationTrigger) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill").font(.system(size: 9))
            Text(describeTrigger(trigger))
        }
        .font(.caption2.bold())
        .padding(.horizontal, 9).padding(.vertical, 4)
        .foregroundStyle(.white)
        .background(Color.blue.gradient, in: Capsule())
    }

    @ViewBuilder
    private func actionBadge(_ action: AutomationAction) -> some View {
        let (text, icon, color) = describeAction(action)
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text)
        }
        .font(.caption2.bold())
        .padding(.horizontal, 9).padding(.vertical, 4)
        .foregroundStyle(color == .yellow ? .black.opacity(0.75) : .white)
        .background(color.gradient, in: Capsule())
    }

    private func describeAction(_ action: AutomationAction) -> (String, String, Color) {
        switch action {
        case .setBrightness(let level): return ("亮度 \(Int(level * 100))%", "sun.min", .yellow)
        case .pinTopCPU(let n, _): return ("CPU前\(n)钉小核", "cpu", .purple)
        case .pinKeyword(let kw): return ("「\(kw)」钉小核", "text.magnifyingglass", .purple)
        case .pinApp(let app): return ("「\(app)」钉小核", "app.badge", .purple)
        case .unpinAll: return ("解除钉核", "cpu.badge.clock", .purple)
        case .displaySleep: return ("熄屏", "moon.stars", .teal)
        case .forceSleep: return ("强制睡眠", "powersleep", .red)
        case .quitApp(let app): return ("退出「\(app)」", "xmark.app", .pink)
        case .wait(let minutes): return ("等待 \(minutes >= 1 ? String(format: "%.0f", minutes) + " 分" : String(Int(minutes * 60)) + " 秒")", "clock.arrow.circlepath", .gray)
        case .keepAwakeOn(let seconds): return (seconds.map { "不休眠 \($0/60)分" } ?? "不休眠", "moon.zzz", .indigo)
        case .keepAwakeOff: return ("恢复休眠", "moon", .indigo)
        case .notify(let message): return (message, "bubble.right", .green)
        }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                triggerSection
                actionsSection
                Spacer(minLength: 4)
                footer
            }
            .padding(20)
        }
        .frame(minWidth: 520, minHeight: 540)
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

    // 触发块：拼图顶座（带凸起咬口）
    private var triggerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("当（触发）")
                .font(.caption.bold()).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Picker("", selection: triggerTypeBinding) {
                    Text("合盖").tag("lidClosed")
                    Text("开盖").tag("lidOpened")
                    Text("接入电源").tag("pluggedIn")
                    Text("拔掉电源").tag("unplugged")
                    Text("电量低于").tag("batteryBelow")
                    Text("电量高于").tag("batteryAbove")
                }
                .labelsHidden()
                .frame(maxWidth: 230)
                .tint(.blue)

                switch rule.trigger {
                case .batteryBelow(let pct, _):
                    Stepper("电量 < \(pct)%", value: batteryPct, in: 5...95)
                case .batteryAbove(let pct, _):
                    Stepper("电量 > \(pct)%", value: batteryPct, in: 5...95)
                default:
                    EmptyView()
                }

                if rule.trigger.requiresLidClosed {
                    Toggle("仅合盖时", isOn: requiresLid)
                }
            }
            .padding(14)
            .background(Color.blue.gradient.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
        }
    }

    // 动作块堆叠
    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("就（动作，从上到下依次执行）")
                .font(.caption.bold()).foregroundStyle(.secondary)

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
                Button("熄屏") { rule.actions.append(.displaySleep) }
                Button("CPU 前 N 钉小核") { rule.actions.append(.pinTopCPU(n: 5, stickyUntilLidOpen: true)) }
                Button("钉关键词进程小核") { rule.actions.append(.pinKeyword(keyword: "关键词")) }
                Button("钉指定应用小核") { rule.actions.append(.pinApp(appName: "应用名")) }
                Button("解除全部钉核") { rule.actions.append(.unpinAll) }
                Button("等待") { rule.actions.append(.wait(minutes: 5)) }
                Button("强制睡眠") { rule.actions.append(.forceSleep) }
                Button("退出指定应用") { rule.actions.append(.quitApp(appName: "应用名")) }
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

    // MARK: 触发器绑定

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

/// 单个动作块：彩色拼图块（左侧色带 + 咬口圆点），参数控件 + 排序/删除
private struct ActionBlockRow: View {
    @Binding var action: AutomationAction
    var onDelete: () -> Void
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(spacing: 3) {
                Button(action: onMoveUp) { Image(systemName: "chevron.up").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.borderless)
                Circle().fill(color.opacity(0.5)).frame(width: 7, height: 7)
                Button(action: onMoveDown) { Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(.borderless)
            }

            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 26)

            bodyByType
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
                .shadow(color: color.opacity(0.25), radius: 4, y: 1)
        )
        .overlay(alignment: .leading) {
            // 左侧拼图色带
            RoundedRectangle(cornerRadius: 3)
                .fill(color.gradient)
                .frame(width: 5)
                .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var bodyByType: some View {
        switch action {
        case .setBrightness(let level):
            HStack {
                Image(systemName: "sun.min")
                Slider(value: Binding(
                    get: { level },
                    set: { action = .setBrightness(level: $0) }
                ), in: 0...1, step: 0.05)
                Text("亮度 \(Int(level * 100))%").monospacedDigit().frame(width: 72)
            }

        case .pinKeyword(let keyword):
            HStack {
                Text("命令行含")
                TextField("关键词", text: Binding(
                    get: { keyword },
                    set: { action = .pinKeyword(keyword: $0) }
                ))
                .textFieldStyle(.roundedBorder)
                Text("的进程 → 小核")
            }

        case .pinApp(let appName):
            HStack {
                Text("应用")
                TextField("应用名（如 Chrome）", text: Binding(
                    get: { appName },
                    set: { action = .pinApp(appName: $0) }
                ))
                .textFieldStyle(.roundedBorder)
                Text("全部进程 → 小核")
            }

        case .quitApp(let appName):
            HStack {
                Text("退出应用")
                TextField("应用名", text: Binding(
                    get: { appName },
                    set: { action = .quitApp(appName: $0) }
                ))
                .textFieldStyle(.roundedBorder)
            }

        case .wait(let minutes):
            HStack {
                Slider(value: Binding(
                    get: { minutes },
                    set: { action = .wait(minutes: $0) }
                ), in: 0.5...120, step: 0.5)
                Text(minutes >= 1 ? String(format: "%.0f 分钟", minutes) : "\(Int(minutes * 60)) 秒")
                    .monospacedDigit()
                    .frame(width: 72)
            }

        case .displaySleep:
            Text("立即熄屏（动鼠标即亮）")

        case .pinTopCPU(let n, let sticky):
            HStack {
                Stepper("CPU 占用前 \(n) 名", value: Binding(
                    get: { n },
                    set: { action = .pinTopCPU(n: $0, stickyUntilLidOpen: sticky) }
                ), in: 1...20)
                Toggle("开盖解除", isOn: Binding(
                    get: { sticky },
                    set: { action = .pinTopCPU(n: n, stickyUntilLidOpen: $0) }
                ))
            }

        case .unpinAll:
            Text("解除本应用全部钉核")

        case .forceSleep:
            Text("立即强制睡眠")

        case .keepAwakeOn(let seconds):
            Picker("时长", selection: Binding(
                get: { seconds ?? -1 },
                set: { action = .keepAwakeOn(seconds: $0 == -1 ? nil : $0) }
            )) {
                Text("不限时").tag(-1)
                Text("30 分钟").tag(1800)
                Text("1 小时").tag(3600)
                Text("2 小时").tag(7200)
            }

        case .keepAwakeOff:
            Text("恢复合盖休眠")

        case .notify(let message):
            TextField("通知内容", text: Binding(
                get: { message },
                set: { action = .notify(message: $0) }
            ))
            .textFieldStyle(.roundedBorder)
        }
    }

    private var icon: String {
        switch action {
        case .setBrightness: return "sun.min"
        case .pinTopCPU: return "cpu"
        case .pinKeyword: return "text.magnifyingglass"
        case .pinApp: return "app.badge"
        case .unpinAll: return "cpu.badge.clock"
        case .displaySleep: return "moon.stars"
        case .forceSleep: return "powersleep"
        case .quitApp: return "xmark.app"
        case .wait: return "clock.arrow.circlepath"
        case .keepAwakeOn: return "moon.zzz"
        case .keepAwakeOff: return "moon"
        case .notify: return "bubble.right"
        }
    }

    private var color: Color {
        switch action {
        case .setBrightness: return .yellow
        case .pinTopCPU, .pinKeyword, .pinApp, .unpinAll: return .purple
        case .displaySleep: return .teal
        case .forceSleep: return .red
        case .quitApp: return .pink
        case .wait: return .gray
        case .keepAwakeOn, .keepAwakeOff: return .indigo
        case .notify: return .green
        }
    }
}
