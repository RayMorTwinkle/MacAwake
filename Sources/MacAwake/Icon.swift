import AppKit

/// 菜单栏图标（template 单色，主题自适应）
@MainActor
enum Icon {

    /// 开启态：实心月亮（SleepDisabled = 1）
    static let moonFilled: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        return NSImage(systemSymbolName: "moon.fill", accessibilityDescription: "on")!
            .withSymbolConfiguration(config)!
    }()

    /// 关闭态：线框月亮（默认休眠）
    static let moonOutline: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        return NSImage(systemSymbolName: "moon", accessibilityDescription: "off")!
            .withSymbolConfiguration(config)!
    }()

    /// 未知态：带问号的月亮
    static let moonQuestion: NSImage = {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        return NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: "unknown")!
            .withSymbolConfiguration(config)!
    }()
}
