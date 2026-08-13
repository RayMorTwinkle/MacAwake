import Foundation
import ServiceManagement

/// 开机启动管理（SMAppService.mainApp）。
/// 部署目标为 macOS 13.0（Package.swift），API 恒可用。
enum SMAppServiceUtil {

    /// 当前是否已注册开机启动
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 切换开机启动状态
    static func toggle() throws {
        if isEnabled {
            try SMAppService.mainApp.unregister()
        } else {
            try SMAppService.mainApp.register()
        }
    }
}
