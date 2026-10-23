#!/usr/bin/env python3
"""WCAG 2.2 contrast report for the colour pairs P-Pass actually renders (#1127).

Reads assets/design/tokens.json and computes the contrast ratio of every
foreground/background pair listed in PAIRS below — not an N×N matrix of all
tokens, only combinations the apps really draw, each with a code reference.

Two surface families are checked separately (the apps have no system dark
mode — Android Theme.Material.Light / iOS UIUserInterfaceStyle=Light; the only
dark screens are scan / photo viewer / video on `surface-dark`):
  light — paper / canvas / linen and the pill backgrounds
  dark  — surface-dark

Translucent colours (border, divider, PaperDim …) are alpha-composited onto
their actual background in sRGB space before the luminance is computed, which
is what the renderer does.

Thresholds (WCAG 2.2):
  text        4.5:1  (1.4.3)
  large-text  3:1    (1.4.3; >=24px, or >=18.66px bold)
  non-text    3:1    (1.4.11; control boundaries and meaningful icons only)
  decorative  reported, never fails (1.4.11 does not apply: purely
              decorative lines, or outlines of buttons whose text label
              already identifies them — see W3C "Understanding 1.4.11")

Usage:
  python3 tools/a11y-contrast.py            # report, exit 0
  python3 tools/a11y-contrast.py --strict   # exit 1 if any pair fails
  python3 tools/a11y-contrast.py --json     # machine-readable report

Report-only by default on purpose: some failures are brand colours whose fix
needs a design decision, so this is not wired into CI as a blocking gate.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TOKENS_JSON = REPO_ROOT / "assets" / "design" / "tokens.json"

THRESHOLDS = {"text": 4.5, "large-text": 3.0, "non-text": 3.0, "decorative": None}
CRITERION = {
    "text": "1.4.3",
    "large-text": "1.4.3",
    "non-text": "1.4.11",
    "decorative": "-",
}

RGBA = tuple[float, float, float, float]


def parse_color(value: str) -> RGBA:
    """'#RRGGBB' / '#RRGGBBAA' / 'rgba(r,g,b,a)' / 'rgb(r,g,b)' -> (r, g, b, a), channels 0-255."""
    v = value.strip()
    m = re.fullmatch(r"#([0-9a-fA-F]{6})([0-9a-fA-F]{2})?", v)
    if m:
        h = m.group(1)
        a = int(m.group(2), 16) / 255 if m.group(2) else 1.0
        return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), a)
    m = re.fullmatch(r"rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)\s*(?:,\s*([\d.]+)\s*)?\)", v)
    if m:
        a = float(m.group(4)) if m.group(4) is not None else 1.0
        return (float(m.group(1)), float(m.group(2)), float(m.group(3)), a)
    raise ValueError(f"unsupported colour literal: {value!r}")


def composite(fg: RGBA, bg: RGBA) -> RGBA:
    """Source-over in sRGB encoded space (what browsers / Skia / Core Graphics do by default)."""
    if bg[3] < 1.0:
        raise ValueError("background must be opaque; composite it onto its own backdrop first")
    a = fg[3]
    return (
        fg[0] * a + bg[0] * (1 - a),
        fg[1] * a + bg[1] * (1 - a),
        fg[2] * a + bg[2] * (1 - a),
        1.0,
    )


def relative_luminance(c: RGBA) -> float:
    def lin(ch: float) -> float:
        s = ch / 255
        return s / 12.92 if s <= 0.04045 else ((s + 0.055) / 1.055) ** 2.4

    return 0.2126 * lin(c[0]) + 0.7152 * lin(c[1]) + 0.0722 * lin(c[2])


def contrast_ratio(fg: RGBA, bg: RGBA) -> float:
    fg = composite(fg, bg) if fg[3] < 1.0 else fg
    l1, l2 = relative_luminance(fg), relative_luminance(bg)
    hi, lo = max(l1, l2), min(l1, l2)
    return (hi + 0.05) / (lo + 0.05)


def to_hex(c: RGBA) -> str:
    return "#{:02X}{:02X}{:02X}".format(*(round(x) for x in c[:3]))


@dataclass(frozen=True)
class Pair:
    fg: str          # token key, optionally "key@alpha" (e.g. "paper@0.62" = PaperDim)
    bg: str          # opaque token key
    kind: str        # text | large-text | non-text | decorative
    family: str      # light | dark
    use: str         # what this pair is on screen
    refs: str        # representative code locations


# Pairs the apps actually draw. Keep each entry tied to a code reference; when a
# screen starts drawing a new token combination, add it here.
A, I, D, S = "android ui/", "ios PPass/", "desktop src/", "site src/"
L, K = "light", "dark"

PAIRS: list[Pair] = [
    # ---- paper (app surface) ----
    Pair("ink", "paper", "text", L, "body text, row labels", f"{A}HomeScreen.kt:878; {I}Design/PPStyle.swift:266; {D}App.svelte:2218"),
    Pair("ink-60", "paper", "text", L, "secondary text, onboarding copy, quiet button label", f"{A}Onboarding.kt:69; {I}Pairing/OnboardingFlow.swift:44; {D}Wizard.svelte:76"),
    Pair("ink-40", "paper", "text", L, "meta / captions / unselected tab label (11-15px)", f"{A}PhotosScreen.kt:406; {A}TwoTabs.kt:130; {D}App.svelte:1618; {S}components/Landing.astro:52"),
    Pair("ink-40", "paper", "non-text", L, "unselected tab icon, folder icon button", f"{A}TwoTabs.kt:128; {I}Design/PPStyle.swift:91; {D}App.svelte:1794"),
    Pair("act", "paper", "text", L, "error text, destructive outline button label", f"{A}UpdateDialog.kt:53; {A}HomeScreen.kt:992; {I}Pairing/OnboardingFlow.swift:118; {D}App.svelte:1610"),
    Pair("act", "paper", "large-text", L, "failure page headline 36pt serif", f"{I}PPassApp.swift:249"),
    Pair("waiting", "paper", "text", L, "low-space notice, amber setting hint, 'new' album tag (11-13.5px)", f"{A}HomeScreen.kt:624,832; {A}BucketScreen.kt:181; {I}Home/HeroCard.swift:46"),
    Pair("safe", "paper", "text", L, "'checks passed', safe-tone link", f"{D}Wizard.svelte:63; {D}lib/components/ui/button/button.svelte:34"),
    Pair("safe", "paper", "non-text", L, "status dot / update progress bar", f"{D}Wizard.svelte:101; {A}UpdateDialog.kt:185"),
    Pair("waiting", "paper", "non-text", L, "status dot (waiting)", f"{D}Wizard.svelte:101; {D}App.svelte:1815"),
    Pair("idle", "paper", "non-text", L, "status dot (offline peer)", f"{D}App.svelte:1815"),
    Pair("border-strong", "paper", "non-text", L, "text field boundary (manual pairing code, rename input)", f"{A}ScanScreen.kt:252; {D}App.svelte:1744; {D}lib/components/ui/button/button.svelte:24"),
    Pair("border", "paper", "decorative", L, "card outline; unselected album card outline (cover image + check badge identify it)", f"{A}HomeScreen.kt:763; {A}BucketScreen.kt:155; {I}Home/BucketScreen.swift:77; {D}Wizard.svelte:60"),
    Pair("ink-40", "hairline", "non-text", L, "M3 switch off-state thumb/outline on hairline track", f"{A}Theme.kt:57-60"),
    Pair("divider", "paper", "decorative", L, "row divider", f"{A}HomeScreen.kt:782; {I}Design/PPStyle.swift:252"),
    Pair("hairline", "paper", "decorative", L, "site header/footer rule", f"{S}layouts/Base.astro:133"),
    # ---- linen / canvas / idle-bg ----
    Pair("ink-60", "linen", "text", L, "photo filter chip, desktop sidebar item, iOS settings row", f"{A}PhotosScreen.kt:815; {I}Photos/PhotosScreen.swift:59; {D}lib/components/ui/nav-item/nav-item.svelte:26"),
    Pair("ink-40", "linen", "text", L, "iOS settings row hint (settings card is linen on iOS)", f"{I}Home/SettingsScreen.swift:151"),
    Pair("ink", "linen", "text", L, "iOS settings row label, desktop path code", f"{I}Home/SettingsScreen.swift:179; {D}App.svelte:1962"),
    Pair("safe", "linen", "non-text", L, "iOS Toggle on-track tint", f"{I}Home/SettingsScreen.swift:142"),
    Pair("ink-60", "canvas", "text", L, "site feature cards", f"{S}components/Landing.astro:93"),
    Pair("ink-40", "canvas", "text", L, "site FAQ index card meta", f"{S}components/Faq.astro:146"),
    Pair("ink-60", "idle-bg", "text", L, "desktop sidebar service pill (idle)", f"{D}App.svelte:2265"),
    Pair("ink-60", "hairline", "text", L, "desktop nav item hover", f"{D}lib/components/ui/nav-item/nav-item.svelte:26"),
    # ---- meaning-colour backgrounds ----
    Pair("safe", "safe-bg", "large-text", L, "home hero number 40 serif / 'backup started' 34 serif", f"{A}HomeScreen.kt:433; {A}Onboarding.kt:126; {I}Home/HeroCard.swift:68"),
    Pair("safe", "safe-bg", "text", L, "hero '/ N photos' 18 serif regular; desktop pill & toast", f"{A}HomeScreen.kt:443; {D}App.svelte:2284; {D}app.css:166"),
    Pair("safe", "safe-bg", "non-text", L, "hero progress bar", f"{A}HomeScreen.kt:545; {I}Home/HeroCard.swift:137"),
    Pair("ink", "safe-bg", "text", L, "hero number fallback ink", f"{A}HomeScreen.kt:433"),
    Pair("ink-60", "safe-bg", "text", L, "hero sub-line, progress file name", f"{A}HomeScreen.kt:458,516; {I}Home/HeroCard.swift:19"),
    Pair("ink-40", "safe-bg", "text", L, "'backup started' footnote", f"{A}Onboarding.kt:137; {I}Home/BucketScreen.swift:167"),
    Pair("waiting", "safe-bg", "text", L, "hero 'counts don't match' title, 'slow' status line", f"{A}HomeScreen.kt:468,530; {I}Home/HeroCard.swift:26,130"),
    Pair("waiting", "safe-bg", "non-text", L, "hero progress bar (slow)", f"{A}HomeScreen.kt:545; {I}Home/HeroCard.swift:137"),
    Pair("act", "act-bg", "text", L, "red card title, desktop error banner / pill / env badge", f"{A}HomeScreen.kt:401,649; {I}Home/SettingsScreen.swift:43; {D}App.svelte:1477,2291,2422"),
    Pair("ink", "act-bg", "text", L, "red card secondary button, desktop danger card", f"{A}HomeScreen.kt:979; {D}lib/components/ui/card/card.svelte:24"),
    Pair("ink-60", "act-bg", "text", L, "red card body", f"{A}HomeScreen.kt:409; {I}Home/SettingsScreen.swift:44; {D}App.svelte:1480"),
    Pair("ink-40", "act-bg", "text", L, "'show technical details', banner small print", f"{A}HomeScreen.kt:665; {I}Home/SettingsScreen.swift:58; {D}App.svelte:1485"),
    Pair("ink", "waiting-bg", "text", L, "notice 'fix it' action", f"{A}HomeNotices.kt:143; {I}Home/SettingsScreen.swift:206"),
    Pair("ink-60", "waiting-bg", "text", L, "notice body, wizard hint, pairing banner", f"{A}HomeNotices.kt:116; {I}Home/SettingsScreen.swift:196; {D}Wizard.svelte:89"),
    Pair("ink-40", "waiting-bg", "text", L, "notice 'got it'", f"{A}HomeNotices.kt:135; {I}Home/SettingsScreen.swift:200"),
    Pair("act", "waiting-bg", "text", L, "wizard sleep card warning line", f"{D}Wizard.svelte:106-127"),
    Pair("waiting", "waiting-bg", "text", L, "desktop toast, site Beta badge (12.2px)", f"{D}app.css:166-185; {S}components/Download.astro:97"),
    Pair("border-strong", "waiting-bg", "decorative", L, "text button outline inside amber banner (label identifies it)", f"{D}App.svelte:1544-1583"),
    Pair("border-strong", "act-bg", "decorative", L, "text button outline inside red banner (label identifies it)", f"{D}App.svelte:1544-1583"),
    # ---- solid ink buttons ----
    Pair("paper", "ink", "text", L, "primary button, selected chip/tab, toast", f"{A}Onboarding.kt:38; {I}Design/PPStyle.swift:144; {D}lib/components/ui/button/button.svelte:22"),
    Pair("paper", "ink-hover", "text", L, "primary button hover/pressed", f"{I}Design/PPStyle.swift:155; {D}lib/components/ui/button/button.svelte:22"),
    Pair("paper", "act", "text", L, "destructive confirm button", f"{A}HomeScreen.kt:985"),
    # ---- dark surfaces (scan / viewer / video; site dark mode) ----
    Pair("paper", "surface-dark", "text", K, "viewer/scan title, back, size", f"{A}PhotosScreen.kt:706; {A}ScanScreen.kt:136; {I}Photos/MediaViewer.swift:42"),
    Pair("paper", "surface-dark", "non-text", K, "toolbar / share icons", f"{A}VideoScreen.kt:153; {I}Photos/MediaViewer.swift:60"),
    Pair("paper@0.62", "surface-dark", "text", K, "PaperDim: dimension, loading/failure copy, scan hint, 'enter manually'", f"{A}PhotosScreen.kt:715; {A}ScanScreen.kt:199; {I}Photos/MediaViewer.swift:44"),
    Pair("paper@0.62", "surface-dark", "non-text", K, "PaperDim status symbol / spinner", f"{I}Photos/MediaViewer.swift:190; {I}Design/PPStyle.swift:190"),
    Pair("linen", "surface-dark", "text", K, "site dark --text-secondary", f"{S}styles/global.css:121"),
    Pair("idle", "surface-dark", "text", K, "site dark --text-meta (overline, footer, FAQ detail)", f"{S}styles/global.css:122"),
    Pair("idle", "ink-hover", "text", K, "site dark --text-meta on dark card", f"{S}styles/global.css:122; {S}components/Faq.astro:308"),
    Pair("paper", "ink-hover", "text", K, "site dark body on dark card", f"{S}styles/global.css:116-124"),
    Pair("border-strong", "surface-dark", "non-text", K, "site dark FAQ chip hover outline (light-mode value not swapped)", f"{S}components/Faq.astro:200"),
]


def resolve(name: str, palette: dict[str, str]) -> RGBA:
    key, _, alpha = name.partition("@")
    if key not in palette:
        raise KeyError(f"unknown token {key!r} (not in tokens.json color)")
    c = parse_color(palette[key])
    if alpha:
        c = (c[0], c[1], c[2], c[3] * float(alpha))
    return c


def evaluate(pairs: list[Pair], palette: dict[str, str]) -> list[dict]:
    rows = []
    for p in pairs:
        if p.kind not in THRESHOLDS:
            raise ValueError(f"unknown kind {p.kind!r} for {p.fg} on {p.bg}")
        fg, bg = resolve(p.fg, palette), resolve(p.bg, palette)
        ratio = contrast_ratio(fg, bg)
        need = THRESHOLDS[p.kind]
        shown = composite(fg, bg) if fg[3] < 1.0 else fg
        rows.append({
            "family": p.family,
            "fg": p.fg,
            "bg": p.bg,
            "fg_hex": to_hex(shown),
            "bg_hex": to_hex(bg),
            "kind": p.kind,
            "criterion": CRITERION[p.kind],
            "ratio": round(ratio, 2),
            "required": need,
            "pass": True if need is None else ratio >= need,
            "use": p.use,
            "refs": p.refs,
        })
    return rows


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--strict", action="store_true", help="exit 1 when any pair fails")
    ap.add_argument("--json", action="store_true", help="print the report as JSON")
    ap.add_argument("--tokens", type=Path, default=TOKENS_JSON)
    args = ap.parse_args(argv)

    palette = {k: v["value"] for k, v in json.loads(args.tokens.read_text())["color"].items()}
    rows = evaluate(PAIRS, palette)
    failures = [r for r in rows if not r["pass"]]

    if args.json:
        print(json.dumps({"pairs": rows, "failures": len(failures)}, ensure_ascii=False, indent=2))
    else:
        for family in ("light", "dark"):
            sub = [r for r in rows if r["family"] == family]
            bad = [r for r in sub if not r["pass"]]
            print(f"== {family}: {len(sub)} pairs, {len(bad)} below threshold")
            for r in sorted(sub, key=lambda r: (r["pass"], r["ratio"])):
                need = "-" if r["required"] is None else f">={r['required']}"
                mark = "FAIL" if not r["pass"] else ("info" if r["required"] is None else "ok  ")
                print(f"  {mark} {r['ratio']:>5.2f}:1 {need:<6} {r['criterion']:<6} "
                      f"{r['fg']}({r['fg_hex']}) on {r['bg']}({r['bg_hex']})  [{r['kind']}] {r['use']}")
            print()
        print(f"{len(failures)} of {len(rows)} pairs below WCAG 2.2 AA.")

    return 1 if (args.strict and failures) else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
