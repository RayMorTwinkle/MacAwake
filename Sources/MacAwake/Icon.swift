import AppKit

/// 菜单栏图标（template 单色，主题自适应）
@MainActor
enum Icon {

    private static func make(_ symbol: String, accessibilityDescription: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        return NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityDescription)!
            .withSymbolConfiguration(config)!
    }

    /// 开启态：实心月亮（SleepDisabled = 1）
    static let moonFilled = make("moon.fill", accessibilityDescription: "on")

    /// 关闭态：线框月亮（默认休眠）
    static let moonOutline = make("moon", accessibilityDescription: "off")

    /// 未知态：月亮加 Z（读取不到状态时显示）
    static let moonQuestion = make("moon.zzz", accessibilityDescription: "unknown")
}
