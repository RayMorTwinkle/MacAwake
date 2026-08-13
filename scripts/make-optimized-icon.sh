#!/bin/bash
# 生成优化版 AppIcon.icns：
# 1. SVG → 1024 PNG（qlmanage + Swift 修正透明）
# 2. sips 缩放 10 个尺寸
# 3. pngquant 量化每张 PNG（256 色，保留质量）
# 4. 直接组装 icns（绕过 iconutil，避免二次膨胀）
# 依赖：pngquant（brew install pngquant）、swiftc
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RES="$ROOT/Resources"
WORK="/tmp/macawake-icon"
ICONSET="$RES/AppIcon.iconset"

echo "==> 渲染 SVG → 1024 PNG"
rm -rf "$WORK" "$ICONSET"
mkdir -p "$WORK" "$ICONSET"

# qlmanage 渲染（会把背景垫白）
qlmanage -t -s 1024 -o "$WORK" "$RES/app-icon.svg" >/dev/null 2>&1 || { echo "qlmanage 失败"; exit 1; }
RAW_PNG="$WORK/app-icon.svg.png"
[ -f "$RAW_PNG" ] || RAW_PNG="$WORK/$(basename "$RES/app-icon.svg").png"

# Swift + CoreGraphics 裁圆角 + 透明背景
cat > "$WORK/fix_alpha.swift" << 'SWIFT'
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let input = CommandLine.arguments[1]
let output = CommandLine.arguments[2]

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: input) as CFURL, nil),
      let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    fatalError("无法读取源图")
}

let W = img.width, H = img.height
let wf = CGFloat(W), hf = CGFloat(H)
let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
                          bytesPerRow: 0, space: colorSpace,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("无法创建上下文")
}
ctx.interpolationQuality = .high
// 圆角蒙版（rx = 228/1024 比例）
let corner = wf * 228.0 / 1024.0
ctx.beginPath()
ctx.move(to: CGPoint(x: corner, y: 0))
ctx.addLine(to: CGPoint(x: wf - corner, y: 0))
ctx.addArc(tangent1End: CGPoint(x: wf, y: 0), tangent2End: CGPoint(x: wf, y: corner), radius: corner)
ctx.addLine(to: CGPoint(x: wf, y: hf - corner))
ctx.addArc(tangent1End: CGPoint(x: wf, y: hf), tangent2End: CGPoint(x: wf - corner, y: hf), radius: corner)
ctx.addLine(to: CGPoint(x: corner, y: hf))
ctx.addArc(tangent1End: CGPoint(x: 0, y: hf), tangent2End: CGPoint(x: 0, y: hf - corner), radius: corner)
ctx.addLine(to: CGPoint(x: 0, y: corner))
ctx.addArc(tangent1End: CGPoint(x: 0, y: 0), tangent2End: CGPoint(x: corner, y: 0), radius: corner)
ctx.closePath()
ctx.clip()
ctx.draw(img, in: CGRect(x: 0, y: 0, width: wf, height: hf))

guard let out = ctx.makeImage() else { fatalError("无法生成输出图") }
let url = URL(fileURLWithPath: output) as CFURL
guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("无法创建目标")
}
CGImageDestinationAddImage(dest, out, nil)
CGImageDestinationFinalize(dest)
SWIFT
swiftc "$WORK/fix_alpha.swift" -o "$WORK/fix_alpha" 2>/dev/null || { echo "swiftc 失败"; exit 1; }
"$WORK/fix_alpha" "$RAW_PNG" "$WORK/icon-1024.png"
echo "    1024 PNG: $(ls -la "$WORK/icon-1024.png" | awk '{print $5}') bytes"

echo "==> sips 缩放 10 个尺寸"
# 定义 尺寸名:像素
declare -a SIZES=(
  "icon_16x16.png:16" "icon_16x16@2x.png:32"
  "icon_32x32.png:32" "icon_32x32@2x.png:64"
  "icon_128x128.png:128" "icon_128x128@2x.png:256"
  "icon_256x256.png:256" "icon_256x256@2x.png:512"
  "icon_512x512.png:512" "icon_512x512@2x.png:1024"
)
for entry in "${SIZES[@]}"; do
  name="${entry%%:*}"
  px="${entry##*:}"
  sips -z "$px" "$px" "$WORK/icon-1024.png" --out "$ICONSET/$name" >/dev/null 2>&1
done
echo "    10 个尺寸生成完成"

echo "==> pngquant 量化（256 色）"
# pngquant 失败（缺失/坏图）必须显式中止：位于 && 链非末尾的命令
# 失败不会触发 set -e，静默跳过会导致最终 icns 未被量化且脚本"成功"退出
command -v pngquant >/dev/null || { echo "缺少 pngquant：brew install pngquant"; exit 1; }
for f in "$ICONSET"/*.png; do
  tmp="$f.quantized"
  pngquant 256 --speed 1 --force --output "$tmp" "$f" >/dev/null 2>&1 && mv "$tmp" "$f" || {
    echo "pngquant 失败: $f"; exit 1
  }
done

echo "==> 直接组装 icns（绕过 iconutil）"
python3 - "$ICONSET" "$RES/AppIcon.icns" << 'PY'
import sys, struct, os
iconset, outpath = sys.argv[1], sys.argv[2]
# OSType 映射
OSTYPE = {
    "icon_16x16.png": "icp4", "icon_16x16@2x.png": "icp5",
    "icon_32x32.png": "icp5", "icon_32x32@2x.png": "icp6",
    "icon_128x128.png": "ic07", "icon_128x128@2x.png": "ic08",
    "icon_256x256.png": "ic08", "icon_256x256@2x.png": "ic09",
    "icon_512x512.png": "ic09", "icon_512x512@2x.png": "ic10",
}
chunks = b""
for name, ostype in OSTYPE.items():
    path = os.path.join(iconset, name)
    if not os.path.exists(path):
        continue
    data = open(path, "rb").read()
    chunks += struct.pack(">4sI", ostype.encode(), 8 + len(data)) + data
total = 8 + len(chunks)
icns = struct.pack(">4sI", b"icns", total) + chunks
open(outpath, "wb").write(icns)
print(f"    icns 生成: {len(icns)} bytes")
PY

echo "==> 验证"
file "$RES/AppIcon.icns"
ls -la "$RES/AppIcon.icns"
echo "完成：$RES/AppIcon.icns"
