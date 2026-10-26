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
    let appPicker: AppPickerStore

    /// 1 秒心跳：驱动剩余时间倒计时、电量刷新等
    @Published private(set) var now = Date()
    @Published private(set) var power = PowerSnapshot.onACDesktop
    /// 主窗口是否可见（可见时 App 列表才自动刷新，省电）
    @Published var isWindowVisible = false

    private var timer: Timer?
    private var lastPickerRefresh = Date.distantPast

    init(controller: SessionController,
         efficiency: EfficiencyEngine,
         automation: AutomationEngine,
         stats: StatsRecorder,
         appPicker: AppPickerStore) {
        self.controller = controller
        self.efficiency = efficiency
        self.automation = automation
        self.stats = stats
        self.appPicker = appPicker
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
        if isWindowVisible, now.timeIntervalSince(lastPickerRefresh) > 4 {
            lastPickerRefresh = now
            appPicker.refresh()
        }
    }

    // MARK: - 电源页派生状态

    var isEffectivelyOn: Bool {
        controller.session != nil || controller.systemState == .on
    }

    var remainingSeconds: TimeInterval? {
        controller.session?.remaining(now: now)
    }
}

// MARK: - 主窗口（侧边栏导航）

struct MainTabView: View {
    @ObservedObject var model: AppModel

    enum Page: String, CaseIterable, Identifiable {
        case power, efficiency, automation, stats
        var id: String { rawValue }

        var title: String {
            switch self {
            case .power: return "合盖不休眠"
            case .efficiency: return "能效调度"
            case .automation: return "自动化"
            case .stats: return "统计"
            }
        }

        var icon: String {
            switch self {
            case .power: return "moon.zzz.fill"
            case .efficiency: return "cpu.fill"
            case .automation: return "puzzlepiece.fill"
            case .stats: return "chart.bar.fill"
            }
        }

        var tint: Color {
            switch self {
            case .power: return .indigo
            case .efficiency: return .blue
            case .automation: return .orange
            case .stats: return .green
            }
        }
    }

    @State private var page: Page = .power

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .navigationSplitViewColumnWidth(min: 185, ideal: 200, max: 230)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 580)
    }

    // MARK: 侧边栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            // 品牌区
            HStack(spacing: 10) {
                Image(systemName: "moon.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.indigo.gradient)
                Text("MacAwake")
                    .font(.title3.bold())
                if PowerManager.isDevBuild {
                    Text("DEV")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .foregroundStyle(.orange)
                        .background(.orange.opacity(0.15), in: Capsule())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 12)

            List {
                ForEach(Page.allCases) { p in
                    NavigationLink(value: p) {
                        Label {
                            Text(p.title)
                        } icon: {
                            Image(systemName: p.icon)
                                .foregroundStyle(page == p ? AnyShapeStyle(p.tint.gradient) : AnyShapeStyle(Color.secondary))
                                .frame(width: 20)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 8))
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .navigationDestination(for: Page.self) { p in
                detail(for: p)
                    .environment(\.pageTint, p.tint)
            }
            .safeAreaInset(edge: .bottom) {
                batteryFooter
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
        .onAppear { page = .power }
    }

    /// 侧边栏底部：电源快照（常显，全局可用信息）
    private var batteryFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: model.power.isOnAC ? "plug.fill" : "battery.75")
                .foregroundStyle(model.power.isOnAC ? .green : .yellow)
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 1) {
                Text(footerLine)
                    .font(.caption)
                    .monospacedDigit()
                if let watts = model.power.watts, watts > 0 {
                    Text(String(format: "%.1f W", model.power.isCharging ? watts : -watts))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var footerLine: String {
        var parts: [String] = []
        if let pct = model.power.capacityPercent { parts.append("\(pct)%") }
        parts.append(model.power.isOnAC ? "外接电源" : "电池")
        return parts.joined(separator: " · ")
    }

    // MARK: 详情区

    private var detail: some View {
        detail(for: page)
            .environment(\.pageTint, page.tint)
    }

    @ViewBuilder
    private func detail(for p: Page) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pageHeader(p)
                content(p)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(p) // 切页重置滚动
    }

    private func pageHeader(_ p: Page) -> some View {
        HStack(spacing: 12) {
            Image(systemName: p.icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(p.tint.gradient)
                .frame(width: 40, height: 40)
                .background(p.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            Text(p.title)
                .font(.title2.bold())
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private func content(_ p: Page) -> some View {
        switch p {
        case .power: PowerTabView(model: model)
        case .efficiency: EfficiencyTabView(model: model)
        case .automation: AutomationTabView(model: model)
        case .stats: StatsTabView(model: model)
        }
    }
}

// MARK: - 共享设计组件

/// 页面主色调（每页注入，卡片/图标统一取色）
private struct PageTintKey: EnvironmentKey {
    static let defaultValue: Color = .accentColor
}

extension EnvironmentValues {
    var pageTint: Color {
        get { self[PageTintKey.self] }
        set { self[PageTintKey.self] = newValue }
    }
}

/// 统一卡片容器
struct Card<Content: View>: View {
    var title: String?
    var icon: String?
    @Environment(\.pageTint) private var tint
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 6) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                    Text(title)
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }
}

/// 大数字统计卡
struct StatCard: View {
    let title: String
    let value: String
    var sub: String? = nil
    var icon: String? = nil
    @Environment(\.pageTint) private var tint

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(.title3, design: .rounded).bold())
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let sub {
                Text(sub)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.04), radius: 5, y: 1)
    }
}

/// 小徽章
struct Chip: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}
