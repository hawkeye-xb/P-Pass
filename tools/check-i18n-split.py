#!/usr/bin/env python3
"""文案按端拆分（#1302）的归属门禁：每个 key 住在对的那一份里，每个消费方都能在它实际加载的那份里查到。

    tools/check-i18n-split.py              # 检查仓库，红了 exit 1
    tools/check-i18n-split.py --self-test  # 反证：造几种放错的仓库，每种都必须红

为什么要这道门：发版按文件归属到端（tools/check-version-bump.sh）。key 放错文件不会编译失败，
只会在界面上静默退回 key 名（托盘 tray_text、daemon ui_text、iOS L.s 都是这个兜底），
或者让改一端文案又牵动别的端。

查四件事：
  1. 跨端集合 assets/i18n 与桌面字典 apps/desktop/src/i18n：各自 en/zh 键集一致，两份不重叠。
  2. Android：strings.xml 与 strings_android_only.xml 各自 en/zh 键集一致，两份不重叠
     （同一个 key 在 values 与 values-zh 里住不同文件，iOS 的某种语言就缺这句）。
  3. iOS：Swift 源码里引用的 Android key 不许住在 strings_android_only.xml
     ——gen-strings.py 只读 strings.xml，住那里 iOS 就没有这句。
  4. 桌面壳托盘（apps/desktop/src-tauri/src/lib.rs）与 daemon 通知（crates/daemon/src/main.rs 的
     ui_text）只加载一份字典：它们引用的 ui.* key 必须在各自 include_str! 的那份里。
"""
from __future__ import annotations

import json
import re
import shutil
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
LANGS = ("en", "zh")
RES = "apps/android/app/src/main/res"
RES_DIRS = ("values", "values-zh")
KEY_LIT = re.compile(r'"([a-z][a-z0-9_]*)"')
UI_KEY_LIT = re.compile(r'"((?:ui|err|diag)\.[a-z0-9_.]+)"')
INCLUDE = re.compile(r'include_str!\("([^"]+\.json)"\)')


def load_json(root: Path, rel: str) -> dict:
    return json.loads((root / rel).read_text(encoding="utf-8"))


def android_keys(root: Path, res_dir: str, name: str) -> set[str]:
    p = root / RES / res_dir / name
    if not p.exists():
        return set()
    return {el.get("name") for el in ET.parse(p).getroot() if el.get("name")}


def check_pair(errors: list[str], label: str, a: dict[str, set[str]], b: dict[str, set[str]], a_name: str, b_name: str) -> None:
    for side, name in ((a, a_name), (b, b_name)):
        first, second = side.keys()
        if side[first] != side[second]:
            diff = sorted(side[first] ^ side[second])
            errors.append(f"{label}：{name} 的 {first}/{second} 键集不一致：{diff[:10]}")
    for lang in a:
        both = sorted(a[lang] & b[lang])
        if both:
            errors.append(f"{label}：{both[:10]} 同时在 {a_name} 与 {b_name}（{lang}）——一个 key 只许住一份")


def swift_sources(root: Path) -> str:
    return "\n".join(p.read_text(encoding="utf-8") for p in sorted((root / "apps/ios").rglob("*.swift")))


def included_dicts(root: Path, src: Path) -> dict[str, dict]:
    """src 里 include_str! 的每份字典 json（相对 src 所在目录解析）→ 内容。"""
    out = {}
    for rel in INCLUDE.findall(src.read_text(encoding="utf-8")):
        if "/i18n/" not in rel:
            continue
        p = (src.parent / rel).resolve()
        out[str(p.relative_to(root.resolve()))] = json.loads(p.read_text(encoding="utf-8"))
    return out


def check(root: Path) -> list[str]:
    errors: list[str] = []

    # 1. 跨端集合 vs 桌面字典
    shared = {l: set(load_json(root, f"assets/i18n/{l}.json")) for l in LANGS}
    desktop = {l: set(load_json(root, f"apps/desktop/src/i18n/{l}.json")) for l in LANGS}
    check_pair(errors, "桌面/跨端字典", shared, desktop, "assets/i18n", "apps/desktop/src/i18n")

    # 2. Android 两份
    phone = {d: android_keys(root, d, "strings.xml") for d in RES_DIRS}
    only = {d: android_keys(root, d, "strings_android_only.xml") for d in RES_DIRS}
    check_pair(errors, "Android 文案", phone, only, "strings.xml", "strings_android_only.xml")

    # 3. iOS 不许引用 Android 独有 key
    used = set(KEY_LIT.findall(swift_sources(root)))
    leaked = sorted(used & (only["values"] | only["values-zh"]))
    if leaked:
        errors.append(
            f"iOS 引用了只在 strings_android_only.xml 里的 key：{leaked[:10]}——gen-strings.py 不读那份，"
            "iOS 会缺这句。两部手机都要说的句子挪回 strings.xml，再跑 just ios-strings"
        )

    # 4. 只加载一份字典的 Rust 消费方
    for rel in ("apps/desktop/src-tauri/src/lib.rs", "crates/daemon/src/main.rs"):
        src = root / rel
        if not src.exists():
            continue
        dicts = included_dicts(root, src)
        text = src.read_text(encoding="utf-8")
        if "src-tauri" in rel:  # 托盘：TRAY_ITEMS 表里的 key 与 tray_text("…") 直呼的 key（ui.err_* 等交给前端 t()，不归它）
            items = re.search(r"const TRAY_ITEMS[^=]*=\s*\[(.*?)\];", text, re.S)
            refs = set(UI_KEY_LIT.findall(items.group(1))) if items else set()
            refs |= set(re.findall(r'tray_text\([^,()]*,\s*"([^"]+)"', text))
        else:
            refs = set(re.findall(r'ui_text\(\s*"([^"]+)"', text))
        if "daemon" in rel:  # daemon 经 diag::I18N_EN/ZH 查表，那两个常量指向哪份由 crates/diag 决定
            dicts = included_dicts(root, root / "crates/diag/src/lib.rs")
            dicts = {k: v for k, v in dicts.items() if k.startswith("apps/desktop/src/i18n/")} or dicts
        if not refs:
            continue
        if not dicts:
            errors.append(f"{rel}：引用了 {sorted(refs)[:5]}，却没找到它 include_str! 的字典")
            continue
        for name, d in dicts.items():
            missing = sorted(refs - set(d))
            if missing:
                errors.append(f"{rel} 只加载 {name}，里面没有它引用的 {missing[:10]}——界面会静默显示 key 名")
    return errors


def self_test() -> int:
    """反证：每种放错都必须被抓到。"""
    cases = {
        "key 同时在跨端与桌面字典": lambda r: _json_add(r, "assets/i18n/en.json", "ui.paired_count", "x")
        or _json_add(r, "assets/i18n/zh.json", "ui.paired_count", "x"),
        "桌面字典 en/zh 键集不一致": lambda r: _json_add(r, "apps/desktop/src/i18n/en.json", "ui.only_en", "x"),
        "iOS 引用的 key 挪进 strings_android_only.xml": lambda r: _move_android(r, "welcome_headline"),
        "托盘 key 只在跨端集合（托盘没 include 到）": lambda r: _json_move(r, "ui.tray_quit"),
    }
    tmp = Path(tempfile.mkdtemp())
    fails = 0
    try:
        base = tmp / "base"
        for rel in ("assets/i18n", "apps/desktop/src/i18n", RES + "/values", RES + "/values-zh", "apps/ios",
                    "apps/desktop/src-tauri/src", "crates/daemon/src", "crates/diag/src"):
            src = REPO / rel
            if src.is_dir():
                shutil.copytree(src, base / rel, ignore=shutil.ignore_patterns("*.png", "*.xcassets", "build"))
        # 托盘 include 指向哪份由第 4 条在真仓库上判；反证基线固定成拆分后的正确指向，不受它牵连。
        tray = base / "apps/desktop/src-tauri/src/lib.rs"
        if tray.exists():
            tray.write_text(re.sub(r'"(?:\.\./)+assets/i18n/(en|zh)\.json"', r'"../../src/i18n/\1.json"',
                                   tray.read_text(encoding="utf-8")), encoding="utf-8")
        baseline = check(base)
        if baseline:
            print("self-test：基线本身就红，反证无从谈起：\n  " + "\n  ".join(baseline), file=sys.stderr)
            return 1
        for name, mutate in cases.items():
            root = tmp / f"case{len(name)}{abs(hash(name))}"
            shutil.copytree(base, root)
            mutate(root)
            if check(root):
                print(f"ok  反证「{name}」⇒ 红")
            else:
                print(f"✗   反证「{name}」⇒ 没红", file=sys.stderr)
                fails += 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return 1 if fails else 0


def _json_add(root: Path, rel: str, key: str, val: str) -> None:
    p = root / rel
    d = json.loads(p.read_text(encoding="utf-8"))
    d[key] = val
    p.write_text(json.dumps(d, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _json_move(root: Path, key: str) -> None:
    for l in LANGS:
        src, dst = root / f"apps/desktop/src/i18n/{l}.json", root / f"assets/i18n/{l}.json"
        d = json.loads(src.read_text(encoding="utf-8"))
        val = d.pop(key)
        src.write_text(json.dumps(d, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        _json_add(root, f"assets/i18n/{l}.json", key, val)


def _move_android(root: Path, key: str) -> None:
    for d in RES_DIRS:
        phone, only = root / RES / d / "strings.xml", root / RES / d / "strings_android_only.xml"
        lines = phone.read_text(encoding="utf-8").split("\n")
        hit = [l for l in lines if f'name="{key}"' in l]
        phone.write_text("\n".join(l for l in lines if l not in hit), encoding="utf-8")
        only.write_text(only.read_text(encoding="utf-8").replace("</resources>", "\n".join(hit) + "\n</resources>"), encoding="utf-8")


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return self_test()
    errors = check(REPO)
    if errors:
        print("✗ 文案归属（#1302）：\n  " + "\n  ".join(errors), file=sys.stderr)
        return 1
    print("ok: 文案按端归属——跨端/桌面字典与 Android 两份各自对齐、不重叠；iOS 没引用 Android 独有 key；托盘与 daemon 的 key 都在各自加载的字典里")
    return 0


if __name__ == "__main__":
    sys.exit(main())
