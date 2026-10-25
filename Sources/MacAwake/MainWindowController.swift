import AppKit
import SwiftUI

/// 主窗口（GUI 四标签页）。App 仍是 accessory（菜单栏应用），
/// 窗口关闭只藏窗口，App 继续在菜单栏活着。
@MainActor
final class MainWindowController {

    private var window: NSWindow?

    func show(model: AppModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = MainTabView(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacAwake"
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.isReleasedWhenClosed = false // 复用同一个窗口实例
        window.setFrameAutosaveName("MacAwakeMainWindow")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}
