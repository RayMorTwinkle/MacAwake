import AppKit
import MacAwakeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {

    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!

    private let powerManager = PowerManager()
    private let controller = SessionController()

    /// 菜单展开时缓存电池文案：重建菜单不能每次都 fork `pmset -g batt`
    private var cachedBatteryText = ""

    private var isLaunchAtLoginEnabled: Bool {
        SMAppServiceUtil.isEnabled
    }

    /// "对用户来说算不算开着"：会话存在，或系统值仍为 1（外部开启的情况）
    private var isEffectivelyOn: Bool {
        controller.session != nil || controller.systemState == .on
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

        controller.onSnapshotChange = { [weak self] in self?.updateIcon() }
        controller.onEvent = { [weak self] event in self?.handle(event) }
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.releaseOnQuit()
        controller.stop()
        Logger.info("MacAwake 退出")
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

    // MARK: - 图标

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let image: NSImage
        if controller.session != nil || controller.systemState == .on {
            image = Icon.moonFilled
        } else if controller.systemState == .off {
            image = Icon.moonOutline
        } else {
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
            statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: statusItem.button?.bounds.height ?? 22), in: statusItem.button)
        }
    }

    private func togglePower() {
        if isEffectivelyOn {
            controller.turnOff()
        } else {
            controller.turnOn(duration: nil)
        }
    }

    // MARK: - 会话事件提示

    private func handle(_ event: SessionController.Event) {
        switch event {
        case .rebootAdopted(let sleepDisabled):
            Notifier.post(title: "MacAwake",
                          body: sleepDisabled
                              ? String(localized: "检测到重启，已沿用系统当前设置：合盖不休眠")
                              : String(localized: "检测到重启，当前为合盖休眠（默认）"))
        case .missedDeadline:
            Notifier.post(title: "MacAwake", body: String(localized: "上次定时已过期，已恢复合盖休眠"))
        case .timerExpired(let forcedSleep):
            Notifier.post(title: "MacAwake",
                          body: forcedSleep
                              ? String(localized: "定时到点：已恢复合盖休眠并强制睡眠")
                              : String(localized: "定时到点：已恢复合盖休眠"))
        case .driftRepaired:
            // 外部改写可能反复发生，不进系统通知（避免刷屏），只在菜单与日志里体现
            break
        }
    }

    private func showError(_ message: String) {
        Logger.error("操作失败: \(message)")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "操作失败")
        alert.informativeText = message
        alert.runModal()
    }

    // MARK: - 菜单动作

    @objc private func togglePowerFromMenu() {
        togglePower()
    }

    /// 定时菜单项：representedObject 是秒数
    @objc private func startPresetDuration(_ sender: NSMenuItem) {
        guard let seconds = (sender.representedObject as? NSNumber)?.doubleValue else { return }
        controller.turnOn(duration: seconds)
    }

    @objc private func startUntimed() {
        controller.turnOn(duration: nil)
    }

    @objc private func extendThirtyMinutes() {
        controller.extend(by: 30 * 60)
    }

    @objc private func toggleForceSleep() {
        controller.forceSleepOnExpiry.toggle()
    }

    @objc private func askCustomDuration() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = String(localized: "自定义时长")
        alert.informativeText = String(localized: "输入 1 分钟 – 24 小时，例如 90、45m、1h30m")
        alert.addButton(withTitle: String(localized: "确定"))
        alert.addButton(withTitle: String(localized: "取消"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "45m"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let seconds = DurationFormat.parse(field.stringValue) else {
            showError(String(localized: "请输入 1 分钟到 24 小时之间的时长（例如 90、45m、1h30m）"))
            return
        }
        controller.turnOn(duration: seconds)
    }

    @objc private func toggleBatteryDisplay() {
        batteryShowRaw.toggle()
        cachedBatteryText = batteryDisplayText
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

    // MARK: - 文案

    private func remainingText(_ seconds: TimeInterval) -> String {
        let (hours, minutes) = DurationFormat.decomposeRemaining(seconds)
        if hours > 0 {
            return String(format: String(localized: "剩余 %d 小时 %d 分"), hours, minutes)
        }
        return String(format: String(localized: "剩余 %d 分钟"), minutes)
    }
}

// MARK: - 菜单构建

extension AppDelegate: NSMenuDelegate {

    func menuWillOpen(_ menu: NSMenu) {
        controller.reconcileNow()                                    // 打开菜单顺手收敛一次（发现漂移立即修复）
        cachedBatteryText = batteryDisplayText
        rebuildMenu()
    }

    private func rebuildMenu() {
        statusMenu.removeAllItems()

        // 1. 状态
        let stateTitle: String
        if let session = controller.session {
            if let remaining = session.remaining(now: Date()) {
                stateTitle = "\(String(localized: "状态：合盖不休眠")) · \(remainingText(remaining))"
            } else {
                stateTitle = String(localized: "状态：合盖不休眠（不限时）")
            }
        } else if controller.systemState == .on {
            stateTitle = String(localized: "状态：合盖不休眠（已开启）")
        } else if controller.systemState == .off {
            stateTitle = String(localized: "状态：合盖休眠（默认）")
        } else {
            stateTitle = String(localized: "状态：未知")
        }
        let stateItem = NSMenuItem(title: stateTitle, action: nil, keyEquivalent: "")
        stateItem.isEnabled = false
        statusMenu.addItem(stateItem)

        // 1b. 漂移提示（外部改写被自动修复的次数）
        if controller.driftRepairCount > 0 {
            let driftItem = NSMenuItem(
                title: "⚠️ " + String(format: String(localized: "已被外部修改 %d 次，已自动恢复"), controller.driftRepairCount),
                action: nil, keyEquivalent: ""
            )
            driftItem.isEnabled = false
            statusMenu.addItem(driftItem)
        }

        // 2. 开关
        let powerItem = NSMenuItem(
            title: isEffectivelyOn ? String(localized: "关闭合盖不休眠")
                                   : String(localized: "开启合盖不休眠"),
            action: #selector(togglePowerFromMenu), keyEquivalent: ""
        )
        powerItem.target = self
        statusMenu.addItem(powerItem)

        // 3. 定时恢复休眠
        statusMenu.addItem(buildTimerMenu())

        // 4. 电池 / 电源状态（默认自然语言，点击切换原始输出）
        let batteryItem = NSMenuItem(
            title: "\(String(localized: "电源"))：\(cachedBatteryText)",
            action: #selector(toggleBatteryDisplay), keyEquivalent: ""
        )
        batteryItem.target = self
        statusMenu.addItem(batteryItem)

        statusMenu.addItem(.separator())

        // 5. 开机启动
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

    /// 定时恢复休眠子菜单
    private func buildTimerMenu() -> NSMenuItem {
        let root = NSMenuItem(title: String(localized: "定时恢复休眠"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let presets: [(String, TimeInterval)] = [
            (String(localized: "30 分钟"), 30 * 60),
            (String(localized: "1 小时"), 60 * 60),
            (String(localized: "2 小时"), 2 * 60 * 60),
            (String(localized: "4 小时"), 4 * 60 * 60),
        ]
        for (title, seconds) in presets {
            let item = NSMenuItem(title: title, action: #selector(startPresetDuration(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: seconds)
            submenu.addItem(item)
        }

        let customItem = NSMenuItem(title: String(localized: "自定义…"), action: #selector(askCustomDuration), keyEquivalent: "")
        customItem.target = self
        submenu.addItem(customItem)

        submenu.addItem(.separator())

        let untimedItem = NSMenuItem(title: String(localized: "不限时"), action: #selector(startUntimed), keyEquivalent: "")
        untimedItem.target = self
        if let session = controller.session, !session.isTimed {
            untimedItem.state = .on
        }
        submenu.addItem(untimedItem)

        if controller.session?.isTimed == true {
            let extendItem = NSMenuItem(title: String(localized: "延长 30 分钟"), action: #selector(extendThirtyMinutes), keyEquivalent: "")
            extendItem.target = self
            submenu.addItem(extendItem)
        }

        submenu.addItem(.separator())

        let forceItem = NSMenuItem(title: String(localized: "到点后强制睡眠"), action: #selector(toggleForceSleep), keyEquivalent: "")
        forceItem.target = self
        forceItem.state = controller.forceSleepOnExpiry ? .on : .off
        submenu.addItem(forceItem)

        root.submenu = submenu
        return root
    }
}
