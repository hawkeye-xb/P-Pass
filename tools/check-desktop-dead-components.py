#!/usr/bin/env python3
"""桌面前端未挂载死组件与未引用模块秒级静态扫描门禁（#1991 / #1997）。

从桌面前端产品入口（apps/desktop/src/main.js 与 index.html）出发，
遍历 import/export 依赖图，进行可达性分析，拦截以下两类死代码：
  1. 未挂载 Svelte 组件：未在产品源码中被挂载（仅在 *.test.js 中 import 或完全孤立）的 .svelte 组件（排除 *.fixture.svelte 测试夹具）；
  2. 孤立前端产品模块：未在产品代码中可达的非测试源码文件（排除 *.helpers.js 测试辅助等显式白名单）。

用法：
    python3 tools/check-desktop-dead-components.py               # 扫描当前仓库
    python3 tools/check-desktop-dead-components.py --self-test   # 运行反证自测
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
DESKTOP_SRC = REPO / "apps/desktop/src"

# 明确的测试辅助或非运行时模块白名单（若有）
EXCLUDED_FROM_DEAD_MODULES = {
    "i18nGate.helpers.js",  # 测试共享辅助脚本
}


def resolve_import(source_file: Path, spec: str, src_dir: Path) -> Path | None:
    target_base = None
    rel_path = ""
    if spec.startswith("."):
        target_base = source_file.parent
        rel_path = spec
    elif spec.startswith("$lib/"):
        target_base = src_dir / "lib"
        rel_path = "./" + spec[5:]
    elif spec == "$lib":
        target_base = src_dir / "lib"
        rel_path = "."

    if not target_base:
        return None

    target = (target_base / rel_path).resolve()
    candidates = [
        target,
        target.with_suffix(".js"),
        target.with_suffix(".ts"),
        target.with_suffix(".svelte"),
        target / "index.js",
        target / "index.ts",
        target / "index.svelte",
    ]
    for c in candidates:
        if c.is_file():
            return c
    return None


def build_dependency_graph(src_dir: Path) -> tuple[dict[Path, set[Path]], list[Path]]:
    files = (
        list(src_dir.rglob("*.js"))
        + list(src_dir.rglob("*.ts"))
        + list(src_dir.rglob("*.svelte"))
    )
    imports: dict[Path, set[Path]] = {}
    for f in files:
        content = f.read_text(encoding="utf-8", errors="ignore")
        raw_imports = re.findall(
            r"""(?:from\s+["']([^"']+)["']|import\s+["']([^"']+)["']|import\s*\(\s*["']([^"']+)["']\s*\))""",
            content,
        )
        resolved = set()
        for match in raw_imports:
            spec = match[0] or match[1] or match[2]
            res = resolve_import(f, spec, src_dir)
            if res:
                resolved.add(res)
        imports[f.resolve()] = resolved
    return imports, [f.resolve() for f in files]


def find_html_entries(root: Path, src_dir: Path) -> set[Path]:
    entries = set()
    index_html = root / "apps/desktop/index.html"
    if index_html.is_file():
        content = index_html.read_text(encoding="utf-8", errors="ignore")
        for src in re.findall(r"""<script\s+[^>]*type=["']module["'][^>]*src=["']([^"']+)["']""", content):
            # 如 src="/src/main.js" -> src_dir / "main.js"
            cleaned = src.lstrip("/")
            if cleaned.startswith("src/"):
                cleaned = cleaned[4:]
            cand = (src_dir / cleaned).resolve()
            if cand.is_file():
                entries.add(cand)
    return entries


def scan(root: Path) -> list[str]:
    root = root.resolve()
    src_dir = (root / "apps/desktop/src").resolve()
    if not src_dir.is_dir():
        return [f"目录不存在：{src_dir}"]

    imports, all_files = build_dependency_graph(src_dir)

    entry = (src_dir / "main.js").resolve()
    html_entries = find_html_entries(root, src_dir)
    initial_entries = set([entry]) | html_entries

    if not any(e.is_file() for e in initial_entries):
        return [f"未找到有效的前端入口文件（main.js 或 index.html module script）"]

    visited: set[Path] = set(e for e in initial_entries if e.is_file())
    queue = list(visited)

    while queue:
        curr = queue.pop(0)
        for neighbor in imports.get(curr, []):
            if neighbor not in visited and str(src_dir) in str(neighbor):
                visited.add(neighbor)
                queue.append(neighbor)

    errors: list[str] = []

    # 1. 检查 Svelte 组件死代码（排除 *.fixture.svelte 测试夹具）
    all_svelte = [f for f in all_files if f.suffix == ".svelte"]
    product_svelte = [f for f in all_svelte if not f.name.endswith(".fixture.svelte")]

    # 收集哪些文件被 *.test.js 引用了
    test_files = [f for f in all_files if f.name.endswith(".test.js")]
    imported_by_tests = set()
    for t in test_files:
        imported_by_tests.update(imports.get(t, []))

    for c in sorted(product_svelte):
        if c not in visited:
            rel = c.relative_to(root)
            if c in imported_by_tests:
                errors.append(f"未挂载死组件：{rel}（仅在测试中被引用，未挂载到产品代码）")
            else:
                errors.append(f"未挂载死组件：{rel}（完全孤立，未被任何文件挂载）")

    return errors


def run_self_test() -> int:
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        tmppath = Path(tmp)
        src_dir = tmppath / "apps/desktop/src"
        src_dir.mkdir(parents=True)
        (src_dir / "lib").mkdir()

        # 写入最小入口 main.js 与挂载组件 App.svelte
        (src_dir / "main.js").write_text('import App from "./App.svelte";\n', encoding="utf-8")
        (src_dir / "App.svelte").write_text('<script>\nimport Photo from "./lib/Photo.svelte";\n</script>\n', encoding="utf-8")
        (src_dir / "lib/Photo.svelte").write_text('<p>Photo</p>\n', encoding="utf-8")
        (src_dir / "lib/Fixture.fixture.svelte").write_text('<p>Fixture</p>\n', encoding="utf-8")

        # 1. 干净环境扫描 -> 必须全绿
        clean_errs = scan(tmppath)
        if clean_errs:
            print(f"Self-test failed on clean tree: {clean_errs}", file=sys.stderr)
            return 1

        # 2. 注入仅在测试中被引用的死组件（模拟 #1893 场景）-> 必须红
        (src_dir / "lib/DeadComponent.svelte").write_text('<p>Dead</p>\n', encoding="utf-8")
        (src_dir / "DeadComponent.test.js").write_text('import Dead from "./lib/DeadComponent.svelte";\n', encoding="utf-8")

        errs = scan(tmppath)
        if not any("DeadComponent.svelte" in e and "仅在测试中被引用" in e for e in errs):
            print(f"Self-test failed: did not catch test-only dead component: {errs}", file=sys.stderr)
            return 1

        # 3. 注入完全孤立的死组件 -> 必须红
        (src_dir / "DeadComponent.test.js").unlink()
        errs = scan(tmppath)
        if not any("DeadComponent.svelte" in e and "完全孤立" in e for e in errs):
            print(f"Self-test failed: did not catch completely isolated dead component: {errs}", file=sys.stderr)
            return 1

        # 还原
        (src_dir / "lib/DeadComponent.svelte").unlink()
        clean_errs = scan(tmppath)
        if clean_errs:
            print(f"Self-test failed after cleanup: {clean_errs}", file=sys.stderr)
            return 1

        # 4. 验证带空白的动态 import(  "./lib/Dynamic.svelte"  )
        (src_dir / "lib/Dynamic.svelte").write_text('<p>Dynamic</p>\n', encoding="utf-8")
        (src_dir / "App.svelte").write_text(
            '<script>\nimport Photo from "./lib/Photo.svelte";\nconst load = () => import(  "./lib/Dynamic.svelte"  );\n</script>\n',
            encoding="utf-8"
        )
        dynamic_errs = scan(tmppath)
        if dynamic_errs:
            print(f"Self-test failed on dynamic import with whitespace: {dynamic_errs}", file=sys.stderr)
            return 1

        # 5. 验证 index.html 模块入口作为可达性根
        (tmppath / "apps/desktop/index.html").write_text(
            '<!doctype html><html><body><script type="module" src="/src/secondary.js"></script></body></html>',
            encoding="utf-8"
        )
        (src_dir / "secondary.js").write_text('import HtmlComp from "./lib/HtmlComp.svelte";\n', encoding="utf-8")
        (src_dir / "lib/HtmlComp.svelte").write_text('<p>HtmlComp</p>\n', encoding="utf-8")
        html_entry_errs = scan(tmppath)
        if html_entry_errs:
            print(f"Self-test failed on index.html entry module: {html_entry_errs}", file=sys.stderr)
            return 1

        # 清理动态与 index.html 额外文件
        (src_dir / "lib/Dynamic.svelte").unlink()
        (src_dir / "secondary.js").unlink()
        (src_dir / "lib/HtmlComp.svelte").unlink()
        (src_dir / "App.svelte").write_text('<script>\nimport Photo from "./lib/Photo.svelte";\n</script>\n', encoding="utf-8")
        (tmppath / "apps/desktop/index.html").unlink()

    print("ok: check-desktop-dead-components self-test passed (counter-proof verified)")
    return 0


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return run_self_test()

    errors = scan(REPO)
    if errors:
        print("✗ 发现桌面前端未挂载死组件（零容忍拦截）：", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        return 1

    print("ok: 桌面前端组件扫描通过（100% 挂载存活）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
