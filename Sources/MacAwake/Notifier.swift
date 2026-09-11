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
    static func post(title: String, body: String) {
        Logger.info("通知: \(title) — \(body)")

        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()

        func deliver() {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                               content: content,
                                               trigger: nil)
            center.add(request) { error in
                if let error { Logger.error("通知投递失败: \(error.localizedDescription)") }
            }
        }

        if didRequestAuthorization {
            deliver()
            return
        }
        didRequestAuthorization = true
        center.requestAuthorization(options: [.alert]) { granted, error in
            if let error { Logger.error("通知授权失败: \(error.localizedDescription)") }
            guard granted else {
                Logger.info("通知未授权，仅记录日志")
                return
            }
            Task { @MainActor in deliver() }
        }
    }
}
