<div align="center">

<img src="Resources/logo.png" alt="MacAwake" width="128">

# 🌙 MacAwake

**MacBook 合盖不休眠菜单栏工具** · Keep your MacBook awake with the lid closed

轻量、开源、单文件的 macOS 菜单栏应用，一键切换「合盖后是否休眠」。
A lightweight open-source macOS menu bar app that toggles lid-closed sleep with one click.

![Platform](https://img.shields.io/badge/macOS-13%2B-blue) ![License](https://img.shields.io/badge/License-GPL--3.0-green) ![Swift](https://img.shields.io/badge/Swift-6-orange) ![Size](https://img.shields.io/badge/Size-~135KB-brightgreen)

</div>

---

## ✨ 功能 / Features

- 🌙 **状态栏图标显示当前状态**：实心月亮 = 合盖不休眠（已开启）；线框月亮 = 合盖休眠（默认）
  - Menu bar icon reflects current state: filled moon = lid-sleep disabled; outline moon = default
- 🖱️ **左键**打开菜单查看/操作；**右键**直接切换
  - Left-click opens the menu; right-click toggles immediately
- ⏱️ **定时恢复休眠**：30 分钟 / 1 小时 / 2 小时 / 4 小时 / 自定义（`90`、`45m`、`1h30m`）/ 不限时；到点恢复休眠并可强制立即睡眠
  - Auto-restore sleep after 30m / 1h / 2h / 4h / custom / no limit
- 🛡️ **漂移自愈**：每 ~2 秒核对一次系统值（IOKit 进程内读取，不 fork），被别的程序改回去会自动重新施加，并在菜单里显示被改了几次
  - Self-healing: re-asserts the setting if another app rewrites it
- 🔋 **电池状态人性化显示**（点击可在自然语言 / 原始输出间切换）
  - Human-readable battery info (click to toggle raw output)
- 🚀 **可选开机启动**
  - Optional "Launch at Login"
- 📝 **本地化**：中文 / English（自动跟随系统语言）
  - Localized: 中文 / English (auto-detects system language)
- 🔒 **最小权限**：只在首次使用时请求一次管理员密码（安装 sudoers 白名单，仅放行 `pmset` 一条命令）

---

## 📦 安装 / Install

### 方式一：下载 Release 包（.dmg）

1. 从 [Releases](https://github.com/RayMorTwinkle/MacAwake/releases) 下载最新的 `MacAwake-<版本>.dmg`
2. 打开 dmg，把 `MacAwake.app` 拖进 `Applications` 文件夹
3. 因为 App 是 ad-hoc 签名（未公证），首次运行需要**一条命令解除拦截**：

```bash
xattr -dr com.apple.quarantine /Applications/MacAwake.app && open /Applications/MacAwake.app
```

> 为什么需要这一步？App 未使用付费的 Apple Developer ID 签名，macOS Gatekeeper 会拦截未公证的应用。这条命令只移除下载标记，**不需要管理员密码**，且只影响本 App。

### 方式二：从源码编译

```bash
git clone https://github.com/RayMorTwinkle/MacAwake.git
cd MacAwake
./scripts/build.sh
open build/MacAwake.app
```

需要 macOS 13+ 和 Swift 工具链（`xcode-select --install` 即可）。

---

## 🚀 首次使用 / First Launch

点击菜单栏月亮图标 → 点「开启合盖不休眠」→ **系统会弹一次管理员密码框**。

这是**唯一一次**需要输入密码的地方。App 会在 `/etc/sudoers.d/macawake` 安装一条**白名单规则**，只允许当前用户免密执行 `pmset` 这一条命令（其余命令仍需密码）。之后所有开关操作都免密、无弹窗。

> **安全说明**：合盖不休眠是系统级电源设置（`pmset disablesleep`），必须 root 权限。
> 我们采用**最小权限**方案：sudoers 白名单精确匹配 `pmset` 命令，不安装常驻守护进程，无后台服务。
> 这是 macOS 同类工具（Amphetamine、Sleepless 等）的通行做法。

**卸载授权**（恢复"合盖自动休眠"，也删除 sudoers 权限）：

```bash
# 先退出 MacAwake，否则运行中的 App 会把 disablesleep 自愈回 1
# 恢复休眠
sudo pmset -a disablesleep 0

# 移除 sudoers 白名单（可选，卸载 App 时建议执行）
sudo rm -f /etc/sudoers.d/macawake
```

---

## 🔍 使用 / Usage

| 操作 | 效果 |
|---|---|
| 右键点击菜单栏图标 | 直接切换 合盖不休眠 ⇄ 合盖休眠 |
| 左键点击菜单栏图标 | 打开菜单，显示状态 + 开关 + 定时 + 电源信息 |
| 菜单 → 定时恢复休眠 | 选 30 分钟 / 1 小时 / 2 小时 / 4 小时 / 自定义… / 不限时 |
| 菜单 → 定时恢复休眠 → 延长 30 分钟 | 定时会话未到点时顺延（仅定时会话可见） |
| 菜单 → 定时恢复休眠 → 到点后强制睡眠 | 到点是「立刻睡」还是「回到系统正常休眠规则」，默认立刻睡 |
| 菜单 → 电源行 | 点击在「电量 28% 放电中 剩余约1小时」和原始输出间切换 |
| 菜单 → 开机启动 | 开关开机自启 |

日志（用于排查问题）：`~/Library/Logs/MacAwake/MacAwake.log`

### 行为约定 / Semantics

- **重启后沿用系统当前值**：`pmset` 本来就是跨重启持久的，所以重启后如果系统值仍是 1，App 会继续维护这个会话，并弹一条通知告知。带到期时间的定时若在 App 未运行期间已过期，启动时会直接恢复休眠（不会变成"永远不休眠"）。
- **退出 App**：定时会话会被释放（定时承诺无法兑现，属于失效安全）；不限时会话保持 —— 这样退出 App 不会莫名其妙改掉你的设置。
- **App 运行期间，外部把 `disablesleep` 改成 0 会被自动改回 1**。要真正关掉，请用菜单里的「关闭合盖不休眠」，或先退出 App 再执行 `sudo pmset -a disablesleep 0`。

---

## ⚠️ 注意事项 / Notes

- **合盖不休眠会持续耗电和发热**。请把电脑放在通风、坚硬的表面；不要把电脑合盖后塞进包里运行。
- 该设置在**重启后依然生效**（`pmset` 是持久配置）。用完记得关闭，或执行恢复命令。
- 本 App 仅限 **自用 / 局域网分发**。若要做正式商业分发，需 Apple Developer ID 签名 + 公证。

### 已知冲突：其他电源工具会把设置改回去 / Known conflict

`SleepDisabled` 是**全系统共用**的一项电源配置，任何用 `pmset` 写电源配置的程序都会连带重写它。

本机实测（macOS 15.3.1 / M1 Max）：**AlDente Pro** 每 10 分钟用 `pmset` 重写一次 Energy Saver 配置，把 `SleepDisabled` 清回 0。用户看到的现象就是「开启合盖不休眠后，只有第一次合盖有效，第二次又恢复原状」。

新版 MacAwake 会在 ~2 秒内自动改回 1，并在菜单里显示「⚠️ 已被外部修改 N 次，已自动恢复」。如果你看到这个提示，说明有别的工具在抢这项设置。

想确认是谁干的：

```bash
# 看最近 10 分钟有哪些进程在跑 pmset（每 10 分钟一次的定时任务最容易认出来）
log show --last 10m --predicate 'process == "pmset"' --style compact | grep activating

# 看电源配置被重写的时刻
log show --last 10m --predicate 'eventMessage CONTAINS "Energy Saver Prefs"' --style compact
```

缓解办法（二选一）：在冲突工具里关掉相关的自动化（例如 AlDente 的 Energy Mode 自动切换 / 「完全禁用睡眠」），或者接受自愈 —— 两者的写入周期不同，MacAwake 的 2 秒轮询会稳定赢，不会来回抖动。

---

## 🛠️ 开发 / Development

```
MacAwake/
├── Sources/MacAwakeCore/     # 纯逻辑（无 IO，可单测）
│   ├── PowerParsing.swift    # pmset 输出解析
│   ├── Session.swift         # 会话模型 + 收敛决策引擎 + 重启检测
│   └── Duration.swift        # 时长解析（90 / 45m / 1h30m）与拆解
├── Sources/MacAwake/         # 带 IO 的 App 层
│   ├── main.swift            # 入口
│   ├── AppDelegate.swift     # 菜单栏 UI
│   ├── SessionController.swift   # 意图持久化 + 漂移自愈 + 定时器 + 退出失效安全
│   ├── PowerStateReader.swift    # IOKit 进程内读 SleepDisabled（不 fork）
│   ├── PowerManager.swift    # pmset 写入 / 回读校验 / sleepnow
│   ├── Notifier.swift        # 系统通知
│   ├── SudoersManager.swift  # sudoers 白名单管理
│   ├── SMAppServiceUtil.swift # 开机启动
│   ├── Icon.swift            # 菜单栏图标
│   └── Logger.swift          # 日志
├── Tests/MacAwakeTests/      # 自建断言 harness（CLT 环境无 XCTest）
├── Resources/                # 图标源文件
├── scripts/
│   ├── build.sh            # 构建 .app（SwiftPM + 组装 + ad-hoc 签名）
│   ├── run-tests.sh        # 单元测试
│   ├── make-optimized-icon.sh # SVG → 优化 icns（pngquant 压缩）
│   └── make-dmg.sh         # 打包 .dmg
└── Package.swift
```

构建：
```bash
./scripts/run-tests.sh          # 单元测试
./scripts/build.sh 1.2.0        # 构建 .app
./scripts/make-dmg.sh 1.2.0     # 打包 .dmg
```

---

## ❓ 常见问题 / FAQ

**Q：开启后第一次合盖有效，第二次合盖又睡了？**
A：v1.1.3 及更早版本存在这个 Bug —— 别的程序用 `pmset` 重写电源配置时把 `SleepDisabled` 清回了 0（本机实测是 AlDente Pro，每 10 分钟一次），而旧版把「系统当前值」当成了「用户意图」，被改掉后自己也不知道。v1.2.0 起由 App 持有意图并持续收敛，会自动改回来。详见下面的「已知冲突」。

**Q：菜单显示「已开启」，但 `pmset -g` 读出来是 0？**
A：正常情况下 App 会在 ~2 秒内改回 1。若长期不是 1，配合菜单里的「⚠️ 已被外部修改 N 次」和日志排查（多半是 sudoers 白名单失效 —— 重新开关一次会重新引导安装）。

**Q：我想手动关掉，为什么 `sudo pmset -a disablesleep 0` 会被改回去？**
A：App 运行期间这就是设计行为（否则别的程序清掉它也没人管）。请用菜单里的「关闭合盖不休眠」，或先退出 App 再执行命令。

---

## 📝 更新日志 / Changelog

### v1.2.0
- 🐛 **修复「开启后只有第一次合盖有效，第二次又睡了」**：根因是其他电源工具周期性用 `pmset` 重写 Energy Saver 配置，连带把 `SleepDisabled` 清回 0。新版把「用户意图」与「系统当前值」分离，**每 ~2 秒核对一次，发现漂移立刻重新施加**（IOKit 进程内读取，不 fork；写路径仍是 `pmset` + sudoers 白名单）
- ✨ 新增**定时恢复休眠**：30 分钟 / 1 小时 / 2 小时 / 4 小时 / 自定义（`90`、`45m`、`1h30m`，1 分钟–24 小时）/ 不限时，支持「延长 30 分钟」，到点恢复休眠并强制立即睡眠（可在子菜单里关掉）
- ✨ 重启后沿用系统当前值并弹一条通知；退出 App 时定时会话按失效安全释放
- 📋 菜单显示「⚠️ 已被外部修改 N 次，已自动恢复」，让漂移可见
- ✅ 61 项单元测试通过；真机验证：注入外部改写后 **~2 秒**自愈

### v1.1.3
- 插电未充电时显示「外接电源」，与非插电场景的误报兜底

### v1.1.2
- 不再覆盖用户原有的 `sleep` 设置，等 16 项审查修复

### v1.1.1
- 首个版本：一键切换合盖休眠 + 电池信息 + 开机启动 + 中英双语

---

## 📄 License

[GPL-3.0](LICENSE)

---

## 🙏 致谢 / Credits

- 图标中的 MacBook 轮廓下载自 [SVG Repo](https://www.svgrepo.com/)（CC0 License，已重新配色并用于 App 图标）
- 参考项目：[LidAwake](https://github.com/NeoSpecies/LidAwake)（功能启发，代码独立实现）
