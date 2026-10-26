#!/usr/bin/env python3
"""#937: Apple 隐私清单（PrivacyInfo.xcprivacy）不许漏报 required-reason API。

Apple 要求：App 自己或链接进来的代码用到「需要理由的 API」时，清单里必须声明
对应类别和理由，否则提审会被拒（ITMS-91053）。这类遗漏只在提审时才暴露，
所以在 ci-ios 上提前挡。

两个来源：
  1. Swift 源码（apps/ios，排除测试）：按调用名匹配；
  2. Rust 静态库 libtransport.a（--lib）：用 llvm-nm 列未定义符号，按 libc 函数名匹配。
     Rust 的 std::fs::metadata 底层就是 stat，源码里看不出来，只能看符号。

只查「用到了却没声明」（会被拒）。声明了但没扫到只打印提示：理由可能来自
扫描覆盖不到的路径，删除声明要人来判断。

用法：
  tools/ios/check-privacy-manifest.py                     # 只查 Swift
  tools/ios/check-privacy-manifest.py --lib <libtransport.a> [--nm <llvm-nm>]
  tools/ios/check-privacy-manifest.py --self-test
"""
from __future__ import annotations

import argparse
import plistlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "apps/ios/PPass/Resources/PrivacyInfo.xcprivacy"
SWIFT_ROOT = ROOT / "apps/ios"

CAT = "NSPrivacyAccessedAPICategory"

# Swift 调用名 → 类别。PhotoKit 的 PHAsset.creationDate / modificationDate 是照片元数据，
# 不属于文件时间戳类别，所以这里只认文件系统的 key 与 FileManager 调用。
SWIFT_RULES: list[tuple[str, re.Pattern[str]]] = [
    (CAT + "UserDefaults", re.compile(r"\bUserDefaults\b|@AppStorage\b")),
    (CAT + "SystemBootTime", re.compile(r"\bsystemUptime\b|\bmach_absolute_time\b")),
    (CAT + "FileTimestamp", re.compile(
        r"\battributesOfItem\b|\.(creationDate|contentModificationDate|contentAccessDate|"
        r"attributeModificationDate)Key\b|\bfileModificationDate\b|\bgetattrlist\w*\b")),
    (CAT + "DiskSpace", re.compile(
        r"\bvolume(Available|Total)Capacity\w*Key\b|\bsystemFreeSize\b|\bsystemSize\b|\bstatv?fs\b")),
    (CAT + "ActiveKeyboards", re.compile(r"\bactiveInputModes\b")),
]

# 静态库未定义符号（Mach-O 带前导下划线，可能有 $INODE64 后缀）→ 类别。
SYMBOL_RULES: list[tuple[str, re.Pattern[str]]] = [
    (CAT + "FileTimestamp", re.compile(r"^_(f?stat|lstat|fstatat|f?getattrlist|getattrlistat|getattrlistbulk)(\$INODE64)?$")),
    (CAT + "DiskSpace", re.compile(r"^_(f?statfs|f?statvfs)(64)?(\$INODE64)?$")),
    (CAT + "SystemBootTime", re.compile(r"^_mach_absolute_time$")),
]


def declared(manifest: dict) -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    for entry in manifest.get("NSPrivacyAccessedAPITypes", []):
        out[entry.get("NSPrivacyAccessedAPIType", "")] = list(entry.get("NSPrivacyAccessedAPITypeReasons", []))
    return out


def scan_swift(files: dict[str, str]) -> dict[str, list[str]]:
    hits: dict[str, list[str]] = {}
    for path, text in files.items():
        for lineno, line in enumerate(text.splitlines(), 1):
            code = line.split("//", 1)[0]
            for cat, pat in SWIFT_RULES:
                if pat.search(code):
                    hits.setdefault(cat, []).append(f"{path}:{lineno}")
    return hits


def scan_symbols(symbols: list[str]) -> dict[str, list[str]]:
    hits: dict[str, list[str]] = {}
    for sym in sorted(set(symbols)):
        for cat, pat in SYMBOL_RULES:
            if pat.match(sym):
                hits.setdefault(cat, []).append(sym)
    return hits


def check(decl: dict[str, list[str]], hits: dict[str, list[str]]) -> list[str]:
    errors = []
    for cat, reasons in decl.items():
        if not reasons:
            errors.append(f"{cat} 已声明但没有填理由")
    for cat, where in sorted(hits.items()):
        if cat not in decl:
            shown = ", ".join(where[:5]) + (" …" if len(where) > 5 else "")
            errors.append(f"用到了 {cat} 却没在清单里声明：{shown}")
    return errors


def swift_sources() -> dict[str, str]:
    files = {}
    for p in sorted(SWIFT_ROOT.rglob("*.swift")):
        rel = p.relative_to(ROOT).as_posix()
        if "/Tests/" in rel or "Tests/" in p.parent.name or "/Generated/" in rel or "/.build/" in rel:
            continue
        files[rel] = p.read_text(encoding="utf-8", errors="replace")
    return files


def undefined_symbols(lib: Path, nm: str) -> list[str]:
    proc = subprocess.run([nm, "-u", "-j", str(lib)], capture_output=True, text=True)
    if proc.returncode != 0 and not proc.stdout:
        sys.exit(f"✗ {nm} 读不了 {lib}：{proc.stderr.strip()[:300]}")
    return [s.strip() for s in proc.stdout.splitlines() if s.strip() and not s.endswith(":")]


def self_test() -> int:
    """反证：判据在该红的时候必须红。"""
    ok = True

    def expect(name: str, decl: dict, hits: dict, want_errors: bool) -> None:
        nonlocal ok
        got = bool(check(decl, hits))
        mark = "✅" if got == want_errors else "❌"
        ok &= got == want_errors
        print(f"  {mark} {name}（{'红' if got else '绿'}）")

    ud = {CAT + "UserDefaults": ["CA92.1"]}
    print("==> #937 隐私清单门禁反证")
    expect("A Swift 用 UserDefaults、已声明 → 绿", ud,
           scan_swift({"a.swift": "UserDefaults.standard.set(1, forKey: k)"}), False)
    expect("B Swift 用 UserDefaults、未声明 → 红", {},
           scan_swift({"a.swift": "UserDefaults.standard.set(1, forKey: k)"}), True)
    expect("C 只出现在注释里 → 绿", {},
           scan_swift({"a.swift": "let x = 1 // UserDefaults 不用"}), False)
    expect("D PHAsset.creationDate 不算文件时间戳 → 绿", {},
           scan_swift({"a.swift": "let d = asset.creationDate"}), False)
    expect("E systemUptime 未声明 → 红", {},
           scan_swift({"a.swift": "ProcessInfo.processInfo.systemUptime"}), True)
    expect("F 静态库引用 _stat、未声明文件时间戳 → 红", {},
           scan_symbols(["_stat", "_malloc"]), True)
    expect("G 静态库引用 _fstatfs、未声明磁盘空间 → 红", {CAT + "FileTimestamp": ["C617.1"]},
           scan_symbols(["_fstatfs"]), True)
    expect("H 已声明但理由为空 → 红", {CAT + "UserDefaults": []}, {}, True)
    expect("I 静态库只引用 _clock_gettime（不在清单类别内）→ 绿", {},
           scan_symbols(["_clock_gettime", "_sysctlbyname"]), False)
    if not ok:
        print("✗ 反证未通过：门禁在该红的时候没红", file=sys.stderr)
        return 1
    print("ok: 九个变异全部符合期望，门禁判据有效")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", type=Path, help="libtransport.a 路径（设备切片）")
    ap.add_argument("--nm", default="llvm-nm", help="能读 Rust 目标文件的 llvm-nm（Xcode 自带的 nm 读不了新版 rustc 产物）")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    decl = declared(plistlib.loads(MANIFEST.read_bytes()))
    hits = scan_swift(swift_sources())
    if args.lib:
        for cat, syms in scan_symbols(undefined_symbols(args.lib, args.nm)).items():
            hits.setdefault(cat, []).extend(f"{args.lib.name}:{s}" for s in syms)

    for cat in sorted(set(decl) - set(hits)):
        print(f"提示：{cat} 已声明，本次扫描没看到用法（未加 --lib 时 Rust 侧不在扫描范围）")
    errors = check(decl, hits)
    if errors:
        for e in errors:
            print(f"✗ {e}", file=sys.stderr)
        print(f"\n改 {MANIFEST.relative_to(ROOT)}，理由代码见 docs/runbook/ios-app-privacy.md", file=sys.stderr)
        return 1
    scope = "Swift + " + args.lib.name if args.lib else "Swift"
    print(f"ok: 隐私清单覆盖了 {scope} 用到的全部 required-reason API 类别：{', '.join(sorted(hits))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
