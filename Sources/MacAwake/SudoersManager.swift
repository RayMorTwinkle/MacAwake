import Foundation

/// sudoers 白名单管理。
/// 原理：在 /etc/sudoers.d/ 下写一个文件，只允许当前用户免密执行 /usr/bin/pmset。
/// 这样 App 无需每次弹密码，且权限面最小（仅 pmset 一条命令）。
enum SudoersManager {

    static let sudoersPath = "/etc/sudoers.d/macawake"

    /// sudoers 白名单是否已正确安装。
    /// sudo 会静默忽略属主/权限不合规的 sudoers.d 文件（只打一条警告），
    /// 所以"文件存在"不等于"规则生效"——属主非 root 或组/全局可写时视为未安装，
    /// 以便 install() 重写修复，否则 App 会永远卡在"sudo 免密失败"上无法自愈。
    static var isInstalled: Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: sudoersPath) else { return false }
        let owner = (attrs[.ownerAccountID] as? NSNumber)?.intValue
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        return owner == 0 && (perms & 0o022) == 0
    }

    /// 引导安装 sudoers（需要管理员权限，会弹密码框）
    /// 用 osascript 以 root 写入文件，保持严格权限 440。
    static func install() -> Result<Void, Error> {
        guard !isInstalled else { return .success(()) }

        // 剔除可能破坏 AppleScript 字符串/shell 单引号的字符。
        // NSUserName 通常只有字母数字，但保险起见。
        let username = NSUserName()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
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
}
