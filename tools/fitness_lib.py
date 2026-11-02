"""适应度函数（architectural fitness functions）共用库：扫描仓库 + 比对登记表。

三条门禁共用的做法（check-egress.py / check-autostart.py / check-disk-growth.py）：
  1. 只看 git 跟踪的文件（--root 指向的仓库），限定在 SCAN_ROOTS 内，剔掉测试 / 生成物；
     Rust 文件从第一个 `#[cfg(test)]` 起截断（内联测试不算产品代码）。
  2. 每条规则把命中归一成一个「键」（文件路径 / 主机名 / 依赖名 / 目录名）。
  3. 与登记表逐键比对：命中但没登记 → 红（新增必须登记）；登记了却不再命中 → 红
     （登记表必须跟现状精确相等，避免成了无人维护的垃圾堆）；登记缺「用途 / 触发条件」→ 红。

登记表格式：每行 `种类|键|…|说明`，`#` 开头是注释。说明不许为空——为什么要有这一处，
是登记的全部意义。例外怎么登记见 docs/runbook/fitness.md。
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

SCAN_ROOTS = ("crates/", "apps/", "config/")
# 路径里出现这些片段 = 测试 / 样例 / 生成物，不算产品代码。
_TEST_PATH = re.compile(
    r"(/tests?/|/Tests?/|[A-Za-z]Tests?/|androidTest|/src/test/|/fixtures?/|/examples?/|/node_modules/|/target/|"
    r"/build/|/Fake/|/Debug/|(^|/)tests?\.rs$|_tests?\.rs$|\.test\.[a-z]+$|Tests?\.(kt|swift)$|"
    r"/IntegrationHost/|\.generated\.)"
)
_COMMENT = re.compile(r"^\s*(//|\*|/\*|#|<!--)")


def parse_args(desc: str) -> argparse.Namespace:
    ap = argparse.ArgumentParser(description=desc)
    ap.add_argument("--root", default=str(Path(__file__).resolve().parent.parent), help="仓库根（自测用）")
    ap.add_argument("--registry", help="登记表路径（默认 <root>/tools/<各检查的默认文件>）")
    return ap.parse_args()


def tracked_files(root: Path) -> list[str]:
    out = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z"], check=True, capture_output=True, text=True
    ).stdout
    return [p for p in out.split("\0") if p and p.startswith(SCAN_ROOTS) and not _TEST_PATH.search(p)]


def read_product(root: Path, rel: str) -> list[tuple[int, str]]:
    """返回 (行号, 行文本)，已去掉注释行；Rust 文件在 #[cfg(test)] 处截断。"""
    try:
        text = (root / rel).read_text(encoding="utf-8")
    except (UnicodeDecodeError, FileNotFoundError, IsADirectoryError):
        return []
    lines: list[tuple[int, str]] = []
    for n, line in enumerate(text.splitlines(), 1):
        if rel.endswith(".rs") and line.strip().startswith("#[cfg(test)]"):
            break
        if _COMMENT.match(line):
            continue
        lines.append((n, line))
    return lines


def load_registry(path: Path, kinds: dict[str, int]) -> dict[tuple[str, str], list[str]]:
    """kinds: 种类 -> 该种类的字段数（含种类、键、末尾说明）。返回 {(种类, 键): 其余字段}。"""
    reg: dict[tuple[str, str], list[str]] = {}
    errors: list[str] = []
    if not path.exists():
        die([f"登记表不存在：{path}"])
    for n, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = [p.strip() for p in line.split("|")]
        kind = parts[0]
        if kind not in kinds:
            errors.append(f"{path.name}:{n}: 未知种类 `{kind}`（可用：{', '.join(kinds)}）")
            continue
        if len(parts) != kinds[kind] or not all(parts):
            errors.append(f"{path.name}:{n}: `{kind}` 行必须正好 {kinds[kind]} 段、每段非空（说明不许留空）：{line}")
            continue
        key = (kind, parts[1])
        if key in reg:
            errors.append(f"{path.name}:{n}: 重复登记 {kind}|{parts[1]}")
            continue
        reg[key] = parts[2:]
    if errors:
        die(errors)
    return reg


def compare(found: dict[tuple[str, str], str], reg: dict, what: str, how: str) -> list[str]:
    """found: {键: 命中位置示例}。返回错误列表。"""
    errs = []
    for key in sorted(set(found) - set(reg)):
        errs.append(f"✗ 未登记的{what}：{key[0]}|{key[1]}（命中 {found[key]}）\n    → {how}")
    for key in sorted(set(reg) - set(found)):
        errs.append(f"✗ 登记表里有、代码里已找不到：{key[0]}|{key[1]}\n    → 删掉这一行（登记表必须与现状精确相等）")
    return errs


def die(errors: list[str]) -> None:
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)


def symbol_exists(root: Path, symbol: str) -> bool:
    """符号（函数名 / 测试名）在被扫描范围内至少出现一次（含测试文件）。"""
    r = subprocess.run(
        ["git", "-C", str(root), "grep", "-qwF", "--", symbol, "--", *[s.rstrip("/") for s in SCAN_ROOTS]],
        capture_output=True,
    )
    return r.returncode == 0
