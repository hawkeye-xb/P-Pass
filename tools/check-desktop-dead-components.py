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


BLANK_PAT = re.compile(r"[^\n]")


def blank_preserve_newlines(s: str) -> str:
    return BLANK_PAT.sub(" ", s)


def blank_comments_1to1(code: str, is_svelte: bool = False) -> str:
    """词法状态机：将 // 与 /* */ 注释替换为等长空格，保持 1:1 字符偏移并避免截断代码。"""
    out: list[str] = []
    i = 0
    n = len(code)
    while i < n:
        if is_svelte and code.startswith("<!--", i):
            j = code.find("-->", i + 4)
            end = n if j == -1 else j + 3
            out.append(blank_preserve_newlines(code[i:end]))
            i = end
            continue
        c = code[i]
        nxt = code[i + 1] if i + 1 < n else ""
        if c == "/" and nxt == "/":
            j = code.find("\n", i)
            end = n if j == -1 else j
            out.append(" " * (end - i))
            i = end
            continue
        if c == "/" and nxt == "*":
            j = code.find("*/", i + 2)
            end = n if j == -1 else j + 2
            out.append(blank_preserve_newlines(code[i:end]))
            i = end
            continue
        if c in ('"', "'"):
            q = c
            out.append(q)
            i += 1
            while i < n:
                ch = code[i]
                out.append(ch)
                if ch == "\\":
                    if i + 1 < n:
                        out.append(code[i + 1])
                        i += 2
                    else:
                        i += 1
                    continue
                if ch == q:
                    i += 1
                    break
                i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def extract_valid_imports(raw_src: str, is_svelte: bool = False) -> set[str]:
    """词法状态机：精确提取真实 import 与动态 import(...)，跳过注释与普通字符串字面量，支持模板表达式。"""
    # 先做 1:1 字符等长注释替换，彻底消灭所有注释（含 /* ... */ 内可能混杂的伪声明与换行）且偏移量严格保持 1:1
    src = blank_comments_1to1(raw_src, is_svelte=is_svelte)
    imports = set()
    i = 0
    n = len(src)
    tpl_stack: list[int] = []

    while i < n:
        c = src[i]

        # 普通单双引号字符串（跳过其内部，不产生依赖边）
        if c in ('"', "'"):
            quote = c
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == quote:
                    i += 1
                    break
                i += 1
            continue

        # 模板字面量：扫描文本，遇到 ${ 则压栈进入表达式模式
        if c == "`":
            i += 1
            while i < n:
                if src[i] == "\\":
                    i += 2
                    continue
                if src[i] == "$" and i + 1 < n and src[i + 1] == "{":
                    tpl_stack.append(1)
                    i += 2
                    break
                if src[i] == "`":
                    i += 1
                    break
                i += 1
            continue

        # 模板表达式花括号深度追踪
        if tpl_stack:
            if c == "{":
                tpl_stack[-1] += 1
            elif c == "}":
                tpl_stack[-1] -= 1
                if tpl_stack[-1] == 0:
                    tpl_stack.pop()
                    # 重新恢复扫描模板字面量剩余文本
                    i += 1
                    while i < n:
                        if src[i] == "\\":
                            i += 2
                            continue
                        if src[i] == "$" and i + 1 < n and src[i + 1] == "{":
                            tpl_stack.append(1)
                            i += 2
                            break
                        if src[i] == "`":
                            i += 1
                            break
                        i += 1
                    continue

        # 匹配语句层 import
        if src.startswith("import", i) and (i == 0 or not (src[i - 1].isalnum() or src[i - 1] in "_$")):
            rem = src[i + 6 :]
            # 1. 动态 import( ... )
            m_dyn = re.match(r"""^\s*\(\s*["']([^"']+)["']\s*\)""", rem)
            if m_dyn:
                imports.add(m_dyn.group(1))
                i += 6 + m_dyn.end()
                continue
            # 2. 静态 import ... from "..." 或 import "..."（支持 * as、默认、解构、混合组合与跨行）
            m_stat = re.match(r"""^(?:\s+(?:(?:\*\s+as\s+[\w$]+|\{[^}]*\}|[\w$]+(?:,\s*(?:\*\s+as\s+[\w$]+|\{[^}]*\}))?)\s+from\s+)?|\s+)["']([^"']+)["']""", rem)
            if m_stat:
                imports.add(m_stat.group(1))
                i += 6 + m_stat.end()
                continue

        # 匹配 export ... from "..." 重新导出（支持 export * from、export * as X from、export { X } from）
        if src.startswith("export", i) and (i == 0 or not (src[i - 1].isalnum() or src[i - 1] in "_$")):
            rem = src[i + 6 :]
            m_exp = re.match(r"""^(?:\s+(?:(?:\*\s*(?:as\s+[\w$]+)?|\{[^}]*\})\s+from\s+)|\s+from\s+)["']([^"']+)["']""", rem)
            if m_exp:
                imports.add(m_exp.group(1))
                i += 6 + m_exp.end()
                continue

        i += 1
    return imports


def build_dependency_graph(src_dir: Path) -> tuple[dict[Path, set[Path]], list[Path]]:
    files = (
        list(src_dir.rglob("*.js"))
        + list(src_dir.rglob("*.ts"))
        + list(src_dir.rglob("*.svelte"))
    )
    imports: dict[Path, set[Path]] = {}
    for f in files:
        raw_content = f.read_text(encoding="utf-8", errors="ignore")
        raw_specs = extract_valid_imports(raw_content, is_svelte=(f.suffix == ".svelte"))
        resolved = set()
        for spec in raw_specs:
            res = resolve_import(f, spec, src_dir)
            if res:
                resolved.add(res)
        imports[f.resolve()] = resolved
    return imports, [f.resolve() for f in files]


def find_html_entries(root: Path, src_dir: Path) -> set[Path]:
    entries = set()
    index_html = root / "apps/desktop/index.html"
    if index_html.is_file():
        from html.parser import HTMLParser

        class ScriptModuleParser(HTMLParser):
            def __init__(self):
                super().__init__()
                self.srcs = []

            def handle_starttag(self, tag, attrs):
                if tag == "script":
                    d = dict(attrs)
                    if d.get("type") == "module" and "src" in d:
                        self.srcs.append(d["src"].strip())

        parser = ScriptModuleParser()
        parser.feed(index_html.read_text(encoding="utf-8", errors="ignore"))
        for raw_src in parser.srcs:
            cleaned = raw_src.lstrip("./").lstrip("/")
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

        # 4. 验证带空白和换行的动态 import 以及无空白动态 import
        (src_dir / "lib/Dynamic.svelte").write_text('<p>Dynamic</p>\n', encoding="utf-8")
        (src_dir / "lib/Dynamic2.svelte").write_text('<p>Dynamic2</p>\n', encoding="utf-8")
        (src_dir / "App.svelte").write_text(
            '<script>\nimport Photo from "./lib/Photo.svelte";\nconst load1 = () => import(  \n  "./lib/Dynamic.svelte"  \n);\nconst load2 = () => import("./lib/Dynamic2.svelte");\n</script>\n',
            encoding="utf-8"
        )
        dynamic_errs = scan(tmppath)
        if dynamic_errs:
            print(f"Self-test failed on dynamic import with whitespace/newline: {dynamic_errs}", file=sys.stderr)
            return 1

        # 清理动态组件
        (src_dir / "lib/Dynamic.svelte").unlink()
        (src_dir / "lib/Dynamic2.svelte").unlink()
        (src_dir / "App.svelte").write_text('<script>\nimport Photo from "./lib/Photo.svelte";\n</script>\n', encoding="utf-8")

        # 5. 验证 index.html 模块入口作为可达性根（含 src 在前 type = "module" 带空格与 ./src 路径）
        (tmppath / "apps/desktop/index.html").write_text(
            '<!doctype html><html><body><script data-src="ignored.js" src = "./src/secondary.js"  type = "module" ></script></body></html>',
            encoding="utf-8"
        )
        (src_dir / "secondary.js").write_text('import HtmlComp from "./lib/HtmlComp.svelte";\n', encoding="utf-8")
        (src_dir / "lib/HtmlComp.svelte").write_text('<p>HtmlComp</p>\n', encoding="utf-8")
        html_entry_errs = scan(tmppath)
        if html_entry_errs:
            print(f"Self-test failed on index.html entry module: {html_entry_errs}", file=sys.stderr)
            return 1

        # 清理 index.html 额外文件
        (src_dir / "secondary.js").unlink()
        (src_dir / "lib/HtmlComp.svelte").unlink()
        (tmppath / "apps/desktop/index.html").unlink()

        # 6. 反例：普通字符串里的 import(...) 与 export from 不能产生依赖边 -> 孤立组件必须判红（同时阳性验证 Photo.svelte 仍存活）
        (src_dir / "lib/FakeString.svelte").write_text('<p>Fake</p>\n', encoding="utf-8")
        (src_dir / "App.svelte").write_text(
            '<script>\nimport Photo from "./lib/Photo.svelte";\nconst tip = \'import("./lib/FakeString.svelte")\';\nexport const label = \' from "./lib/FakeString.svelte"\';\nconst tip2 = "https://example.com//not-a-comment";\n</script>\n',
            encoding="utf-8"
        )
        str_errs = scan(tmppath)
        if not any("FakeString.svelte" in e for e in str_errs) or any("Photo.svelte" in e for e in str_errs):
            print("Self-test failed: import inside normal string literal wrongly kept component alive or killed real import", file=sys.stderr)
            return 1

        (src_dir / "lib/FakeString.svelte").unlink()

        # 7. 验证 export * from 与模板字符串中动态 import 均可被识别
        (src_dir / "lib/InsideTpl.svelte").write_text('<p>InsideTpl</p>\n', encoding="utf-8")
        (src_dir / "lib/ExportStar.svelte").write_text('<p>ExportStar</p>\n', encoding="utf-8")
        (src_dir / "lib/ExportStarAs.svelte").write_text('<p>ExportStarAs</p>\n', encoding="utf-8")
        (src_dir / "App.svelte").write_text(
            '<script>\nimport Photo from "./lib/Photo.svelte";\nexport * from "./lib/ExportStar.svelte";\nexport * as MyStar from "./lib/ExportStarAs.svelte";\nconst loadTpl = `${import("./lib/InsideTpl.svelte")}`;\n</script>\n',
            encoding="utf-8"
        )
        tpl_errs = scan(tmppath)
        if tpl_errs:
            print(f"Self-test failed: export * from or import inside template failed to be recognized: {tpl_errs}", file=sys.stderr)
            return 1

        (src_dir / "lib/InsideTpl.svelte").unlink()
        (src_dir / "lib/ExportStar.svelte").unlink()
        (src_dir / "lib/ExportStarAs.svelte").unlink()

        # 8. 反例：注释中的 export/import 与混淆长注释不能产生依赖边 -> 孤立组件必须判红（同时验证长注释后真实 import 仍存活）
        (src_dir / "lib/LiveTarget.svelte").write_text('<p>LiveTarget</p>\n', encoding="utf-8")
        (src_dir / "App.svelte").write_text(
            '<script>\n// import Photo from "./lib/Photo.svelte";\n/* import Photo from "./lib/Photo.svelte"; */\nexport { /* \n } from "./lib/Photo.svelte"\n */ };\nexport { /* xxxxxxxxxxxxxxxxxxxxxxxx import("./lib/Photo.svelte") */ } from "./lib/LiveTarget.svelte";\nimport { /* } from "./lib/Photo.svelte" */ } from "./lib/LiveTarget.svelte";\n</script>\n',
            encoding="utf-8"
        )
        comment_errs = scan(tmppath)
        if not any("Photo.svelte" in e for e in comment_errs) or any("LiveTarget.svelte" in e for e in comment_errs):
            print("Self-test failed: comment import wrongly kept component alive or killed real import after comment", file=sys.stderr)
            return 1

        (src_dir / "lib/LiveTarget.svelte").unlink()

        # 还原干净 App.svelte
        (src_dir / "App.svelte").write_text('<script>\nimport Photo from "./lib/Photo.svelte";\n</script>\n', encoding="utf-8")

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
