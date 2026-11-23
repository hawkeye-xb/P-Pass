"""适应度函数（architectural fitness functions）共用库：外部物理扫描仓库 + 比对登记表。

外部物理独立性铁律（V3 #1954）：
  适应度脚本只许通过外部文件读取、正则/AST 扫描与 git 清单独立断言，严禁 import 或调用任何业务包（crates/、apps/）内的
  自判辅助函数（防止模型修改业务自判函数恒返回 true 绕过只读门禁）。`assert_zero_product_imports()` 在启动时自检。
"""
from __future__ import annotations

import argparse
import ast
import re
import subprocess
import sys
from pathlib import Path

SCAN_ROOTS = ("crates/", "apps/", "config/")
_TEST_PATH = re.compile(
    r"(/tests?/|/Tests?/|[A-Za-z]Tests?/|androidTest|/src/test/|/fixtures?/|/examples?/|/node_modules/|/target/|"
    r"/build/|/Fake/|/Debug/|(^|/)tests?\.rs$|_tests?\.rs$|\.test\.[a-z]+$|Tests?\.(kt|swift)$|"
    r"/IntegrationHost/|\.generated\.)"
)
_COMMENT = re.compile(r"^\s*(//|\*|/\*|#|<!--)")
_TRIVIAL_GUARD_BODY = re.compile(
    r"(?:\bfn\s+{sym}\s*\([^)]*\)\s*(?:->\s*bool\s*)?\{{\s*(?:return\s+)?(?:true|false)\s*;?\s*\}})"
    r"|(?:\bfun\s+{sym}\s*\([^)]*\)\s*(?::\s*Boolean\s*)?=\s*(?:true|false)\b)"
    r"|(?:\bfun\s+{sym}\s*\([^)]*\)\s*(?::\s*Boolean\s*)?\{{\s*return\s+(?:true|false)\s*;?\s*\}})"
    r"|(?:\bfunc\s+{sym}\s*\([^)]*\)\s*(?:->\s*Bool\s*)?\{{\s*(?:return\s+)?(?:true|false)\s*\}})"
)


def assert_zero_product_imports(script_file: str) -> None:
    """自检：确保门禁脚本自身 AST 零导入任何非标准库/非 fitness_lib 的业务包。"""
    tree = ast.parse(Path(script_file).read_text(encoding="utf-8"), filename=script_file)
    allowed = {"__future__", "argparse", "ast", "fnmatch", "glob", "hashlib", "json", "os", "pathlib", "re", "shutil", "subprocess", "sys", "tempfile", "fitness_lib"}
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            mods = [a.name.split(".")[0] for a in node.names]
        elif isinstance(node, ast.ImportFrom) and node.module:
            mods = [node.module.split(".")[0]]
        else:
            continue
        bad = [m for m in mods if m not in allowed]
        if bad:
            die([f"✗ 适应度门禁违反外部物理原语铁律：{script_file} 导入了外部/业务模块 {bad}"])


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
    r = subprocess.run(
        ["git", "-C", str(root), "grep", "-qwF", "--", symbol, "--", *[s.rstrip("/") for s in SCAN_ROOTS]],
        capture_output=True,
    )
    return r.returncode == 0


def guard_symbol_compromised(root: Path, symbol: str) -> str | None:
    """外部物理扫描产品代码中的守卫函数定义，拦截把守卫函数直接改成恒返回字面量 true/false 的 T5 式退化绕过。"""
    pat = re.compile(_TRIVIAL_GUARD_BODY.pattern.format(sym=re.escape(symbol)), re.S)
    for rel in tracked_files(root):
        if not rel.endswith((".rs", ".kt", ".java", ".swift")):
            continue
        stripped = "\n".join(line for _, line in read_product(root, rel))
        if pat.search(stripped):
            return rel
    return None
