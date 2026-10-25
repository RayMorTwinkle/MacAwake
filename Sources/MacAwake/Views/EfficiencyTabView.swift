import SwiftUI
import MacAwakeCore

/// Tab 2：能效调度（EfficiencyTool 移植）
struct EfficiencyTabView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        @ObservedObject var engine = model.efficiency
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {

                // 启停 + 模式
                HStack {
                    Button {
                        engine.isRunning ? engine.stop() : engine.start()
                    } label: {
                        Label(engine.isRunning ? "停止调度" : "开始调度",
                              systemImage: engine.isRunning ? "stop.fill" : "play.fill")
                            .frame(minWidth: 110)
                    }
                    .controlSize(.large)
                    .tint(engine.isRunning ? .red : .accentColor)

                    Picker("模式", selection: Binding(
                        get: { engine.mode },
                        set: { engine.mode = $0 }
                    )) {
                        Text("钉小核（省电）").tag(EfficiencyEngine.Mode.efficiency)
                        Text("钉大核（性能）").tag(EfficiencyEngine.Mode.performance)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        if engine.isRunning, let next = engine.nextScanAt {
                            Text("下次扫描 \(Int(max(0, next.timeIntervalSince(model.now))))s")
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                        Text("系统 CPU \(Int(engine.lastSystemCPU))%")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }

                // 规则
                GroupBox("匹配规则（每行一个关键词，按进程名/路径匹配）") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: Binding(
                            get: { engine.customPatternsText },
                            set: { engine.customPatternsText = $0 }
                        ))
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 64)
                        .border(.quaternary)

                        Toggle("叠加默认规则（Renderer|bilibili|wine）", isOn: Binding(
                            get: { engine.useDefaultRules },
                            set: { engine.useDefaultRules = $0 }
                        ))
                        Text("生效正则：\(engine.rules.combinedRegex.isEmpty ? "（空，不匹配任何进程）" : engine.rules.combinedRegex)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 4)
                }

                // 门控与平衡
                GroupBox("门控") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("仅电池供电时钉核（插电不动）", isOn: Binding(
                            get: { engine.batteryOnly },
                            set: { engine.batteryOnly = $0 }
                        ))
                        Divider()
                        Toggle("平衡模式（CPU 飙高自动放回大核）", isOn: Binding(
                            get: { engine.balanceEnabled },
                            set: { engine.balanceEnabled = $0 }
                        ))
                        HStack {
                            Text("系统 CPU 门槛")
                            Slider(value: Binding(
                                get: { engine.cpuGatePercent },
                                set: { engine.cpuGatePercent = $0 }
                            ), in: 5...80, step: 1)
                            Text("\(Int(engine.cpuGatePercent))%").monospacedDigit().frame(width: 40)
                        }
                        HStack {
                            Text("单进程放行阈值")
                            Slider(value: Binding(
                                get: { engine.balanceThreshold },
                                set: { engine.balanceThreshold = $0 }
                            ), in: 20...400, step: 10)
                            Text("\(Int(engine.balanceThreshold))%").monospacedDigit().frame(width: 48)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // 被钉进程表
                GroupBox("被钉进程（\(engine.trackedList.count)）") {
                    if engine.trackedList.isEmpty {
                        Text("暂无。开始调度后，匹配规则的进程会被钉到对应核。")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(engine.trackedList) { proc in
                                HStack {
                                    Text(proc.name).lineLimit(1).truncationMode(.middle)
                                    Text("PID \(proc.pid)")
                                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                    Spacer()
                                    Text(String(format: "%.0f%%", proc.cpuPercent))
                                        .monospacedDigit().frame(width: 52)
                                        .foregroundStyle(.secondary)
                                    Text(proc.assignment == .efficiency ? "小核" : "大核")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 8).padding(.vertical, 2)
                                        .foregroundStyle(proc.assignment == .efficiency ? .blue : .orange)
                                        .background((proc.assignment == .efficiency ? Color.blue : Color.orange).opacity(0.15),
                                                    in: Capsule())
                                    Button {
                                        _ = model.efficiency.taskPolicy.restore(pid: proc.pid)
                                    } label: {
                                        Image(systemName: "xmark.circle")
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(.vertical, 4)
                                Divider()
                            }
                        }
                    }
                }

                // 日志
                GroupBox("运行日志") {
                    ScrollView {
                        Text(engine.logLines.suffix(40).joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 130)
                }
            }
        }
    }
}
