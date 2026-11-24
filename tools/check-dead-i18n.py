#!/usr/bin/env python3
"""四端零引用死词条秒级静态门禁（#1991 / #1997）。

在毫秒级（通常 < 0.3s）内精准扫描四端全部文案资源，零容忍拦截零引用死词条：
  1. strings.xml：两部手机共用文案，必须在 Android src/main 或 iOS 产品源码中被引用；
  2. strings_android_only.xml：Android 独有文案，必须在 Android src/main 中被引用；
  3. IOS.strings：iOS 独有文案，必须在 iOS 产品源码中被引用；
  4. apps/desktop/src/i18n/*.json：桌面前端字典，en/zh key 严格对齐，且必须在桌面前端产品源码或 Rust crates 中被引用；
  5. assets/i18n/*.json：跨端字典（diag/err），必须在全仓产品代码中被引用。

用法：
    python3 tools/check-dead-i18n.py               # 扫描当前仓库，发现死词条 exit 1
    python3 tools/check-dead-i18n.py --self-test   # 运行反证自测
"""
from __future__ import annotations

import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
WORD = re.compile(r"[a-zA-Z0-9_]+")


def get_xml_keys(path: Path) -> set[str]:
    if not path.is_file():
        return set()
    tree = ET.parse(path)
    return {el.get("name") for el in tree.getroot() if el.get("name")}


def get_ios_strings_keys(path: Path) -> set[str]:
    if not path.is_file():
        return set()
    keys = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith('"') and "=" in line:
            keys.add(line.split("=")[0].strip().strip('"'))
    return keys


def load_json_keys(path: Path) -> set[str]:
    if not path.is_file():
        return set()
    return set(json.loads(path.read_text(encoding="utf-8")).keys())


COMMENT_RE = re.compile(r"//.*?$|/\*.*?\*/", re.MULTILINE | re.DOTALL)
DOTTED_WORD = re.compile(r"[a-zA-Z0-9_.-]+")


def strip_comments(text: str) -> str:
    return COMMENT_RE.sub("", text)


def extract_tokens(files: list[Path]) -> set[str]:
    tokens = set()
    for f in files:
        txt = f.read_text(encoding="utf-8", errors="ignore")
        if f.suffix in (".kt", ".java", ".swift", ".m", ".h", ".rs", ".js", ".svelte", ".ts"):
            txt = strip_comments(txt)
        tokens.update(WORD.findall(txt))
    return tokens


def scan(root: Path) -> list[str]:
    errors: list[str] = []

    # 1. 加载资源词条集合
    strings_en = root / "apps/android/app/src/main/res/values/strings.xml"
    android_only_en = root / "apps/android/app/src/main/res/values/strings_android_only.xml"
    ios_strings_zh = root / "apps/ios/PPass/Resources/zh-Hans.lproj/IOS.strings"
    desk_en_path = root / "apps/desktop/src/i18n/en.json"
    desk_zh_path = root / "apps/desktop/src/i18n/zh.json"
    shared_en_path = root / "assets/i18n/en.json"

    strings_keys = get_xml_keys(strings_en)
    android_only_keys = get_xml_keys(android_only_en)
    ios_keys = get_ios_strings_keys(ios_strings_zh)
    desk_en_keys = load_json_keys(desk_en_path)
    desk_zh_keys = load_json_keys(desk_zh_path)
    shared_keys = load_json_keys(shared_en_path)

    # 检查桌面 en/zh 字典 key 严格一致
    if desk_en_keys != desk_zh_keys:
        diff = sorted(desk_en_keys ^ desk_zh_keys)
        errors.append(f"桌面前端字典 en/zh 键集不一致：{diff[:10]}")

    # 2. 收集移动端代码语料（排除测试与文案资源自身）
    android_files = [
        p for p in (root / "apps/android/app/src/main").rglob("*")
        if p.is_file() and p.suffix in (".kt", ".java", ".xml") and "strings" not in p.name
    ]
    ios_files = [
        p for p in (root / "apps/ios").rglob("*")
        if p.is_file()
        and not any(part in ("Tests", "PPassTests", "PPassCoreTests") for part in p.parts)
        and not p.name.endswith("Tests.swift")
        and p.suffix in (".swift", ".m", ".h", ".plist")
        and not p.name.endswith(".strings")
        and not p.name.endswith(".stringsdict")
    ]

    android_tokens = extract_tokens(android_files)
    ios_tokens = extract_tokens(ios_files)
    mobile_tokens = android_tokens | ios_tokens

    android_text = "\n".join(strip_comments(p.read_text(encoding="utf-8", errors="ignore")) if p.suffix in (".kt", ".java") else p.read_text(encoding="utf-8", errors="ignore") for p in android_files)
    ios_text = "\n".join(strip_comments(p.read_text(encoding="utf-8", errors="ignore")) if p.suffix in (".swift", ".m", ".h") else p.read_text(encoding="utf-8", errors="ignore") for p in ios_files)
    mobile_corpus = android_text + "\n" + ios_text

    # 3. 收集桌面端源码与 Rust crates 语料（快速匹配）
    desk_files = [
        p for p in (root / "apps/desktop/src").rglob("*")
        if p.is_file() and not p.name.endswith(".test.js") and "i18n" not in p.parts
    ]
    desk_text = "\n".join(strip_comments(p.read_text(encoding="utf-8", errors="ignore")) for p in desk_files)
    desk_html = ""
    index_html = root / "apps/desktop/index.html"
    if index_html.is_file():
        desk_html = index_html.read_text(encoding="utf-8", errors="ignore")

    rust_files = [
        p for p in list((root / "crates").rglob("*.rs")) + list((root / "apps/desktop/src-tauri").rglob("*.rs"))
        if p.is_file()
        and not any(part == "tests" for part in p.parts)
        and not p.name.endswith("_test.rs")
        and not p.name.endswith("test.rs")
    ]
    rust_text = "\n".join(strip_comments(p.read_text(encoding="utf-8", errors="ignore")) for p in rust_files)
    desk_corpus = desk_text + "\n" + desk_html + "\n" + rust_text
    desktop_dotted_tokens = set(DOTTED_WORD.findall(desk_corpus))
    global_dotted_tokens = desktop_dotted_tokens | set(DOTTED_WORD.findall(mobile_corpus))

    # 4. 判定死词条
    # (a) strings.xml：在 Android src/main 或 iOS 产品源码中出现即存活
    dead_strings = [k for k in sorted(strings_keys) if k not in mobile_tokens]
    if dead_strings:
        errors.append(f"apps/android/.../strings.xml 存在零引用死词条（{len(dead_strings)} 个）：{dead_strings[:10]}")

    # (b) strings_android_only.xml：必须在 Android src/main 中出现
    dead_android_only = [k for k in sorted(android_only_keys) if k not in android_tokens]
    if dead_android_only:
        errors.append(f"apps/android/.../strings_android_only.xml 存在零引用死词条（{len(dead_android_only)} 个）：{dead_android_only[:10]}")

    # (c) IOS.strings：必须在 iOS 产品源码中出现
    dead_ios = [k for k in sorted(ios_keys) if k not in ios_tokens]
    if dead_ios:
        errors.append(f"apps/ios/.../IOS.strings 存在零引用死词条（{len(dead_ios)} 个）：{dead_ios[:10]}")

    # (d) apps/desktop/src/i18n/*.json：必须在桌面前端产品源码或 Rust 中出现（按完整键匹配，不跨端借用移动端 token）
    dead_desk = [k for k in sorted(desk_en_keys) if k not in desktop_dotted_tokens]
    if dead_desk:
        errors.append(f"apps/desktop/src/i18n/*.json 存在零引用死词条（{len(dead_desk)} 个）：{dead_desk[:10]}")

    # (e) assets/i18n/*.json：跨端词条，必须在全仓产品代码中出现
    dead_shared = [k for k in sorted(shared_keys) if k not in global_dotted_tokens]
    if dead_shared:
        errors.append(f"assets/i18n/*.json 存在零引用死词条（{len(dead_shared)} 个）：{dead_shared[:10]}")

    return errors


def run_self_test() -> int:
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        tmppath = Path(tmp)
        (tmppath / "apps/android/app/src/main/res/values").mkdir(parents=True)
        (tmppath / "apps/android/app/src/main/res/values-zh").mkdir(parents=True)
        (tmppath / "apps/ios/PPass/Resources/zh-Hans.lproj").mkdir(parents=True)
        (tmppath / "apps/desktop/src/i18n").mkdir(parents=True)
        (tmppath / "assets/i18n").mkdir(parents=True)

        # 写入存活词条定义
        (tmppath / "apps/android/app/src/main/res/values/strings.xml").write_text(
            '<resources><string name="test_shared">Hello</string></resources>', encoding="utf-8"
        )
        (tmppath / "apps/android/app/src/main/res/values/strings_android_only.xml").write_text(
            '<resources><string name="test_android_only">Android</string></resources>', encoding="utf-8"
        )
        (tmppath / "apps/ios/PPass/Resources/zh-Hans.lproj/IOS.strings").write_text(
            '"test_ios_only" = "iOS";\n', encoding="utf-8"
        )
        (tmppath / "apps/desktop/src/i18n/en.json").write_text('{"ui.test_desk": "Desk"}', encoding="utf-8")
        (tmppath / "apps/desktop/src/i18n/zh.json").write_text('{"ui.test_desk": "桌面"}', encoding="utf-8")
        (tmppath / "assets/i18n/en.json").write_text('{"err.test_shared": "Error"}', encoding="utf-8")

        # 写入源码引用
        (tmppath / "apps/android/app/src/main/Test.kt").write_text(
            'val a = R.string.test_shared\nval b = R.string.test_android_only\nval c = "err.test_shared"', encoding="utf-8"
        )
        (tmppath / "apps/ios/PPass/Test.swift").write_text('let x = "test_ios_only"', encoding="utf-8")
        (tmppath / "apps/desktop/src/Test.svelte").write_text('<span>{t("ui.test_desk")}</span>', encoding="utf-8")

        # 1. 验证干净目录全绿
        clean_errs = scan(tmppath)
        if clean_errs:
            print(f"Self-test failed on clean tree: {clean_errs}", file=sys.stderr)
            return 1

        # 2. 注入 strings.xml 死词条 -> 必须红
        (tmppath / "apps/android/app/src/main/res/values/strings.xml").write_text(
            '<resources><string name="test_shared">Hello</string><string name="dead_shared_key">Dead</string></resources>', encoding="utf-8"
        )
        errs = scan(tmppath)
        if not any("strings.xml" in e and "dead_shared_key" in e for e in errs):
            print("Self-test failed: did not catch dead key in strings.xml", file=sys.stderr)
            return 1

        # 还原
        (tmppath / "apps/android/app/src/main/res/values/strings.xml").write_text(
            '<resources><string name="test_shared">Hello</string></resources>', encoding="utf-8"
        )

        # 3. 注入 strings_android_only.xml 死词条 -> 必须红
        (tmppath / "apps/android/app/src/main/res/values/strings_android_only.xml").write_text(
            '<resources><string name="test_android_only">Android</string><string name="dead_android_key">Dead</string></resources>', encoding="utf-8"
        )
        errs = scan(tmppath)
        if not any("strings_android_only.xml" in e and "dead_android_key" in e for e in errs):
            print("Self-test failed: did not catch dead key in strings_android_only.xml", file=sys.stderr)
            return 1

        # 还原
        (tmppath / "apps/android/app/src/main/res/values/strings_android_only.xml").write_text(
            '<resources><string name="test_android_only">Android</string></resources>', encoding="utf-8"
        )

        # 4. 注入 IOS.strings 死词条 -> 必须红
        (tmppath / "apps/ios/PPass/Resources/zh-Hans.lproj/IOS.strings").write_text(
            '"test_ios_only" = "iOS";\n"dead_ios_key" = "Dead";\n', encoding="utf-8"
        )
        errs = scan(tmppath)
        if not any("IOS.strings" in e and "dead_ios_key" in e for e in errs):
            print("Self-test failed: did not catch dead key in IOS.strings", file=sys.stderr)
            return 1

        # 还原
        (tmppath / "apps/ios/PPass/Resources/zh-Hans.lproj/IOS.strings").write_text(
            '"test_ios_only" = "iOS";\n', encoding="utf-8"
        )

        # 5. 注入桌面字典死词条 -> 必须红
        (tmppath / "apps/desktop/src/i18n/en.json").write_text('{"ui.test_desk": "Desk", "ui.dead_desk_key": "Dead"}', encoding="utf-8")
        (tmppath / "apps/desktop/src/i18n/zh.json").write_text('{"ui.test_desk": "桌面", "ui.dead_desk_key": "死"}', encoding="utf-8")
        errs = scan(tmppath)
        if not any("apps/desktop/src/i18n" in e and "ui.dead_desk_key" in e for e in errs):
            print("Self-test failed: did not catch dead key in apps/desktop/src/i18n", file=sys.stderr)
            return 1

        # 还原
        (tmppath / "apps/desktop/src/i18n/en.json").write_text('{"ui.test_desk": "Desk"}', encoding="utf-8")
        (tmppath / "apps/desktop/src/i18n/zh.json").write_text('{"ui.test_desk": "桌面"}', encoding="utf-8")

        # 6. 注入桌面 en/zh 不一致 -> 必须红
        (tmppath / "apps/desktop/src/i18n/zh.json").write_text('{"ui.test_desk": "桌面", "ui.mismatch": "不一致"}', encoding="utf-8")
        errs = scan(tmppath)
        if not any("en/zh 键集不一致" in e for e in errs):
            print("Self-test failed: did not catch desk en/zh mismatch", file=sys.stderr)
            return 1

        # 还原
        (tmppath / "apps/desktop/src/i18n/zh.json").write_text('{"ui.test_desk": "桌面"}', encoding="utf-8")

        # 7. 反例：注释中的引用不能保活词条 -> 必须红
        (tmppath / "apps/android/app/src/main/res/values/strings.xml").write_text(
            '<resources><string name="test_shared">Hello</string><string name="comment_only_key">Dead</string></resources>', encoding="utf-8"
        )
        (tmppath / "apps/android/app/src/main/CommentTest.kt").write_text(
            '// R.string.comment_only_key\n/* R.string.comment_only_key */\n', encoding="utf-8"
        )
        errs = scan(tmppath)
        if not any("comment_only_key" in e for e in errs):
            print("Self-test failed: comment reference wrongly kept key alive", file=sys.stderr)
            return 1

        # 还原
        (tmppath / "apps/android/app/src/main/res/values/strings.xml").write_text(
            '<resources><string name="test_shared">Hello</string></resources>', encoding="utf-8"
        )
        (tmppath / "apps/android/app/src/main/CommentTest.kt").unlink()

        # 8. 反例：前缀子串不能保活词条（如 ui.test 不能因 ui.test_desk 存活） -> 必须红
        (tmppath / "apps/desktop/src/i18n/en.json").write_text('{"ui.test_desk": "Desk", "ui.test": "Dead"}', encoding="utf-8")
        (tmppath / "apps/desktop/src/i18n/zh.json").write_text('{"ui.test_desk": "桌面", "ui.test": "死"}', encoding="utf-8")
        errs = scan(tmppath)
        # 精确断言死词条列表包含 ui.test，且存活词条 ui.test_desk 不被误报
        dead_list_str = " ".join(e for e in errs if "apps/desktop/src/i18n" in e)
        if "'ui.test'" not in dead_list_str or "'ui.test_desk'" in dead_list_str:
            print("Self-test failed: prefix substring wrongly kept key alive or misreported alive key", file=sys.stderr)
            return 1

        # 还原
        (tmppath / "apps/desktop/src/i18n/en.json").write_text('{"ui.test_desk": "Desk"}', encoding="utf-8")
        (tmppath / "apps/desktop/src/i18n/zh.json").write_text('{"ui.test_desk": "桌面"}', encoding="utf-8")

        # 9. 反例：桌面词条仅在移动端源码出现，不能被误判为存活 -> 必须红
        (tmppath / "apps/desktop/src/i18n/en.json").write_text('{"ui.test_desk": "Desk", "ui.mobile_only": "Mobile"}', encoding="utf-8")
        (tmppath / "apps/desktop/src/i18n/zh.json").write_text('{"ui.test_desk": "桌面", "ui.mobile_only": "移动"}', encoding="utf-8")
        (tmppath / "apps/android/app/src/main/MobileOnly.kt").write_text('val s = "ui.mobile_only"\n', encoding="utf-8")
        errs = scan(tmppath)
        if not any("apps/desktop/src/i18n" in e and "ui.mobile_only" in e for e in errs):
            print("Self-test failed: mobile-only reference wrongly kept desktop key alive", file=sys.stderr)
            return 1

        # 还原
        (tmppath / "apps/desktop/src/i18n/en.json").write_text('{"ui.test_desk": "Desk"}', encoding="utf-8")
        (tmppath / "apps/desktop/src/i18n/zh.json").write_text('{"ui.test_desk": "桌面"}', encoding="utf-8")
        (tmppath / "apps/android/app/src/main/MobileOnly.kt").unlink()

    print("ok: check-dead-i18n self-test passed (all counter-proof cases red, clean pass)")
    return 0


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return run_self_test()

    errors = scan(REPO)
    if errors:
        print("✗ 发现未引用的死词条（零容忍拦截）：", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        print("\n请从对应文案资源中清理死词条；若改动了 strings.xml，请运行 `python3 tools/ios/gen-strings.py` 刷新 iOS 副本。", file=sys.stderr)
        return 1

    print("ok: 四端词条零引用死词条扫描通过（四端资源 100% 存活）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
