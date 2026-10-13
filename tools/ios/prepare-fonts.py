#!/usr/bin/env python3
"""Prepare the iOS copies of the brand fonts from the Android ones (#315).

    tools/ios/prepare-fonts.py      # needs fontTools (pip install fonttools)

Android bundles Newsreader / Manrope (SIL OFL 1.1, MOB-66) as static instances cut from the
variable fonts, but their name tables were never updated: all three Manrope files call
themselves "Manrope-ExtraLight", all three Newsreader files "Newsreader16pt-Regular". Android
does not care (fonts are addressed by resource file); iOS registers fonts by PostScript name,
so three files with one name collapse into one face. This script copies the files and rewrites
ONLY the naming metadata (family / subfamily / full / PostScript name) to match each file's
actual weight (OS/2 usWeightClass). Glyphs, metrics and the OFL licence fields are untouched.
Output is deterministic (no timestamp recalculation) and committed; the XCTest `BrandFontTests`
proves every face resolves by its PostScript name at runtime.
"""
from __future__ import annotations

from pathlib import Path

from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "apps" / "android" / "app" / "src" / "main" / "res" / "font"
DST = ROOT / "apps" / "ios" / "PPass" / "Resources" / "Fonts"

# Android 文件 → (族名, 字重名)。字重名必须与文件的 usWeightClass 对得上（下面断言）。
FACES = {
    "manrope_regular.ttf": ("Manrope", "Regular", 400),
    "manrope_medium.ttf": ("Manrope", "Medium", 500),
    "manrope_bold.ttf": ("Manrope", "Bold", 700),
    "newsreader_regular.ttf": ("Newsreader", "Regular", 400),
    "newsreader_medium.ttf": ("Newsreader", "Medium", 500),
    "newsreader_semibold.ttf": ("Newsreader", "SemiBold", 600),
}


def main() -> None:
    DST.mkdir(parents=True, exist_ok=True)
    for src_name, (family, style, weight) in FACES.items():
        font = TTFont(SRC / src_name, recalcTimestamp=False)
        assert font["OS/2"].usWeightClass == weight, f"{src_name} usWeightClass={font['OS/2'].usWeightClass}, 期望 {weight}"
        ps = f"{family}-{style}"
        legacy_family, legacy_style = (family, style) if style in ("Regular", "Bold") else (f"{family} {style}", "Regular")
        names = font["name"]
        for rec in list(names.names):
            if rec.nameID in (1, 2, 3, 4, 6, 16, 17):
                names.removeNames(nameID=rec.nameID)
        for name_id, value in (
            (1, legacy_family), (2, legacy_style), (3, f"{ps};ios"), (4, f"{family} {style}"),
            (6, ps), (16, family), (17, style),
        ):
            names.setName(value, name_id, 3, 1, 0x409)
            names.setName(value, name_id, 1, 0, 0)
        out = DST / f"{ps}.ttf"
        font.save(out)
        print(f"wrote {out.relative_to(ROOT)}  ({ps}, weight {weight})")


if __name__ == "__main__":
    main()
