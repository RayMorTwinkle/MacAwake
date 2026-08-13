#!/bin/bash
# MacAwake 构建脚本：SwiftPM 编译 + 手工组装 .app + 本地化 + ad-hoc 签名
# 用法: ./scripts/build.sh [version]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-1.0.0}"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/MacAwake.app"
BUNDLE_ID="com.macawake.MacAwake"

echo "==> swift build -c release"
swift build -c release

BIN="$ROOT/.build/release/MacAwake"
[ -x "$BIN" ] || { echo "缺少构建产物: $BIN"; exit 1; }

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/MacAwake"

# 本地化资源
for lang in zh-Hans en; do
    if [ -d "$ROOT/Sources/MacAwake/Resources/$lang.lproj" ]; then
        mkdir -p "$APP/Contents/Resources/$lang.lproj"
        cp "$ROOT/Sources/MacAwake/Resources/$lang.lproj/"*.strings "$APP/Contents/Resources/$lang.lproj/"
    fi
done

# 图标（如有）
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    HAS_ICON=1
else
    HAS_ICON=0
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>MacAwake</string>
    <key>CFBundleDisplayName</key>       <string>MacAwake</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>MacAwake</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>13.0</string>
    <key>LSUIElement</key>               <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key>   <true/>
</dict>
</plist>
PLIST
if [ "$HAS_ICON" = "1" ]; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi

echo "==> ad-hoc 签名"
codesign --force --sign - --timestamp=none "$APP" >/dev/null
codesign --verify --strict "$APP" && echo "    签名校验通过"

echo ""
echo "构建完成:"
echo "  App: $APP"
echo ""
echo "运行: open $APP"
echo "卸载 sudoers: sudo rm -f /etc/sudoers.d/macawake"
