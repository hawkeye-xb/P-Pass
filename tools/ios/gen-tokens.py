#!/usr/bin/env python3
"""Generate the iOS design tokens from assets/design/tokens.json (#344).

    tools/ios/gen-tokens.py           # rewrite apps/ios/PPass/Design/Tokens.generated.swift
    tools/ios/gen-tokens.py --check   # exit 1 if the committed file differs from what we'd generate

tokens.json is the single source of truth (assets/design/README.md). Desktop's tokens.css
and Android's Tokens.kt are hand-maintained (tokens.css is value-checked by check-token-drift.py); iOS is *generated*,
so the drift gate is byte-exact: change tokens.json without regenerating and --check fails.
The XCTest `DesignTokensTests` additionally reads tokens.json at test time and compares it
key-by-key with the generated table — a second, independent gate that runs in ci-ios.

What is generated:
  - every `color.*`                      → PPColor.<camelCase>     (sRGB, alpha from rgba())
  - every `radius.*`                     → PPRadius.<camelCase>    (points)
  - every `size.mobile.*` single value   → PPSize.<camelCase>; ranges "30px–52px" → <name>Min/<name>Max
  - `font.*` first family in the stack   → PPFontFamily.<name>     (e.g. "Newsreader")
  - PPTokenSource: the raw strings as they appear in tokens.json (what the XCTest compares)
Desktop-only sizes and the CSS-shorthand `size.overline` are not mobile tokens and are skipped.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "assets" / "design" / "tokens.json"
OUT = ROOT / "apps" / "ios" / "PPass" / "Design" / "Tokens.generated.swift"

HEX_RE = re.compile(r"^#([0-9A-Fa-f]{6})$")
RGBA_RE = re.compile(r"^rgba\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*([\d.]+)\s*\)$")
PX_RE = re.compile(r"^(\d+(?:\.\d+)?)px$")
RANGE_RE = re.compile(r"^(\d+(?:\.\d+)?)px\s*[–-]\s*(\d+(?:\.\d+)?)px$")


def camel(key: str) -> str:
    parts = re.split(r"[-_]", key)
    out = parts[0] + "".join(p[:1].upper() + p[1:] for p in parts[1:])
    if out[0].isdigit():
        out = "_" + out
    return out


def num(x: str) -> str:
    v = float(x)
    return str(int(v)) if v.is_integer() else repr(v)


def color_expr(value: str) -> str:
    m = HEX_RE.match(value)
    if m:
        h = m.group(1)
        r, g, b = (int(h[i : i + 2], 16) for i in (0, 2, 4))
        a = "1"
    else:
        m = RGBA_RE.match(value)
        if not m:
            sys.exit(f"gen-tokens: 不认识的颜色写法 {value!r}（只支持 #RRGGBB 与 rgba(r,g,b,a)）")
        r, g, b = (int(m.group(i)) for i in (1, 2, 3))
        a = num(m.group(4))
    return f"Color(.sRGB, red: {r} / 255, green: {g} / 255, blue: {b} / 255, opacity: {a})"


def swift_str(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def first_family(stack: str) -> str:
    first = stack.split(",")[0].strip().strip("'\"")
    if not first:
        sys.exit(f"gen-tokens: 读不出字体族 {stack!r}")
    return first


def render(tokens: dict) -> str:
    colors = tokens["color"]
    radii = tokens["radius"]
    mobile = tokens["size"]["mobile"]
    fonts = tokens["font"]

    L: list[str] = []
    w = L.append
    w("// 由 tools/ios/gen-tokens.py 从 assets/design/tokens.json 生成——不要手改。")
    w("// 改 token：先改 tokens.json，再跑 `just ios-tokens`（或 python3 tools/ios/gen-tokens.py）。")
    w("// 漂移门禁：gen-tokens.py --check（逐字节）+ PPassTests/DesignTokensTests（逐键对照源文件）。")
    w("// swiftlint:disable all")
    w("import SwiftUI")
    w("")
    w("/// tokens.json 里的原始写法。DesignTokensTests 拿它与源文件逐键比较。")
    w("enum PPTokenSource {")
    for name, section in (("colors", colors), ("radii", radii), ("mobileSizes", mobile), ("fonts", fonts)):
        w(f"    static let {name}: [String: String] = [")
        for k, v in section.items():
            w(f"        {swift_str(k)}: {swift_str(v['value'])},")
        w("    ]")
    w("}")
    w("")
    w("/// 颜色。只有 safe / waiting / act 三种含义色（tokens.json rules）。")
    w("enum PPColor {")
    for k, v in colors.items():
        use = v.get("use")
        if use:
            w(f"    /// {use}")
        w(f"    static let {camel(k)} = {color_expr(v['value'])}")
    w("")
    w("    /// 按 tokens.json 的键索引，供测试核对生成结果。")
    w("    static let all: [String: Color] = [")
    for k in colors:
        w(f"        {swift_str(k)}: {camel(k)},")
    w("    ]")
    w("}")
    w("")
    w("/// 圆角（pt）。")
    w("enum PPRadius {")
    for k, v in radii.items():
        m = PX_RE.match(v["value"])
        if not m:
            sys.exit(f"gen-tokens: radius.{k} 不是 px 单值：{v['value']!r}")
        w(f"    static let {camel(k)}: CGFloat = {num(m.group(1))}")
    w("}")
    w("")
    w("/// 手机尺寸（pt）。区间拆成 Min/Max。")
    w("enum PPSize {")
    for k, v in mobile.items():
        val = v["value"]
        m = PX_RE.match(val)
        r = RANGE_RE.match(val)
        if m:
            w(f"    static let {camel(k)}: CGFloat = {num(m.group(1))}")
        elif r:
            w(f"    static let {camel(k)}Min: CGFloat = {num(r.group(1))}")
            w(f"    static let {camel(k)}Max: CGFloat = {num(r.group(2))}")
        else:
            sys.exit(f"gen-tokens: size.mobile.{k} 既不是 px 单值也不是 px 区间：{val!r}")
    w("}")
    w("")
    w("/// 品牌字体族（字体栈里的第一个）。字体文件随 App 捆绑。")
    w("enum PPFontFamily {")
    for k, v in fonts.items():
        w(f"    static let {camel(k)} = {swift_str(first_family(v['value']))}")
    w("}")
    return "\n".join(L) + "\n"


def main() -> int:
    check = "--check" in sys.argv[1:]
    text = render(json.loads(SRC.read_text(encoding="utf-8")))
    rel = OUT.relative_to(ROOT)
    if check:
        cur = OUT.read_text(encoding="utf-8") if OUT.exists() else None
        if cur != text:
            print(f"✗ {rel} 与 assets/design/tokens.json 不同步——跑 `just ios-tokens` 重新生成并提交。", file=sys.stderr)
            return 1
        print(f"ok: {rel} 与 tokens.json 同步")
        return 0
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding="utf-8")
    print(f"wrote {rel}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
