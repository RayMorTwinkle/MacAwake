import SwiftUI
import MacAwakeCore

/// Tab 4：统计 —— 合盖事件、掉电速度、平均功率、运行/合盖累计。
/// 数据由 StatsRecorder 每 10 秒采样、事件收口，JSON 落盘。
struct StatsTabView: View {
    @ObservedObject var model: AppModel

    @State private var rangeDays = 7
    @State private var confirmClear = false

    var body: some View {
        @ObservedObject var stats = model.stats
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // 当前状态卡
                HStack(spacing: 16) {
                    statCard("电源", value: stats.current.isOnAC ? "外接电源" : "电池",
                             sub: stats.current.isCharging ? "充电中" : nil)
                    statCard("电量", value: stats.current.capacityPercent.map { "\($0)%" } ?? "—",
                             sub: stats.current.watts.map { String(format: "%.1f W", stats.current.isCharging ? $0 : -$0) })
                    statCard("合盖状态", value: stats.isLidClosed ? "已合盖" : "开盖")
                }

                // 区间选择
                Picker("统计范围", selection: $rangeDays) {
                    Text("今天").tag(1)
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)

                // 摘要
                let summary = stats.summary(days: rangeDays)
                let totals = stats.totals(days: rangeDays)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                          spacing: 10) {
                    statCard("App 运行", value: formatInterval(totals.appSeconds))
                    statCard("合盖时长", value: formatInterval(totals.lidSeconds))
                    statCard("合盖次数", value: "\(summary.episodeCount)")
                    statCard("平均掉电速度",
                             value: summary.avgDrainPerHour.map { String(format: "%.1f %%/h", $0) } ?? "—")
                    statCard("平均放电功率",
                             value: summary.avgWatts.map { String(format: "%.1f W", $0) } ?? "—")
                    statCard("平均合盖→入睡",
                             value: summary.avgCloseToSleepSeconds.map(formatInterval) ?? "—")
                }

                // 事件列表
                GroupBox("合盖事件（最近 \(min(20, stats.store.episodes.count)) 条）") {
                    if stats.store.episodes.isEmpty {
                        Text("暂无记录。合盖后开盖 / 入睡会生成一条事件。")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(stats.store.episodes.suffix(20).reversed())) { episode in
                                episodeRow(episode)
                                Divider()
                            }
                        }
                    }
                }

                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Label("清空统计数据", systemImage: "trash")
                }
                .confirmationDialog("确定清空全部统计？不可恢复", isPresented: $confirmClear) {
                    Button("清空", role: .destructive) { stats.clearAll() }
                }
            }
        }
    }

    // MARK: - 子视图

    private func statCard(_ title: String, value: String, sub: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold()).monospacedDigit()
            if let sub {
                Text(sub).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    private func episodeRow(_ episode: LidEpisode) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(episode.closedAt.formatted(.dateTime.month().day().hour().minute()))
                    Text(episode.endKind == .slept ? "入睡" : episode.endKind == .reopened ? "开盖" : "进行中")
                        .font(.caption.bold())
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .foregroundStyle(.white)
                        .background(episode.endKind == .slept ? Color.green : Color.gray, in: Capsule())
                }
                Text("\(formatInterval(episode.duration(now: model.now))) · 掉电 \(episode.drainPercent.map { "\($0)%" } ?? "—") · \(episode.averageWatts.map { String(format: "%.1f W", $0) } ?? "—")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private func formatInterval(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(Int(seconds))s"
    }
}
