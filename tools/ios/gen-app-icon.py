#!/usr/bin/env python3
"""由定稿图标源 SVG 渲染 iOS App 图标三态 + 启动屏图标（#941）。

    tools/ios/gen-app-icon.py           # 重写 Assets.xcassets 里的 PNG
    tools/ios/gen-app-icon.py --check   # 源 SVG 变了而 PNG 没重渲染时退出 1

源：docs/design/2026-08-11-icon-v1/icon-carbon.svg（默认）、icon-carbon-night.svg（深色）。
  - AppIcon-1024.png        默认：原样渲染，无 alpha（App Store 要求）。
  - AppIcon-1024-dark.png   深色（iOS 18+）：夜巡版，surface-dark 底，无 alpha。
  - AppIcon-1024-tinted.png 着色（iOS 18+）：夜巡版去掉底、转灰度，透明底（系统自带着色底）。
  - LaunchLogo@1x/2x/3x     启动屏居中图标（120pt）：默认版去掉底，透明背景，叠在 paper 色上。
依赖 rsvg-convert（brew install librsvg）与 Pillow。颜色全部来自源 SVG（即 tokens.json）；
灰度化只是对夜巡版亮度做单通道转换，不引入新色。
"""
from __future__ import annotations

import hashlib
import io
import re
import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "docs" / "design" / "2026-08-11-icon-v1"
ASSETS = ROOT / "apps" / "ios" / "PPass" / "Resources" / "Assets.xcassets"
ICON = ASSETS / "AppIcon.appiconset"
LOGO = ASSETS / "LaunchLogo.imageset"

BG_RE = re.compile(r'\s*<rect width="1024" height="1024" fill="#[0-9A-Fa-f]{6}"/>')


def render(svg: str, px: int) -> Image.Image:
    out = subprocess.run(
        ["rsvg-convert", "-w", str(px), "-h", str(px), "-f", "png"],
        input=svg.encode(), capture_output=True, check=True,
    ).stdout
    return Image.open(io.BytesIO(out)).convert("RGBA")


def strip_bg(svg: str) -> str:
    out, n = BG_RE.subn("", svg)
    if n != 1:
        sys.exit("gen-app-icon: 源 SVG 里找不到唯一的整幅底色 rect，结构变了，需要人工处理")
    return out


def opaque(img: Image.Image) -> Image.Image:
    return img.convert("RGB")


def build() -> dict[Path, Image.Image]:
    light = (SRC / "icon-carbon.svg").read_text(encoding="utf-8")
    night = (SRC / "icon-carbon-night.svg").read_text(encoding="utf-8")
    files: dict[Path, Image.Image] = {}
    files[ICON / "AppIcon-1024.png"] = opaque(render(light, 1024))
    files[ICON / "AppIcon-1024-dark.png"] = opaque(render(night, 1024))
    fg = render(strip_bg(night), 1024)
    lum = fg.convert("L")
    tinted = Image.merge("LA", (lum, fg.getchannel("A")))
    files[ICON / "AppIcon-1024-tinted.png"] = tinted
    logo_svg = strip_bg(light)
    for scale in (1, 2, 3):
        files[LOGO / f"LaunchLogo@{scale}x.png"] = render(logo_svg, 120 * scale)
    return files


def encode(img: Image.Image) -> bytes:
    buf = io.BytesIO()
    img.save(buf, "PNG", optimize=True)
    return buf.getvalue()


def main() -> int:
    check = "--check" in sys.argv[1:]
    files = build()
    bad = 0
    for path, img in files.items():
        data = encode(img)
        rel = path.relative_to(ROOT)
        if check:
            # 逐像素比对（不比字节：不同 PNG 编码器输出可能不同）
            ok = path.exists() and Image.open(path).convert("RGBA").tobytes() == img.convert("RGBA").tobytes() \
                and Image.open(path).size == img.size
            if not ok:
                print(f"✗ {rel} 与源 SVG 渲染结果不一致——跑 tools/ios/gen-app-icon.py 并提交", file=sys.stderr)
                bad = 1
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            print(f"wrote {rel} {img.size} {img.mode} sha256={hashlib.sha256(data).hexdigest()[:12]}")
    return bad


if __name__ == "__main__":
    sys.exit(main())
