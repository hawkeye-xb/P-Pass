#!/usr/bin/env python3
"""Fail when assets/design/tokens.css drifts from assets/design/tokens.json.

DESK-15 finding: tokens.css's own header comment says "generated from
tokens.json (edit that first)", but nothing ever enforced that promise —
tokens.json could change and tokens.css silently keep the old value forever,
with no error anywhere in the pipeline. This script closes that gap.

tokens.css is hand-maintained (not literally generated), so this does not
regenerate it — it asserts that every canonical numeric/color value in
tokens.json's color/font/radius/size sections appears, verbatim, as the
corresponding --pp-* custom property in tokens.css. A missing or drifted
value fails loudly instead of silently.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TOKENS_JSON = REPO_ROOT / "assets" / "design" / "tokens.json"
TOKENS_CSS = REPO_ROOT / "assets" / "design" / "tokens.css"

# tokens.json key -> tokens.css custom property name. Anything in tokens.json
# not listed here is intentionally not mirrored into tokens.css (e.g. the
# headline/overline size *ranges*, which aren't single CSS values) — add an
# entry here whenever tokens.css starts consuming a new canonical value.
COLOR_MAP = {
    "paper": "--pp-paper", "canvas": "--pp-canvas", "linen": "--pp-linen",
    "ink": "--pp-ink", "ink-hover": "--pp-ink-hover", "ink-60": "--pp-ink-60",
    "ink-40": "--pp-ink-40", "hairline": "--pp-hairline",
    "surface-dark": "--pp-surface-dark",
    "safe": "--pp-safe", "safe-bg": "--pp-safe-bg",
    "waiting": "--pp-waiting", "waiting-bg": "--pp-waiting-bg",
    "act": "--pp-act", "act-bg": "--pp-act-bg",
    "idle": "--pp-idle", "idle-bg": "--pp-idle-bg",
    "border": "--pp-border", "border-strong": "--pp-border-strong",
    "divider": "--pp-divider",
}
FONT_MAP = {"serif": "--pp-font-serif", "sans": "--pp-font-sans"}
RADIUS_MAP = {
    "card": "--pp-radius-card", "control": "--pp-radius-control",
    "control-sm": "--pp-radius-control-sm", "pill": "--pp-radius-pill",
}
# size.desktop.* — only the single-value floors, not the headline range.
SIZE_DESKTOP_MAP = {"body-min": "--pp-body-min", "tap-min": "--pp-tap-min"}


def parse_css_vars(css_text: str) -> dict[str, str]:
    out = {}
    for m in re.finditer(r"--(pp-[\w-]+)\s*:\s*([^;]+);", css_text):
        out[f"--{m.group(1)}"] = m.group(2).strip()
    return out


RGBA_RE = re.compile(r"rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+)\s*)?\)", re.I)


def normalize(value: str) -> str:
    """Canonicalize a CSS value so equivalent-but-differently-formatted
    numbers (rgba(23,21,18,.12) vs rgba(23, 21, 18, 0.12)) don't false-positive
    as drift — only an actual different number should fail the check."""
    m = RGBA_RE.fullmatch(value.strip())
    if m:
        nums = [float(g) for g in m.groups() if g is not None]
        return "rgba(" + ",".join(f"{n:g}" for n in nums) + ")"
    return re.sub(r"\s+", " ", value.strip().rstrip(",")).lower()


def main() -> int:
    tokens = json.loads(TOKENS_JSON.read_text(encoding="utf-8"))
    css_vars = parse_css_vars(TOKENS_CSS.read_text(encoding="utf-8"))

    failures: list[str] = []

    def check(section: str, key_map: dict[str, str], get_value):
        for json_key, css_var in key_map.items():
            try:
                expected = get_value(json_key)
            except KeyError:
                failures.append(f"tokens.json missing {section}.{json_key} (mapped from tokens.css {css_var})")
                continue
            actual = css_vars.get(css_var)
            if actual is None:
                failures.append(f"tokens.css missing {css_var} (tokens.json {section}.{json_key} = {expected!r})")
            elif normalize(actual) != normalize(expected):
                failures.append(
                    f"drift: tokens.css {css_var} = {actual!r} but tokens.json {section}.{json_key} = {expected!r}"
                )

    check("color", COLOR_MAP, lambda k: tokens["color"][k]["value"])
    check("font", FONT_MAP, lambda k: tokens["font"][k]["value"])
    check("radius", RADIUS_MAP, lambda k: tokens["radius"][k]["value"])
    check("size.desktop", SIZE_DESKTOP_MAP, lambda k: tokens["size"]["desktop"][k]["value"])

    if failures:
        print("token drift check FAILED — tokens.css does not match assets/design/tokens.json:", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        print("\nFix: edit tokens.json first (single source of truth), then mirror the value into tokens.css.", file=sys.stderr)
        return 1

    print(f"ok: tokens.css matches tokens.json ({len(COLOR_MAP) + len(FONT_MAP) + len(RADIUS_MAP) + len(SIZE_DESKTOP_MAP)} values checked)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
