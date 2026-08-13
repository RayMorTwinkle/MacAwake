// swift-tools-version:6.0
import PackageDescription

// MacAwake — 合盖不休眠菜单栏工具
let package = Package(
    name: "MacAwake",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "MacAwakeCore",
            path: "Sources/MacAwakeCore"
        ),
        .executableTarget(
            name: "MacAwake",
            dependencies: ["MacAwakeCore"],
            path: "Sources/MacAwake"
        ),
        .executableTarget(
            name: "MacAwakeTests",
            dependencies: ["MacAwakeCore"],
            path: "Tests/MacAwakeTests"
        )
    ]
)
