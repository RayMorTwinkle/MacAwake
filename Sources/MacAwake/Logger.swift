import Foundation

/// 轻量日志工具：写入 ~/Library/Logs/MacAwake/MacAwake.log
/// 方便排查问题（每次开关操作、错误详情都会记录）。
/// 超过 100KB 时轮转为 MacAwake.log.old（只保留一代）。
enum Logger {
    static let logDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MacAwake")
    static let logFile = logDir.appendingPathComponent("MacAwake.log")
    static let maxLogSize: UInt64 = 100 * 1024

    /// 确保日志目录存在
    private static func ensureDir() {
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    }

    /// 超过上限时把当前日志轮转为 .old（覆盖上一代）
    private static func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logFile.path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              size > maxLogSize else { return }
        try? FileManager.default.removeItem(atPath: logFile.path + ".old")
        try? FileManager.default.moveItem(atPath: logFile.path, toPath: logFile.path + ".old")
    }

    /// 写入一行日志（时间戳 + 级别 + 消息），只追加、不覆盖
    static func log(_ level: String, _ message: String) {
        ensureDir()
        rotateIfNeeded()
        let line = "[\(Date().formatted(.iso8601))] [\(level)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: logFile) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            handle.write(data)
        }
    }

    /// 信息日志
    static func info(_ message: String) { log("INFO", message) }

    /// 错误日志
    static func error(_ message: String) { log("ERROR", message) }
}
