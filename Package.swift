// swift-tools-version:6.0
import PackageDescription

// MacAwake — 合盖不休眠菜单栏工具
let package = Package(
    name: "MacAwake",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MacAwake",
            path: "Sources/MacAwake"
        )
    ]
)
