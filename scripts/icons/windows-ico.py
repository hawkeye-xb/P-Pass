#!/usr/bin/env python3
"""Windows 程序图标 icon.ico（DESK-66）——直接从设计 SVG 逐档渲染。

用法：python3 scripts/icons/windows-ico.py [输出路径]
      默认写 apps/desktop/src-tauri/icons/icon.ico；scripts/icons/generate.sh 第 2 步调用它。
依赖：resvg（`cargo install resvg`，纯 Rust 的标准 SVG 渲染器）。

为什么和 macOS 那几档分开：
  - macOS 规范要求整个图标四周留约 10% 透明边（系统再套圆角遮罩和投影），generate.sh
    的安全区 SVG 就是按它做的。Windows 不套遮罩，任务栏、开始菜单、Alt+Tab 直接画图标
    本身——带着这圈留白，图标在一排图标里就显得小（#944）。
  - Windows 按显示缩放从 ico 里挑最接近的一档（100% → 32、125% → 40、150% → 48、
    200% → 64 …）。缺档就拿相邻档缩放，糊。所以各档都要有，而且每档都直接从矢量
    渲染——绝不能拿小图裁掉留白再放大回原尺寸（#947 那样做，32 档实际只有 26 px
    的内容被拉伸到 32，就是糊的来源）。

构图：圆角纸底铺满画布（去掉 macOS 外层 0.8 的整体缩小）。
  - ≥48 px：碳纹版，兽面占纸底 77%——与 macOS 同一张脸。
  - ≤40 px：beast 全实线版（碳纹在小尺寸会糊，规格见 docs/design/2026-08-11-icon-v1/README.md），
    并按小尺寸单独调构图（验收人 2026-10-15 选定方案 A）：兽面放大到纸底 88%、线宽 72 → 96。
    Windows 11 任务栏在 100% 缩放下按 24 px 画图标；原比例下线条只剩约 1.3 px，抗锯齿成
    灰边、整张脸只有约 14 px 宽，看起来发虚。加粗后 24 px 档线条约 2 px。

幂等：同输入 SVG + 同 resvg 版本 → 字节一致。
"""

import re
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DESIGN = ROOT / "docs/design/2026-08-11-icon-v1"
DEFAULT_OUT = ROOT / "apps/desktop/src-tauri/icons/icon.ico"

# Windows 图标标准档位（Fluent 设计规范的应用图标尺寸）：覆盖 100%–400% 缩放下的
# 小图标（16/20/24/32）与大图标（32/40/48/64），96/128 给资源管理器中等视图，256 给大视图。
SIZES = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
BEAST_MAX = 40
# ico 里**第一档**就是任务栏图标：Tauri 2 编译期把 ico 的第一档（`entries()[0]`）解码成窗口图标，
# Windows 11 任务栏在 100% 缩放下按 24 px 画它。第一档是 16 就要放大（糊），是 48 就要缩小
# （碳纹细线发淡）；放 24 与任务栏逐像素对齐。2026-10-15 在本机任务栏上 16 / 24 / 48 三档对照实测。
# 局限：其它缩放（125% → 30 px、150% → 36 px）仍会缩放这一档；窗口图标只有一张，这是 Tauri 的限制。
FIRST = 24
# (兽面占纸底的比例, 线宽)；线宽 None = 用设计稿原值。
CARBON_LAYOUT = (0.77, None)
BEAST_SMALL_LAYOUT = (0.88, 96)


def windows_svg(src: Path, dst: Path, layout: tuple) -> None:
    face_scale, stroke = layout
    text = src.read_text(encoding="utf-8")
    m = re.match(r"(<svg[^>]*>)(.*)(</svg>)", text, re.S)
    if not m:
        sys.exit(f"{src}: 不是预期的 <svg>…</svg> 结构")
    head, body, tail = m.groups()
    paper_full = '<rect width="1024" height="1024" fill="#FBF8F2"/>'
    if paper_full not in body:
        sys.exit(f"{src}: 找不到铺满的纸底 rect——设计稿结构变了，先核对再改脚本")
    body = body.replace(paper_full, "")
    if stroke is not None:
        if 'stroke-width="72"' not in body:
            sys.exit(f"{src}: 找不到线宽 72——设计稿变了，先核对小尺寸构图再改脚本")
        body = body.replace('stroke-width="72"', f'stroke-width="{stroke}"')
    # 与 generate.sh 的 safe() 同一套圆角纸底 rx=250；只是不做外层 0.8。
    inner = f'<g transform="translate(512 512) scale({face_scale}) translate(-512 -512)">{body}</g>'
    paper = '<rect width="1024" height="1024" rx="250" ry="250" fill="#FBF8F2"/>'
    dst.write_text(f"{head}\n  {paper}\n  {inner}\n{tail}", encoding="utf-8")


def main() -> None:
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUT
    if shutil.which("resvg") is None:
        sys.exit("需要 resvg：cargo install resvg")
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        carbon, beast = tmp / "carbon-win.svg", tmp / "beast-win.svg"
        windows_svg(DESIGN / "icon-carbon.svg", carbon, CARBON_LAYOUT)
        windows_svg(DESIGN / "icon-beast.svg", beast, BEAST_SMALL_LAYOUT)
        frames = []
        for s in SIZES:
            png = tmp / f"{s}.png"
            svg = beast if s <= BEAST_MAX else carbon
            subprocess.run(["resvg", "-w", str(s), "-h", str(s), str(svg), str(png)], check=True)
            frames.append((s, png.read_bytes()))
    frames.sort(key=lambda f: (f[0] != FIRST, f[0]))
    # ICO 容器：每档存 PNG（Vista 起所有尺寸都支持 PNG 帧，32 位带 alpha）。
    header = struct.pack("<HHH", 0, 1, len(frames))
    entries, offset = b"", 6 + 16 * len(frames)
    for s, data in frames:
        w = 0 if s == 256 else s  # 256 在目录项里记作 0
        entries += struct.pack("<BBBBHHII", w, w, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
    out.write_bytes(header + entries + b"".join(d for _, d in frames))
    print(f"{out}: {len(frames)} 档 {SIZES}（<={BEAST_MAX}px beast 88%/线宽96，其余碳纹 77%；铺满画布）")


if __name__ == "__main__":
    main()
