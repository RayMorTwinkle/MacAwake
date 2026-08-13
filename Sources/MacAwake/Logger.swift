import Foundation

/// 轻量日志工具：写入 ~/Library/Logs/MacAwake/MacAwake.log
/// 方便排查问题（每次开关操作、错误详情都会记录）。
enum Logger {
    static let logDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MacAwake")
    static let logFile = logDir.appendingPathComponent("MacAwake.log")

    /// 确保日志目录存在
    private static func ensureDir() {
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    }

    /// 写入一行日志（时间戳 + 级别 + 消息）
    static func log(_ level: String, _ message: String) {
        ensureDir()
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] [\(level)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logFile) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                handle.write(data)
            } else {
                // 文件不存在 → 直接创建
                try? data.write(to: logFile)
            }
        }
    }

    /// 信息日志
    static func info(_ message: String) { log("INFO", message) }

    /// 错误日志
    static func error(_ message: String) { log("ERROR", message) }
}
