#!/usr/bin/env bash
# P-Pass 图标资产生成器（ICON-01，2026-08-11）
#
# 唯一基准：docs/design/2026-08-11-icon-v1/*.svg（README.md 是规格）。
# 版本分工：
#   - 主图标（macOS/Android/Windows App 图标）= 碳纹版 icon-carbon.svg
#   - ≤40px / 托盘 / 通知 = beast 全实线版 icon-beast.svg（碳纹小尺寸会糊）
#   - macOS 托盘 = 模板图标（纯黑 + alpha，beast 重描）
#
# 幂等：连续跑两次产物字节一致（同输入 SVG → 同 PNG → 同 icns/ico）。
# 依赖：rsvg-convert (librsvg)、iconutil (macOS 自带)、python3。

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DESIGN="$ROOT/docs/design/2026-08-11-icon-v1"
ICONS="$ROOT/apps/desktop/src-tauri/icons"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

# ── 1. 主图标 PNG 阶梯（碳纹版，1024 源 → 各档）──────────────
# Tauri 期望的清单（含 Windows Store 档 + macOS icns 用各尺寸）。
# macOS icns 需要 16/32/64/128/256/512/1024（@2x 档由 iconutil 生成）。
for size in 16 32 48 64 128 256 512 1024; do
  rsvg-convert -w "$size" -h "$size" "$DESIGN/icon-carbon.svg" -o "$OUT/${size}x${size}.png"
done
# ⚠️ tauri generate_context! 硬性要求 icons/*.png 为 RGBA——rsvg-convert
# 对铺满纸底的 SVG 输出 RGB（无 alpha），必须强制转 RGBA。
python3 - "$OUT" <<'PYEOF'
import sys, pathlib
from PIL import Image
out = pathlib.Path(sys.argv[1])
for p in out.glob("*.png"):
    im = Image.open(p).convert("RGBA")
    im.save(p)
print("all pngs converted to RGBA")
PYEOF
# @2x 档（macOS icns 的 retina 表示：16@2x=32, 32@2x=64, ...）
for size in 16 32 64 128 256 512; do
  px=$((size * 2))
  rsvg-convert -w "$px" -h "$px" "$DESIGN/icon-carbon.svg" -o "$OUT/${size}x${size}@2x.png"
done

# ── 2. Windows .ico（多尺寸合成；≤32px 用 beast，≥48px 碳纹）─
# ico 无 1024 档（Vista+ 最大 256）。小尺寸档碳纹会糊 → beast 覆盖。
python3 - "$OUT" "$DESIGN" <<'PYEOF'
import subprocess, sys, struct, os
out, design = sys.argv[1], sys.argv[2]
def render(s, svg):
    p = f"{out}/gen-{s}-{'beast' if 'beast' in svg else 'carbon'}.png"
    subprocess.run(["rsvg-convert", "-w", str(s), "-h", str(s), svg, "-o", p], check=True)
    return p
sizes = [16, 32, 48, 64, 128, 256]
pngs = []
for s in sizes:
    svg = f"{design}/icon-beast.svg" if s <= 32 else f"{design}/icon-carbon.svg"
    p = render(s, svg)
    pngs.append((s, open(p, "rb").read()))
header = struct.pack("<HHH", 0, 1, len(pngs))
entries = b""
offset = 6 + 16 * len(pngs)
for s, data in pngs:
    w = 0 if s == 256 else s
    entries += struct.pack("<BBBBHHII", w, w, 0, 0, 1, 32, len(data), offset)
    offset += len(data)
with open(f"{out}/icon.ico", "wb") as f:
    f.write(header + entries + b"".join(d for _, d in pngs))
print("ico written (beast ≤32px, carbon ≥48px)")
PYEOF

# ── 3. macOS .icns（iconutil，碳纹版大层 + beast 小层）────────
# ICON-01 分工：icns 内 ≤32px 层用 beast（碳纹小尺寸会糊），大层碳纹。
ICONSET="$OUT/icon.iconset"
mkdir -p "$ICONSET"
# 16/32px 层 → beast 全实线；≥128px 层 → 碳纹（含 @2x 表示）
rsvg-convert -w 16 -h 16 "$DESIGN/icon-beast.svg" -o "$ICONSET/icon_16x16.png"
rsvg-convert -w 32 -h 32 "$DESIGN/icon-beast.svg" -o "$ICONSET/icon_16x16@2x.png"
rsvg-convert -w 32 -h 32 "$DESIGN/icon-beast.svg" -o "$ICONSET/icon_32x32.png"
rsvg-convert -w 64 -h 64 "$DESIGN/icon-beast.svg" -o "$ICONSET/icon_32x32@2x.png"
cp "$OUT/128x128.png" "$ICONSET/icon_128x128.png"
cp "$OUT/256x256.png" "$ICONSET/icon_128x128@2x.png"
cp "$OUT/256x256.png" "$ICONSET/icon_256x256.png"
cp "$OUT/512x512.png" "$ICONSET/icon_256x256@2x.png"
cp "$OUT/512x512.png" "$ICONSET/icon_512x512.png"
# 512@2x 就是 1024
cp "$OUT/1024x1024.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$OUT/icon.icns"

# ── 4. Tauri 标准文件集（carbon 主档 + Square 系列）─────────
cp "$OUT/32x32.png" "$ICONS/32x32.png"
cp "$OUT/32x32@2x.png" "$ICONS/32x32@2x.png"
cp "$OUT/64x64.png" "$ICONS/64x64.png"
cp "$OUT/128x128.png" "$ICONS/128x128.png"
cp "$OUT/128x128@2x.png" "$ICONS/128x128@2x.png"
cp "$OUT/256x256.png" "$ICONS/256x256.png"
cp "$OUT/icon.icns" "$ICONS/icon.icns"
cp "$OUT/icon.ico" "$ICONS/icon.ico"
# 主 app-icon.png（README/文档用，1024）
cp "$OUT/1024x1024.png" "$ICONS/app-icon.png"

# ── 5. 托盘模板图标（beast 全实线，纯黑 + alpha）─────────────
# macOS 菜单栏模板图标：纯黑形状 + alpha 通道，系统按深/浅色自动反色。
# 从 beast SVG 生成：白底去掉、描边和瞳孔全部改纯黑。
TRAY_SVG="$OUT/tray-beast.svg"
python3 - "$DESIGN/icon-beast.svg" "$TRAY_SVG" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
# 去白底矩形（模板图标不要底色）
src = re.sub(r'<rect width="1024" height="1024" fill="#FBF8F2"/>', '', src)
# 所有可见元素统一纯黑（描边 + 填充）
src = src.replace('stroke="#171512"', 'stroke="#000000"')
src = src.replace('fill="#2E6B4F"', 'fill="#000000"')
open(sys.argv[2], 'w').write(src)
print("tray svg written")
PYEOF
for size in 16 32; do
  rsvg-convert -w "$size" -h "$size" "$TRAY_SVG" -o "$OUT/tray-${size}x${size}.png"
done
# 32px 主档进 tauri icons（托盘构建引用），16px 一并保存
cp "$OUT/tray-32x32.png" "$ICONS/tray-icon.png"
cp "$OUT/tray-16x16.png" "$ICONS/tray-icon-16.png"

# ── 6. Android 自适应图标（分密度 PNG 前景 + 背景色）──────────
# VectorDrawable 不支持 SVG pattern（碳纹会丢）→ 前景层必须分密度 PNG。
# 自适应图标安全区 = 画布中央 66%：前景层直接把 beast/carbon 内容
# 渲染到 432×432 有效区（66% of 1024 ≈ 676，用 66% 缩排到前景画布）。
ANDROID_RES="$ROOT/apps/android/app/src/main/res"
# 背景：纯色（paper 底）—— Android 12+ 会裁成圆角/形状，用颜色即可。
mkdir -p "$ANDROID_RES/values"
cat > "$ANDROID_RES/values/ic_launcher_background.xml" <<'XEOF'
<?xml version="1.0" encoding="utf-8"?>
<resources>
    <color name="ic_launcher_background">#FBF8F2</color>
</resources>
XEOF

# 前景：碳纹版主图标，但 Android 自适应图标安全区要求内容在中央 66%。
# 做法：把 1024 画布缩到 66%（676px 有效），再渲染到各密度画布。
# 密度参考：mdpi=48dp → 前景 108dp 画布；ldpi/mdpi/hdpi/xhdpi/xxhdpi/xxxhdpi
# 对应 px = dp * density/160。
# ⚠️ bash 3.2（macOS 默认）不支持关联数组——用并行数组。
DENS_NAMES=(mdpi hdpi xhdpi xxhdpi xxxhdpi)
DENS_SCALE=(1 1.5 2 3 4)
for i in "${!DENS_NAMES[@]}"; do
  d="${DENS_NAMES[$i]}"
  px=$(python3 -c "print(int(108 * ${DENS_SCALE[$i]}))")
  mkdir -p "$ANDROID_RES/mipmap-$d"
  rsvg-convert -w "$px" -h "$px" "$DESIGN/icon-carbon.svg" \
    -o "$ANDROID_RES/mipmap-$d/ic_launcher_foreground.png"
done

# anydpi-v26 自适应图标定义（引分密度前景 PNG + 背景色）
mkdir -p "$ANDROID_RES/mipmap-anydpi-v26"
cat > "$ANDROID_RES/mipmap-anydpi-v26/ic_launcher.xml" <<'XEOF'
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
  <background android:drawable="@color/ic_launcher_background"/>
  <foreground android:drawable="@mipmap/ic_launcher_foreground"/>
</adaptive-icon>
XEOF

# 旧密度目录可能残留 ic_launcher.png/round（Tauri 模板生成）——清掉，
# 只留 foreground（round 由自适应图标系统自动裁）。
for i in "${!DENS_NAMES[@]}"; do
  d="${DENS_NAMES[$i]}"
  rm -f "$ANDROID_RES/mipmap-$d"/ic_launcher.png \
        "$ANDROID_RES/mipmap-$d"/ic_launcher_round.png \
        "$ANDROID_RES/mipmap-$d"/ic_launcher_round_foreground.png
done

# ── 7. Android 通知小图标（status bar，beast 剪影）────────────
# 通知小图标要求纯 alpha 剪影（系统渲染成白色，彩色会被当成剪影吃掉）。
# beast 全实线 → 剪掉纸底和绿色，只剩黑色轮廓 → 反相成白轮廓。
mkdir -p "$ANDROID_RES/drawable"
python3 - "$DESIGN/icon-beast.svg" "$ANDROID_RES/drawable/ic_notification.xml" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
src = re.sub(r'<rect width="1024" height="1024" fill="#FBF8F2"/>', '', src)
src = src.replace('stroke="#171512"', 'stroke="#FFFFFF"')
src = src.replace('fill="#2E6B4F"', 'fill="#FFFFFF"')
# 去掉外层的 svg 标签，转成 VectorDrawable（全实线无 pattern，可矢量）
paths = re.findall(r'<path d="([^"]+)"[^>]*/>', src)
circles = re.findall(r'<circle cx="(\d+)" cy="(\d+)" r="(\d+)"/>', src)
out = ['<?xml version="1.0" encoding="utf-8"?>',
       '<vector xmlns:android="http://schemas.android.com/apk/res/android"',
       '    android:width="24dp" android:height="24dp"',
       '    android:viewportWidth="1024" android:viewportHeight="1024">']
for d in paths:
    out.append(f'    <path android:pathData="{d}" android:strokeColor="#FFFFFF" android:strokeWidth="72" android:strokeLineCap="round" android:strokeLineJoin="round" android:fillColor="#00000000"/>')
for cx, cy, r in circles:
    out.append(f'    <path android:pathData="M {cx} {int(cy)-int(r)} a {r} {r} 0 1 0 1 0 z" android:fillColor="#FFFFFF"/>')
out.append('</vector>')
open(sys.argv[2], 'w').write('\n'.join(out))
print("notification icon written")
PYEOF

# ── 8. Android 13 monochrome 主题图标（beast 单色矢量）────────
# Android 13+ 主题图标：monochrome 层 = 单色矢量（THEMED_ICON）。
# beast 全实线无 pattern → 可直接转 VectorDrawable；白底去掉。
python3 - "$DESIGN/icon-beast.svg" "$ANDROID_RES/drawable/ic_launcher_monochrome.xml" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
src = re.sub(r'<rect width="1024" height="1024" fill="#FBF8F2"/>', '', src)
src = src.replace('stroke="#171512"', 'stroke="#000000"')
src = src.replace('fill="#2E6B4F"', 'fill="#000000"')
paths = re.findall(r'<path d="([^"]+)"[^>]*/>', src)
circles = re.findall(r'<circle cx="(\d+)" cy="(\d+)" r="(\d+)"/>', src)
out = ['<?xml version="1.0" encoding="utf-8"?>',
       '<vector xmlns:android="http://schemas.android.com/apk/res/android"',
       '    android:width="108dp" android:height="108dp"',
       '    android:viewportWidth="1024" android:viewportHeight="1024">']
for d in paths:
    out.append(f'    <path android:pathData="{d}" android:strokeColor="#000000" android:strokeWidth="72" android:strokeLineCap="round" android:strokeLineJoin="round" android:fillColor="#00000000"/>')
for cx, cy, r in circles:
    out.append(f'    <path android:pathData="M {cx} {int(cy)-int(r)} a {r} {r} 0 1 0 1 0 z" android:fillColor="#000000"/>')
out.append('</vector>')
open(sys.argv[2], 'w').write('\n'.join(out))
print("monochrome written")
PYEOF

# monochrome 层挂进自适应图标（Android 13+ 主题图标）
python3 - "$ANDROID_RES/mipmap-anydpi-v26/ic_launcher.xml" <<'PYEOF'
import sys
p = sys.argv[1]
src = open(p).read()
if 'monochrome' not in src:
    src = src.replace(
        '  <foreground android:drawable="@mipmap/ic_launcher_foreground"/>',
        '  <foreground android:drawable="@mipmap/ic_launcher_foreground"/>\n'
        '  <monochrome android:drawable="@drawable/ic_launcher_monochrome"/>'
    )
    open(p, 'w').write(src)
    print("monochrome wired into adaptive icon")
else:
    print("monochrome already wired")
PYEOF

echo "✅ 图标资产已生成（幂等）"
