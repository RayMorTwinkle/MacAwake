import SwiftUI
import MacAwakeCore

/// 「能效调度」页：易用模式（App 列表一键钉核）+ 专业模式（规则/门控/平衡/日志）
struct EfficiencyTabView: View {
    @ObservedObject var model: AppModel

    @AppStorage("efficiency.useSimpleMode") private var useSimpleMode = true

    var body: some View {
        @ObservedObject var engine = model.efficiency
        VStack(alignment: .leading, spacing: 14) {

            controlBar

            AppPickerCard(model: model)

            if useSimpleMode {
                Label("想按关键词自动监控、调平衡策略？切到专业模式", systemImage: "lightbulb")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                proSection
            }
        }
    }

    // MARK: 顶部控制条

    private var controlBar: some View {
        @ObservedObject var engine = model.efficiency
        return HStack(spacing: 12) {
            Button {
                engine.isRunning ? engine.stop() : engine.start()
            } label: {
                Label(engine.isRunning ? "停止调度" : "开始调度",
                      systemImage: engine.isRunning ? "stop.fill" : "play.fill")
                    .frame(minWidth: 108)
            }
            .controlSize(.large)
            .tint(engine.isRunning ? .red : .blue)

            Picker("模式", selection: Binding(
                get: { engine.mode },
                set: { engine.mode = $0 }
            )) {
                Text("钉小核 · 省电").tag(EfficiencyEngine.Mode.efficiency)
                Text("钉大核 · 性能").tag(EfficiencyEngine.Mode.performance)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 270)

            Spacer()

            HStack(spacing: 8) {
                if engine.isRunning, let next = engine.nextScanAt {
                    Chip(text: "下次扫描 \(Int(max(0, next.timeIntervalSince(model.now))))s", color: .blue)
                }
                Chip(text: "系统 CPU \(Int(engine.lastSystemCPU))%", color: .secondary)
            }

            Picker("", selection: $useSimpleMode) {
                Text("易用").tag(true)
                Text("专业").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(width: 108)
            .help("易用模式：只保留一键操作；专业模式：完整规则与策略")
        }
    }

    // MARK: 专业区

    private var proSection: some View {
        @ObservedObject var engine = model.efficiency
        return VStack(alignment: .leading, spacing: 14) {
            rulesCard(engine: engine)
            gatingCard(engine: engine)
            trackedCard(engine: engine)
            logCard(engine: engine)
        }
    }

    private func rulesCard(engine: EfficiencyEngine) -> some View {
        Card(title: "监控规则（每行一个关键词，匹配进程名 / 命令行）", icon: "text.magnifyingglass") {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: Binding(
                    get: { engine.customPatternsText },
                    set: { engine.customPatternsText = $0 }
                ))
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 68)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))

                Toggle("叠加默认规则（Renderer | bilibili | wine）", isOn: Binding(
                    get: { engine.useDefaultRules },
                    set: { engine.useDefaultRules = $0 }
                ))

                HStack(spacing: 6) {
                    Image(systemName: "curlybraces.square")
                        .font(.caption)
                    Text(engine.rules.combinedRegex.isEmpty ? "（空，不会匹配任何进程）" : engine.rules.combinedRegex)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        }
    }

    private func gatingCard(engine: EfficiencyEngine) -> some View {
        Card(title: "门控与平衡", icon: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("仅电池供电时钉核（插电时不折腾）", isOn: Binding(
                    get: { engine.batteryOnly },
                    set: { engine.batteryOnly = $0 }
                ))
                Divider()
                Toggle("平衡模式（钉住进程 CPU 飙高时自动放回大核）", isOn: Binding(
                    get: { engine.balanceEnabled },
                    set: { engine.balanceEnabled = $0 }
                ))
                sliderRow("系统 CPU 门槛", value: Binding(
                    get: { engine.cpuGatePercent },
                    set: { engine.cpuGatePercent = $0 }
                ), range: 5...80, unit: "%")
                sliderRow("单进程放行阈值", value: Binding(
                    get: { engine.balanceThreshold },
                    set: { engine.balanceThreshold = $0 }
                ), range: 20...400, unit: "%")
            }
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String) -> some View {
        HStack(spacing: 10) {
            Text(title).frame(width: 110, alignment: .leading)
            Slider(value: value, in: range, step: 1)
            Text("\(Int(value.wrappedValue))\(unit)")
                .monospacedDigit()
                .frame(width: 48)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 被钉进程表

    private func trackedCard(engine: EfficiencyEngine) -> some View {
        Card(title: "被钉进程（\(engine.trackedList.count)）", icon: "pin") {
            if engine.trackedList.isEmpty {
                Text(engine.isRunning ? "等待匹配规则的进程出现…" : "调度未运行。开始调度后匹配的进程会被钉到对应核。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(engine.trackedList) { proc in
                        HStack(spacing: 10) {
                            Image(systemName: proc.assignment == .efficiency ? "tortoise.fill" : "hare.fill")
                                .foregroundStyle(proc.assignment == .efficiency ? .blue : .orange)
                            Text(proc.name).lineLimit(1).truncationMode(.middle)
                            Text("PID \(proc.pid)")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.0f%% CPU", proc.cpuPercent))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 70)
                            Button {
                                _ = model.efficiency.taskPolicy.restore(pid: proc.pid)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("恢复默认调度")
                        }
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
        }
    }

    private func logCard(engine: EfficiencyEngine) -> some View {
        Card(title: "运行日志（最近 24 条）", icon: "terminal") {
            Text(engine.logLines.suffix(24).joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: 240, alignment: .topLeading)
                .textSelection(.enabled)
        }
    }
}

// MARK: - 正在运行的应用（易用模式主卡）

private struct AppPickerCard: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var expanded = false

    private static let collapsedCount = 5

    private var filtered: [AppPickerStore.RunningApp] {
        query.isEmpty
            ? model.appPicker.apps
            : model.appPicker.apps.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// 折叠时只显示 CPU 最高的前几个；展开给全部（页面整体滚动，不用嵌套滚动）
    private var visible: [AppPickerStore.RunningApp] {
        expanded ? filtered : Array(filtered.prefix(Self.collapsedCount))
    }

    var body: some View {
        Card(title: "正在运行的应用（\(model.appPicker.apps.count) 个 · 点击即时生效，含全部子进程）", icon: "app.dashed") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("搜索应用…", text: $query)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

                if filtered.isEmpty {
                    Text("没有匹配的应用")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 10)
                } else {
                    VStack(spacing: 0) {
                        ForEach(visible) { app in
                            AppRow(model: model, app: app)
                                .padding(.horizontal, 2)
                                .padding(.vertical, 6)
                            Divider()
                        }
                    }

                    if filtered.count > Self.collapsedCount {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                        } label: {
                            Label(expanded ? "收起" : "显示全部 \(filtered.count) 个应用",
                  systemImage: expanded ? "chevron.up" : "chevron.down")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderless)
                    }
                }

                if let last = model.appPicker.lastLog {
                    Label(last, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .onChange(of: query) { _ in expanded = true } // 搜索时自动展开
    }
}

private struct AppRow: View {
    @ObservedObject var model: AppModel
    let app: AppPickerStore.RunningApp

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).bold().lineLimit(1)
                Text(app.procCount > 0 ? "\(app.procCount) 个进程" : "主进程")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // CPU 占用条
            HStack(spacing: 6) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule()
                            .fill(cpuColor)
                            .frame(width: max(3, geo.size.width * min(1, app.cpu / 400)))
                    }
                }
                .frame(width: 56, height: 5)
                Text(String(format: "%.0f%%", app.cpu))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            if model.appPicker.isWatched(app) {
                Chip(text: "监控中", color: .blue)
            }

            Button {
                model.appPicker.limitNow(app)
            } label: {
                Label("钉小核", systemImage: "tortoise.fill")
            }
            .controlSize(.small)

            Button {
                model.appPicker.restoreNow(app)
            } label: {
                Label("恢复", systemImage: "hare.fill")
            }
            .controlSize(.small)

            Button {
                model.appPicker.addToRules(app)
            } label: {
                Image(systemName: "eye")
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .help("把「\(app.name)」加入持续监控规则")
        }
    }

    private var cpuColor: Color {
        app.cpu > 100 ? .red : app.cpu > 30 ? .orange : .green
    }
}
