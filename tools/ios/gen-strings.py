#!/usr/bin/env python3
"""Generate iOS UI strings from the Android string resources (#315).

    tools/ios/gen-strings.py           # rewrite apps/ios/PPass/Resources/{en,zh-Hans}.lproj/Localizable.*
    tools/ios/gen-strings.py --check   # exit 1 if the committed files differ from what we'd generate

Why Android's strings.xml is the source: the phone UI copy (both tabs, pairing, album picker,
viewer…) only exists in apps/android/app/src/main/res/values{,-zh}/strings.xml — assets/i18n holds
the diag/err keys and the *desktop* ui.* keys, not the phone screens. The iOS shell replicates the
Android semantics, so it reuses the same keys and the same sentences instead of a hand copy that
would silently drift. iOS-only wording (things Android says that are false on iOS — battery
whitelist, foreground service… — plus iOS-only screens such as diagnostics) lives in the
hand-written `IOS.strings` table next to the generated one; the app looks there first.

Consequence (by design): editing an Android string without re-running this script turns ci-ios red.

Conversions:
  - Android escapes \\' \\" \\@ \\? are unescaped, \\n stays a newline
  - %1$s → %1$@, %1$d → %1$ld (Swift Int is 64-bit), bare %s / %d likewise
  - <plurals> → Localizable.stringsdict (NSStringPluralRuleType; zh only has "other")
"""
from __future__ import annotations

import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[2]
RES = ROOT / "apps" / "android" / "app" / "src" / "main" / "res"
OUT = ROOT / "apps" / "ios" / "PPass" / "Resources"
LANGS = {"values": "en", "values-zh": "zh-Hans"}
HEADER = "/* 由 tools/ios/gen-strings.py 从 apps/android/app/src/main/res/{dir}/strings.xml 生成——不要手改。 */\n"

FMT_RE = re.compile(r"%(\d+\$)?([sd])")


def android_text(el: ET.Element) -> str:
    raw = "".join(el.itertext())
    out, i = [], 0
    while i < len(raw):
        c = raw[i]
        if c == "\\" and i + 1 < len(raw):
            n = raw[i + 1]
            out.append({"n": "\n", "t": "\t"}.get(n, n))
            i += 2
            continue
        out.append(c)
        i += 1
    s = "".join(out)
    if len(s) >= 2 and s[0] == '"' and s[-1] == '"':
        s = s[1:-1]
    return FMT_RE.sub(lambda m: "%" + (m.group(1) or "") + ("@" if m.group(2) == "s" else "ld"), s)


def strings_literal(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t") + '"'


def render(res_dir: str) -> tuple[str, str]:
    tree = ET.parse(RES / res_dir / "strings.xml")
    strings: list[str] = [HEADER.format(dir=res_dir)]
    plurals: list[str] = []
    for el in tree.getroot():
        name = el.get("name")
        if el.tag == "string" and name:
            strings.append(f"{strings_literal(name)} = {strings_literal(android_text(el))};\n")
        elif el.tag == "plurals" and name:
            items = {it.get("quantity"): android_text(it) for it in el.findall("item")}
            if "other" not in items:
                sys.exit(f"gen-strings: plurals {name} 缺 other（{res_dir}）")
            p = [f"\t<key>{escape(name)}</key>\n\t<dict>\n",
                 "\t\t<key>NSStringLocalizedFormatKey</key>\n\t\t<string>%#@n@</string>\n",
                 "\t\t<key>n</key>\n\t\t<dict>\n",
                 "\t\t\t<key>NSStringFormatSpecTypeKey</key>\n\t\t\t<string>NSStringPluralRuleType</string>\n",
                 "\t\t\t<key>NSStringFormatValueTypeKey</key>\n\t\t\t<string>ld</string>\n"]
            for q in ("zero", "one", "two", "few", "many", "other"):
                if q in items:
                    p.append(f"\t\t\t<key>{q}</key>\n\t\t\t<string>{escape(items[q])}</string>\n")
            p.append("\t\t</dict>\n\t</dict>\n")
            plurals.append("".join(p))
    dict_xml = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        f"<!-- 由 tools/ios/gen-strings.py 从 apps/android/app/src/main/res/{res_dir}/strings.xml 生成——不要手改。 -->\n"
        '<plist version="1.0">\n<dict>\n' + "".join(plurals) + "</dict>\n</plist>\n"
    )
    return "".join(strings), dict_xml


def main() -> int:
    check = "--check" in sys.argv[1:]
    bad = []
    for res_dir, lang in LANGS.items():
        strings, plist = render(res_dir)
        for name, text in (("Localizable.strings", strings), ("Localizable.stringsdict", plist)):
            path = OUT / f"{lang}.lproj" / name
            if check:
                if not path.exists() or path.read_text(encoding="utf-8") != text:
                    bad.append(str(path.relative_to(ROOT)))
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text, encoding="utf-8")
                print(f"wrote {path.relative_to(ROOT)}")
    if bad:
        print("✗ 与 Android strings.xml 不同步——跑 `just ios-strings` 重新生成并提交：\n  " + "\n  ".join(bad), file=sys.stderr)
        return 1
    if check:
        print("ok: iOS Localizable.* 与 Android strings.xml 同步")
    return 0


if __name__ == "__main__":
    sys.exit(main())
