#!/bin/bash
# MacAwake dmg 打包：创建标准"拖拽安装"镜像（含 Applications 快捷方式）
# 用法: ./scripts/make-dmg.sh [version]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-1.0.0}"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/MacAwake.app"
DMG_NAME="MacAwake-${VERSION}.dmg"
DMG="$BUILD_DIR/$DMG_NAME"

# 先确保 app 已构建
if [ ! -d "$APP" ]; then
    echo "==> 未找到 $APP，先构建"
    ./scripts/build.sh "$VERSION"
fi

echo "==> 创建临时目录"
STAGE="$BUILD_DIR/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"

echo "==> 复制 app 和 Applications 快捷方式"
cp -R "$APP" "$STAGE/MacAwake.app"
ln -s /Applications "$STAGE/Applications"

echo "==> 创建只读 dmg"
# 先创建可写镜像，调整布局，再转只读压缩
TMP_DMG="$BUILD_DIR/_tmp.dmg"
rm -f "$TMP_DMG" "$DMG"

# 计算镜像大小（app 大小 + 20% 余量 + 固定开销）
APP_SIZE=$(du -sk "$APP" | cut -f1)
DMG_SIZE=$(( (APP_SIZE + 4096) * 12 / 10 ))  # 20% 余量

hdiutil create -volname "MacAwake" -srcfolder "$STAGE" \
    -size "${DMG_SIZE}k" -fs HFS+ -format UDRW "$TMP_DMG" >/dev/null

echo "==> 设置窗口布局（App 图标 + Applications 快捷方式）"
# 挂载临时镜像，用 AppleScript 设置 Finder 窗口布局。
# 用 -mountpoint 固定挂载点：若系统已存在同名卷 /Volumes/MacAwake，
# 新卷会被命名为 "MacAwake 1"，按输出文本解析挂载点会取错。
# 注意：挂载后 Finder 以挂载点目录名引用该卷（这里是 "_mount"），
# AppleScript 必须用 "_mount" 而不是 volname "MacAwake"。
MOUNT_POINT="$BUILD_DIR/_mount"
mkdir -p "$MOUNT_POINT"
hdiutil attach "$TMP_DMG" -readwrite -mountpoint "$MOUNT_POINT" >/dev/null
sleep 2

osascript << APPLESCRIPT
tell application "Finder"
    tell disk "_mount"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, 500, 400}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 96
        set position of item "MacAwake.app" of container window to {130, 160}
        set position of item "Applications" of container window to {330, 160}
        close
    end tell
end tell
APPLESCRIPT

echo "==> 卸载并压缩为只读 dmg"
# detach 失败时（镜像被占用）convert 必然报 "Resource busy"，
# 不要吞掉失败继续跑，显式中止让问题可见
hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || {
    echo "ERROR: 无法卸载 $MOUNT_POINT（镜像可能被占用），打包中止"
    exit 1
}
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null

rm -f "$TMP_DMG"
rm -rf "$STAGE"
rmdir "$MOUNT_POINT" 2>/dev/null || true

echo ""
echo "✅ dmg 打包完成:"
echo "  $DMG"
ls -la "$DMG"
