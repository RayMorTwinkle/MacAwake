import AppKit
import SwiftUI

/// 主窗口（侧边栏导航 GUI）。App 仍是 accessory（菜单栏应用），
/// 窗口关闭只藏窗口，App 继续在菜单栏活着。
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private weak var model: AppModel?

    func show(model: AppModel) {
        self.model = model
        model.isWindowVisible = true

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let contentView = MainTabView(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacAwake"
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.isReleasedWhenClosed = false // 复用同一个窗口实例
        window.delegate = self
        window.setFrameAutosaveName("MacAwakeMainWindow")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        model?.isWindowVisible = false // App 列表停止自动刷新（省电）
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model?.isWindowVisible = true
    }
}
