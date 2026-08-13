import AppKit
import MacAwakeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!

    private let powerManager = PowerManager()
    private var state: SleepState = .unknown
    private var isLaunchAtLoginEnabled: Bool {
        SMAppServiceUtil.isEnabled
    }
    private var batteryShowRaw: Bool {
        get { UserDefaults.standard.bool(forKey: "batteryShowRaw") }
        set { UserDefaults.standard.set(newValue, forKey: "batteryShowRaw") }
    }
    private var batteryDisplayText: String {
        batteryShowRaw ? powerManager.batteryRaw : powerManager.batteryInfo
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.info("MacAwake 启动")
        setupStatusItem()
        refreshState()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }

        // 同时捕获左键/右键
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        statusMenu = NSMenu()
        statusMenu.delegate = self

        updateIcon()
    }

    // MARK: - 状态刷新

    func refreshState() {
        state = powerManager.currentState
        updateIcon()
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let image: NSImage
        switch state {
        case .on:
            image = Icon.moonFilled
        case .off:
            image = Icon.moonOutline
        case .unknown:
            image = Icon.moonQuestion
        }
        image.isTemplate = true
        button.image = image
    }

    // MARK: - 点击事件（左/右）

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        // 右键或 Control+点击：直接切换；其余（含 VoiceOver 等不产生鼠标事件的激活）按左键弹菜单
        let isRightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) == true)
        if isRightClick {
            togglePower()
        } else {
            // 刷新由 menuWillOpen 统一处理，避免重复读 pmset
            statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: statusItem.button?.bounds.height ?? 22), in: statusItem.button)
        }
    }

    private func togglePower() {
        refreshState()
        let target: SleepState = (state == .on) ? .off : .on
        let result = powerManager.setSleepDisabled(target == .on)
        switch result {
        case .success:
            refreshState()
        case .failure(let error):
            showError(error.localizedDescription)
        }
    }

    private func showError(_ message: String) {
        Logger.error("操作失败: \(message)")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "操作失败")
        alert.informativeText = message
        alert.runModal()
    }
}

// MARK: - 菜单构建

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        refreshState()  // 打开菜单时动态刷新
        rebuildMenu()
    }

    private func rebuildMenu() {
        statusMenu.removeAllItems()

        let stateTitle: String
        switch state {
        case .on: stateTitle = String(localized: "状态：合盖不休眠（已开启）")
        case .off: stateTitle = String(localized: "状态：合盖休眠（默认）")
        case .unknown: stateTitle = String(localized: "状态：未知")
        }
        let stateItem = NSMenuItem(title: stateTitle, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        statusMenu.addItem(stateItem)

        let powerItem = NSMenuItem(
            title: state == .on ? String(localized: "关闭合盖不休眠")
                                : String(localized: "开启合盖不休眠"),
            action: #selector(togglePowerFromMenu), keyEquivalent: ""
        )
        powerItem.target = self
        statusMenu.addItem(powerItem)

        // 电池 / 电源状态（默认自然语言，点击切换原始输出）
        let batteryItem = NSMenuItem(
            title: "\(String(localized: "电源"))：\(batteryDisplayText)",
            action: #selector(toggleBatteryDisplay), keyEquivalent: ""
        )
        batteryItem.target = self
        statusMenu.addItem(batteryItem)

        statusMenu.addItem(.separator())

        // 开机启动
        let launchItem = NSMenuItem(
            title: String(localized: "开机启动"),
            action: #selector(toggleLaunchAtLogin), keyEquivalent: ""
        )
        launchItem.state = isLaunchAtLoginEnabled ? .on : .off
        launchItem.target = self
        statusMenu.addItem(launchItem)

        statusMenu.addItem(.separator())

        // keyEquivalent 对无主菜单的菜单栏 App 无效（核验确认），留空即可
        let quitItem = NSMenuItem(
            title: String(localized: "退出 MacAwake"),
            action: #selector(quitApp), keyEquivalent: ""
        )
        quitItem.target = self
        statusMenu.addItem(quitItem)
    }

    @objc private func togglePowerFromMenu() {
        togglePower()
    }

    @objc private func toggleBatteryDisplay() {
        batteryShowRaw.toggle()
        rebuildMenu()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try SMAppServiceUtil.toggle()
            rebuildMenu()
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
