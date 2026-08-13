import AppKit

// MacAwake 入口
// LSUIElement = YES（Info.plist），无 Dock 图标，纯菜单栏应用
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
