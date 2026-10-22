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
  - `mobile-ui.*` resolved with `platforms.ios` → PPUI.TextSize / PPUI.Layout / PPUI.Surface (#943)
    base values are Android's; an iOS override must name an existing base key and carry a `why`.
    Value `system` = keep the native SwiftUI List default, so no constant is generated for it;
    every override (system or not) is listed in PPUI.iosOverrides so deviations are greppable.
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
# #941：启动屏背景色（Info.plist UILaunchScreen.UIColorName）。UILaunchScreen 只能引用 asset catalog 的 color set，
# 所以把 token 同步生成成 color set，而不是手写。App 固定浅色外观（UIUserInterfaceStyle=Light），只有一个外观。
LAUNCH_COLORSET = ROOT / "apps" / "ios" / "PPass" / "Resources" / "Assets.xcassets" / "LaunchBackground.colorset" / "Contents.json"
LAUNCH_COLOR_TOKEN = "paper"

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


MUI_SECTIONS = (("type", "TextSize", "字号（pt）"), ("layout", "Layout", "间距 / 尺寸（pt）"), ("surface", "Surface", "底色"))


def resolve_mobile_ui(tokens: dict) -> tuple[dict, list]:
    """mobile-ui 基础值叠上 platforms.ios。返回 {section: {key: value}} 与覆盖清单 [(全键, 基础值, iOS 值, why)]。"""
    mui = tokens.get("mobile-ui", {})
    resolved = {sec: {k: v["value"] for k, v in mui.get(sec, {}).items()} for sec, _, _ in MUI_SECTIONS}
    overrides = []
    for full, spec in tokens.get("platforms", {}).get("ios", {}).items():
        if full.startswith("$"):
            continue
        parts = full.split(".")
        if len(parts) != 3 or parts[0] != "mobile-ui" or parts[2] not in resolved.get(parts[1], {}):
            sys.exit(f"gen-tokens: platforms.ios.{full} 覆盖的键在 mobile-ui 里不存在")
        why = (spec.get("why") or "").strip()
        if not why:
            sys.exit(f"gen-tokens: platforms.ios.{full} 没写 why——偏离 Android 必须写理由")
        sec, key = parts[1], parts[2]
        overrides.append((full, resolved[sec][key], spec["value"], why))
        resolved[sec][key] = spec["value"]
    for key, val in resolved["surface"].items():
        if val != "system" and val not in tokens["color"]:
            sys.exit(f"gen-tokens: mobile-ui.surface.{key} = {val!r} 不是 color 的键名")
    return resolved, overrides


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
    resolved, overrides = resolve_mobile_ui(tokens)
    over = {o[0]: o for o in overrides}
    w("/// 手机首页语义尺寸（tokens.json mobile-ui）。基础值 = Android；iOS 偏离登记在 platforms.ios（见 iosOverrides）。")
    w("/// 值为 system 的项不生成常量：那一项用原生 List 的默认值，代码里不要再写数字。")
    w("enum PPUI {")
    for sec, name, title in MUI_SECTIONS:
        w(f"    /// {title}")
        w(f"    enum {name} {{")
        for k, val in resolved[sec].items():
            full = f"mobile-ui.{sec}.{k}"
            if full in over:
                w(f"        /// iOS 覆盖（Android {over[full][1]}）：见 iosOverrides[{swift_str(full)}]")
            if val == "system":
                w(f"        // {camel(k)}: system（原生默认，不生成常量）")
                continue
            if sec == "surface":
                w(f"        static let {camel(k)} = PPColor.{camel(val)}")
                continue
            m = PX_RE.match(val)
            if not m:
                sys.exit(f"gen-tokens: {full} 不是 px 单值也不是 system：{val!r}")
            w(f"        static let {camel(k)}: CGFloat = {num(m.group(1))}")
        w("    }")
        w("")
    w("    /// platforms.ios 的全部覆盖：键 → (Android 基础值, iOS 值, 理由)。")
    w("    static let iosOverrides: [String: (android: String, ios: String, why: String)] = [")
    for full, base, val, why in overrides:
        w(f"        {swift_str(full)}: ({swift_str(base)}, {swift_str(val)}, {swift_str(why)}),")
    w("    ]")
    w("}")
    w("")
    w("/// 品牌字体族（字体栈里的第一个）。字体文件随 App 捆绑。")
    w("enum PPFontFamily {")
    for k, v in fonts.items():
        w(f"    static let {camel(k)} = {swift_str(first_family(v['value']))}")
    w("}")
    return "\n".join(L) + "\n"


def render_colorset(tokens: dict) -> str:
    value = tokens["color"][LAUNCH_COLOR_TOKEN]["value"]
    m = HEX_RE.match(value)
    if not m:
        sys.exit(f"gen-tokens: color.{LAUNCH_COLOR_TOKEN} 必须是 #RRGGBB：{value!r}")
    h = m.group(1)
    comp = {k: f"0x{h[i : i + 2].upper()}" for k, i in (("red", 0), ("green", 2), ("blue", 4))}
    doc = {
        "colors": [
            {
                "color": {"color-space": "srgb", "components": {**comp, "alpha": "1.000"}},
                "idiom": "universal",
            }
        ],
        "info": {"author": "xcode", "version": 1},
    }
    return json.dumps(doc, indent=2, ensure_ascii=False) + "\n"


def main() -> int:
    check = "--check" in sys.argv[1:]
    tokens = json.loads(SRC.read_text(encoding="utf-8"))
    outputs = [(OUT, render(tokens)), (LAUNCH_COLORSET, render_colorset(tokens))]
    bad = 0
    for path, text in outputs:
        rel = path.relative_to(ROOT)
        if check:
            cur = path.read_text(encoding="utf-8") if path.exists() else None
            if cur != text:
                print(f"✗ {rel} 与 assets/design/tokens.json 不同步——跑 `just ios-tokens` 重新生成并提交。", file=sys.stderr)
                bad = 1
            else:
                print(f"ok: {rel} 与 tokens.json 同步")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
            print(f"wrote {rel}")
    return bad


if __name__ == "__main__":
    sys.exit(main())
