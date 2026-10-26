import SwiftUI
import MacAwakeCore

/// 「统计」页：当前状态 + 聚合卡片网格 + 合盖事件列表
struct StatsTabView: View {
    @ObservedObject var model: AppModel

    @State private var rangeDays = 7
    @State private var confirmClear = false

    var body: some View {
        @ObservedObject var stats = model.stats
        VStack(alignment: .leading, spacing: 14) {

            // 当前状态
            HStack(spacing: 12) {
                StatCard(title: "电源",
                         value: stats.current.isOnAC ? "外接电源" : "电池供电",
                         sub: stats.current.isCharging ? "充电中" : nil,
                         icon: stats.current.isOnAC ? "plug.fill" : "battery.75")
                StatCard(title: "电量",
                         value: stats.current.capacityPercent.map { "\($0)%" } ?? "—",
                         sub: stats.current.watts.map { String(format: "%.1f W", stats.current.isCharging ? $0 : -$0) },
                         icon: "bolt.battery")
                StatCard(title: "上盖状态",
                         value: stats.isLidClosed ? "已合盖" : "开盖",
                         sub: stats.isLidClosed && currentEpisodeText != nil ? currentEpisodeText : nil,
                         icon: stats.isLidClosed ? "book.closed.fill" : "book")
            }

            // 范围选择
            HStack {
                Picker("统计范围", selection: $rangeDays) {
                    Text("今天").tag(1)
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                .labelsHidden()
                Spacer()
                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Label("清空数据", systemImage: "trash")
                        .controlSize(.small)
                }
            }

            // 聚合网格
            let summary = stats.summary(days: rangeDays)
            let totals = stats.totals(days: rangeDays)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
                      spacing: 12) {
                StatCard(title: "App 运行", value: formatInterval(totals.appSeconds), icon: "clock")
                StatCard(title: "合盖时长", value: formatInterval(totals.lidSeconds), icon: "book.closed")
                StatCard(title: "合盖次数", value: "\(summary.episodeCount)", icon: "number")
                StatCard(title: "平均掉电速度",
                         value: summary.avgDrainPerHour.map { String(format: "%.1f %%/h", $0) } ?? "—",
                         icon: "battery.50")
                StatCard(title: "平均放电功率",
                         value: summary.avgWatts.map { String(format: "%.1f W", $0) } ?? "—",
                         icon: "bolt")
                StatCard(title: "平均合盖→入睡",
                         value: summary.avgCloseToSleepSeconds.map(formatInterval) ?? "—",
                         icon: "powersleep")
            }

            episodesCard(stats)
        }
        .confirmationDialog("确定清空全部统计数据？不可恢复", isPresented: $confirmClear) {
            Button("清空", role: .destructive) { stats.clearAll() }
        }
    }

    private var currentEpisodeText: String? {
        guard let episode = model.stats.store.episodes.last, episode.endedAt == nil else { return nil }
        return formatInterval(episode.duration(now: model.now))
    }

    // MARK: 事件列表

    private func episodesCard(_ stats: StatsRecorder) -> some View {
        Card(title: "合盖事件（最近 \(min(20, stats.store.episodes.count)) 条）", icon: "list.bullet.rectangle") {
            if stats.store.episodes.isEmpty {
                Text("暂无记录。合盖后入睡或重新开盖，会生成一条完整事件。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(stats.store.episodes.suffix(20).reversed())) { episode in
                        episodeRow(episode)
                        Divider()
                    }
                }
            }
        }
    }

    private func episodeRow(_ episode: LidEpisode) -> some View {
        HStack(spacing: 12) {
            Image(systemName: episode.endKind == .slept ? "powersleep" : "book")
                .foregroundStyle(episode.endKind == .slept ? .green : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(episode.closedAt.formatted(.dateTime.month().day().hour().minute()))
                    .font(.callout.bold())
                Text("\(formatInterval(episode.duration(now: model.now))) · 掉电 \(episode.drainPercent.map { "\($0)%" } ?? "—") · \(episode.averageWatts.map { String(format: "%.1f W", $0) } ?? "—")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            if let kind = episode.endKind {
                Chip(text: kind == .slept ? "入睡" : "开盖",
                     color: kind == .slept ? .green : .secondary)
            } else {
                Chip(text: "进行中", color: .orange)
            }
        }
        .padding(.vertical, 8)
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
