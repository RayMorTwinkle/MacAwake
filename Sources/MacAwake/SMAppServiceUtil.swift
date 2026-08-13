import Foundation
import ServiceManagement

/// 开机启动管理（SMAppService.mainApp，macOS 13+）
enum SMAppServiceUtil {

    /// 当前是否已注册开机启动
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    /// 切换开机启动状态
    static func toggle() throws {
        if #available(macOS 13.0, *) {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } else {
            throw NSError(
                domain: "MacAwake",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "开机启动需要 macOS 13 或更高版本")]
            )
        }
    }
}
