import AppKit
import UserNotifications

/// 系统通知（重启接管提示 / 定时到点提示 / 漂移自愈提示）。
///
/// 直接跑 `.build/release/MacAwake`（未打包）时 `UNUserNotificationCenter` 会抛
/// `bundleProxyForCurrentProcess is nil`，所以这里用 bundleIdentifier 兜住：
/// 未打包运行只写日志，不影响功能。首次投递会弹一次系统授权。
@MainActor
enum Notifier {

    private static var didRequestAuthorization = false

    /// 发送一条即时通知（授权被拒时静默降级为日志）
    ///
    /// 全程 async/await：`requestAuthorization` / `add` 的 ObjC completion 回调
    /// 在 UN 后台队列执行，而非 @Sendable 闭包会继承 MainActor 隔离，
    /// 入口的 dispatch_assert_queue 运行时检查会直接 SIGTRAP
    /// （v1.2.0 开机自启发"检测到重启"通知后 1 秒崩溃 ×6 的根因）。
    static func post(title: String, body: String) {
        Logger.info("通知: \(title) — \(body)")

        guard Bundle.main.bundleIdentifier != nil else { return }

        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            do {
                if !didRequestAuthorization {
                    didRequestAuthorization = true
                    guard try await center.requestAuthorization(options: [.alert]) else {
                        Logger.info("通知未授权，仅记录日志")
                        return
                    }
                }
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                    content: content,
                                                    trigger: nil)
                try await center.add(request)
            } catch {
                Logger.error("通知投递失败: \(error.localizedDescription)")
            }
        }
    }
}
