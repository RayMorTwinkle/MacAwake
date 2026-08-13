<div align="center">

# 🌙 MacAwake

**MacBook 合盖不休眠菜单栏工具** · Keep your MacBook awake with the lid closed

轻量、开源、单文件的 macOS 菜单栏应用，一键切换「合盖后是否休眠」。
A lightweight open-source macOS menu bar app that toggles lid-closed sleep with one click.

![Platform](https://img.shields.io/badge/macOS-13%2B-blue) ![License](https://img.shields.io/badge/License-GPL--3.0-green) ![Swift](https://img.shields.io/badge/Swift-6-orange) ![Size](https://img.shields.io/badge/Size-~220KB-brightgreen)

</div>

---

## ✨ 功能 / Features

- 🌙 **状态栏图标显示当前状态**：实心月亮 = 合盖不休眠（已开启）；线框月亮 = 合盖休眠（默认）
  - Menu bar icon reflects current state: filled moon = lid-sleep disabled; outline moon = default
- 🖱️ **左键**打开菜单查看/操作；**右键**直接切换
  - Left-click opens the menu; right-click toggles immediately
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
| 左键点击菜单栏图标 | 打开菜单，显示状态 + 开关 + 电源信息 |
| 菜单 → 电源行 | 点击在「电量 28% 放电中 剩余约1小时」和原始输出间切换 |
| 菜单 → 开机启动 | 开关开机自启 |

日志（用于排查问题）：`~/Library/Logs/MacAwake/MacAwake.log`

---

## ⚠️ 注意事项 / Notes

- **合盖不休眠会持续耗电和发热**。请把电脑放在通风、坚硬的表面；不要把电脑合盖后塞进包里运行。
- 该设置在**重启后依然生效**（`pmset` 是持久配置）。用完记得关闭，或执行恢复命令。
- 本 App 仅限 **自用 / 局域网分发**。若要做正式商业分发，需 Apple Developer ID 签名 + 公证。

---

## 🛠️ 开发 / Development

```
MacAwake/
├── Sources/MacAwake/       # Swift 源码
│   ├── main.swift          # 入口
│   ├── AppDelegate.swift   # 菜单栏控制
│   ├── PowerManager.swift  # 电源状态读写
│   ├── SudoersManager.swift# sudoers 白名单管理
│   ├── SMAppServiceUtil.swift # 开机启动
│   ├── Icon.swift          # 菜单栏图标
│   └── Logger.swift        # 日志
├── Resources/              # 图标源文件
├── scripts/
│   ├── build.sh            # 构建 .app（SwiftPM + 组装 + ad-hoc 签名）
│   ├── make-optimized-icon.sh # SVG → 优化 icns（pngquant 压缩）
│   └── make-dmg.sh         # 打包 .dmg
└── Package.swift
```

构建：
```bash
./scripts/build.sh 1.0.0        # 构建 .app
./scripts/make-dmg.sh 1.0.0     # 打包 .dmg
```

---

## 📄 License

[GPL-3.0](LICENSE)

---

## 🙏 致谢 / Credits

- 图标中的 MacBook 轮廓下载自 [SVG Repo](https://www.svgrepo.com/)（CC0 License，已重新配色并用于 App 图标）
- 参考项目：[LidAwake](https://github.com/NeoSpecies/LidAwake)（功能启发，代码独立实现）
