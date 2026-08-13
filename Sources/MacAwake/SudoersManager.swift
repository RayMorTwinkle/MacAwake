import Foundation

/// sudoers 白名单管理。
/// 原理：在 /etc/sudoers.d/ 下写一个文件，只允许当前用户免密执行 /usr/bin/pmset。
/// 这样 App 无需每次弹密码，且权限面最小（仅 pmset 一条命令）。
enum SudoersManager {

    static let sudoersPath = "/etc/sudoers.d/macawake"
    static let sudoersContent = "\(NSUserName()) ALL=(root) NOPASSWD: /usr/bin/pmset\n"

    /// sudoers 白名单是否已安装
    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: sudoersPath)
    }

/// 引导安装 sudoers（需要管理员权限，会弹密码框）
/// 用 osascript 以 root 写入文件，保持严格权限 440。
static func install() -> Result<Void, Error> {
        guard !isInstalled else { return .success(()) }

        // 转义用户输入避免注入。NSUserName 通常只有字母数字，但保险起见。
        let username = NSUserName().replacingOccurrences(of: "'", with: "")
        let line = "\(username) ALL=(root) NOPASSWD: /usr/bin/pmset"
        let script = """
        do shell script "printf '%s\\n' '\(line)' > /etc/sudoers.d/macawake && chmod 440 /etc/sudoers.d/macawake && chown root:wheel /etc/sudoers.d/macawake" with administrator privileges
        """

        var error: NSDictionary?
        let appleScript = NSAppleScript(source: script)
        appleScript?.executeAndReturnError(&error)

        if let error = error {
            let msg = error[NSAppleScript.errorMessage] as? String ?? String(localized: "未知错误")
            return .failure(NSError(
                domain: "MacAwake",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: String(format: String(localized: "安装权限失败：%@"), msg)]
            ))
        }

        // 校验安装结果
        guard isInstalled else {
            return .failure(NSError(
                domain: "MacAwake",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: String(localized: "sudoers 文件未写入成功")]
            ))
        }
        return .success(())
    }

    /// 卸载 sudoers（可选，从 App 内不提供，由卸载脚本处理）
    static func uninstall() {
        guard isInstalled else { return }
        let script = "do shell script \"rm -f /etc/sudoers.d/macawake\" with administrator privileges"
        _ = NSAppleScript(source: script)?.executeAndReturnError(nil)
    }
}
