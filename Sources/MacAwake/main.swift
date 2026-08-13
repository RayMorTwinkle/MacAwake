import AppKit

// MacAwake 入口
// LSUIElement = YES（Info.plist），无 Dock 图标，纯菜单栏应用
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// 单实例保护：已有另一实例在运行则直接退出，避免出现两个状态栏图标
let myPID = ProcessInfo.processInfo.processIdentifier
let others = NSRunningApplication
    .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    .filter { $0.processIdentifier != myPID }
if !others.isEmpty {
    exit(0)
}

app.run()
