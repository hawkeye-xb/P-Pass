#!/usr/bin/env python3
"""桌面前端未挂载死组件秒级静态扫描门禁（#1991 / #1997）。

从桌面前端产品入口（apps/desktop/src/main.js 与 index.html）出发，
遍历 import/export 依赖图，进行可达性分析，拦截以下死代码：
  未挂载 Svelte 组件：未在产品源码中被挂载（仅在 *.test.js 中 import 或完全孤立）的 .svelte 组件（排除 *.fixture.svelte 测试夹具）。

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
    """词法状态机：将 // 与 /* */ 注释替换为等长空格，支持模板字面量及其 ${...} 表达式，保持 1:1 字符偏移。"""
    out: list[str] = []
    i = 0
    n = len(code)
    tpl_stack: list[int] = []

    while i < n:
        if is_svelte and not tpl_stack and code.startswith("<!--", i):
            j = code.find("-->", i + 4)
            end = n if j == -1 else j + 3
            out.append(blank_preserve_newlines(code[i:end]))
            i = end
            continue

        c = code[i]
        nxt = code[i + 1] if i + 1 < n else ""

        # 单行注释 //
        if c == "/" and nxt == "/":
            j = code.find("\n", i)
            end = n if j == -1 else j
            out.append(" " * (end - i))
            i = end
            continue

        # 块注释 /* ... */
        if c == "/" and nxt == "*":
            j = code.find("*/", i + 2)
            end = n if j == -1 else j + 2
            out.append(blank_preserve_newlines(code[i:end]))
            i = end
            continue

        # 普通单双引号字符串
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

        # 模板字面量 `
        if c == "`":
            out.append("`")
            i += 1
            while i < n:
                ch = code[i]
                if ch == "\\":
                    out.append(ch)
                    if i + 1 < n:
                        out.append(code[i + 1])
                        i += 2
                    else:
                        i += 1
                    continue
                if ch == "$" and i + 1 < n and code[i + 1] == "{":
                    out.append("${")
                    tpl_stack.append(1)
                    i += 2
                    break
                if ch == "`":
                    out.append("`")
                    i += 1
                    break
                out.append(ch)
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
                    out.append("}")
                    i += 1
                    while i < n:
                        ch = code[i]
                        if ch == "\\":
                            out.append(ch)
                            if i + 1 < n:
                                out.append(code[i + 1])
                                i += 2
                            else:
                                i += 1
                            continue
                        if ch == "$" and i + 1 < n and code[i + 1] == "{":
                            out.append("${")
                            tpl_stack.append(1)
                            i += 2
                            break
                        if ch == "`":
                            out.append("`")
                            i += 1
                            break
                        out.append(ch)
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

        # 匹配语句层 import（排除 obj.import()、logger . import() 等方法调用）
        if src.startswith("import", i):
            prev_idx = i - 1
            while prev_idx >= 0 and src[prev_idx] in " \t\r\n":
                prev_idx -= 1
            if prev_idx < 0 or not (src[prev_idx].isalnum() or src[prev_idx] in "_$."):
                rem = src[i + 6 :]
                # 1. 动态 import( ... )（支持单参数尾逗号 import("./x",)）
                m_dyn = re.match(r"""^\s*\(\s*["']([^"']+)["']\s*,?\s*\)""", rem)
                if m_dyn:
                    imports.add(m_dyn.group(1))
                    i += 6 + m_dyn.end()
                    continue
                # 2. 静态 import ... from "..." 或 import"..."（支持 * as、默认、解构、混合组合、紧凑无空白导入与跨行）
                m_stat = re.match(r"""^(?:\s*(?:(?:\*\s*as\s+[\w$]+|\{[^}]*\}|[\w$]+(?:,\s*(?:\*\s*as\s+[\w$]+|\{[^}]*\}))?)\s*from\s*)|\s*)["']([^"']+)["']""", rem)
                if m_stat:
                    imports.add(m_stat.group(1))
                    i += 6 + m_stat.end()
                    continue

        # 匹配 export ... from "..." 重新导出（支持 export * from、export * as X from、export { X } from、紧凑无空白）
        if src.startswith("export", i):
            prev_idx = i - 1
            while prev_idx >= 0 and src[prev_idx] in " \t\r\n":
                prev_idx -= 1
            if prev_idx < 0 or not (src[prev_idx].isalnum() or src[prev_idx] in "_$."):
                rem = src[i + 6 :]
                m_exp = re.match(r"""^(?:\s*(?:(?:\*\s*(?:as\s+[\w$]+)?|\{[^}]*\})\s*from\s*)|\s*from\s*)["']([^"']+)["']""", rem)
                if m_exp:
                    imports.add(m_exp.group(1))
                    i += 6 + m_exp.end()
                    continue

        i += 1
    return imports


SCRIPT_BLOCK_RE = re.compile(r"<script\b[^>]*>([\s\S]*?)</script>", re.IGNORECASE)


def build_dependency_graph(desktop_dir: Path, src_dir: Path) -> tuple[dict[Path, set[Path]], list[Path]]:
    all_candidates = (
        list(desktop_dir.rglob("*.js"))
        + list(desktop_dir.rglob("*.ts"))
        + list(src_dir.rglob("*.svelte"))
    )
    files = [
        f for f in all_candidates
        if f.is_file() and not any(part in ("node_modules", ".git", "dist", "build") for part in f.parts)
    ]
    imports: dict[Path, set[Path]] = {}
    for f in files:
        raw_content = f.read_text(encoding="utf-8", errors="ignore")
        if f.suffix == ".svelte":
            script_parts = SCRIPT_BLOCK_RE.findall(raw_content)
            script_content = "\n".join(script_parts)
            raw_specs = extract_valid_imports(script_content, is_svelte=True)
        else:
            raw_specs = extract_valid_imports(raw_content, is_svelte=False)
        resolved = set()
        for spec in raw_specs:
            res = resolve_import(f, spec, src_dir)
            if res:
                resolved.add(res)
        imports[f.resolve()] = resolved
    return imports, [f.resolve() for f in files]


def find_html_entries(root: Path, src_dir: Path) -> set[Path]:
    entries: set[Path] = set()
    index_html = root / "apps/desktop/index.html"
    if index_html.is_file():
        from html.parser import HTMLParser

        html_dir = index_html.parent

        class ScriptModuleParser(HTMLParser):
            def __init__(self):
                super().__init__()
                self.srcs: list[str] = []
                self.inline_scripts: list[str] = []
                self.current_inline: list[str] | None = None

            def handle_starttag(self, tag, attrs):
                if tag == "script":
                    d = dict(attrs)
                    if d.get("type") == "module":
                        src_val = d.get("src")
                        if src_val is not None:
                            self.srcs.append(src_val.strip())
                        else:
                            self.current_inline = []

            def handle_endtag(self, tag):
                if tag == "script" and self.current_inline is not None:
                    self.inline_scripts.append("".join(self.current_inline))
                    self.current_inline = None

            def handle_data(self, data):
                if self.current_inline is not None:
                    self.current_inline.append(data)

        parser = ScriptModuleParser()
        parser.feed(index_html.read_text(encoding="utf-8", errors="ignore"))

        # 1. 外部 script 模块：同时支持相对 html_dir 与相对 src_dir
        for raw_src in parser.srcs:
            # 优先从 index.html 所在目录及其子目录（如 ./scripts/xxx.js）解析相对路径
            cand1 = (html_dir / raw_src).resolve()
            if cand1.is_file():
                entries.add(cand1)
                continue
            cleaned = raw_src.lstrip("./").lstrip("/")
            if cleaned.startswith("src/"):
                cleaned = cleaned[4:]
            cand2 = (src_dir / cleaned).resolve()
            if cand2.is_file():
                entries.add(cand2)

        # 2. 内联 script 模块：分别逐个提取每个内联模块的依赖边，防止跨 script 注释串染
        for inline_code in parser.inline_scripts:
            inline_specs = extract_valid_imports(inline_code)
            for spec in inline_specs:
                res = resolve_import(index_html, spec, src_dir)
                if res:
                    entries.add(res)

    return entries


def scan(root: Path) -> list[str]:
    root = root.resolve()
    desktop_dir = (root / "apps/desktop").resolve()
    src_dir = (root / "apps/desktop/src").resolve()
    if not src_dir.is_dir():
        return [f"目录不存在：{src_dir}"]

    imports, all_files = build_dependency_graph(desktop_dir, src_dir)

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
            if neighbor not in visited and (str(src_dir) in str(neighbor) or str(desktop_dir) in str(neighbor)):
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

        # 5. 验证 index.html 外部相对路径模块（含子目录 scripts/bootstrap.js）与多个内联 script type="module" 分组解析
        (tmppath / "apps/desktop/scripts").mkdir(parents=True, exist_ok=True)
        (tmppath / "apps/desktop/index.html").write_text(
            '<!doctype html><html><body>\n'
            '<!-- <script type="module" src="./src/ignored_comment.js"></script> -->\n'
            '<script type="module" src>/* 无值 src 忽略 */</script>\n'
            '<script data-src="ignored.js" src = "./scripts/bootstrap.js"  type = "module" ></script>\n'
            '<script type="module">// end</script>\n'
            '<script type="module">\n'
            '  import InlineComp from "./src/lib/InlineComp.svelte";\n'
            '</script>\n'
            '</body></html>',
            encoding="utf-8",
        )
        (tmppath / "apps/desktop/scripts/bootstrap.js").write_text('import HtmlComp from "../src/lib/HtmlComp.svelte";\n', encoding="utf-8")
        (src_dir / "lib/HtmlComp.svelte").write_text('<p>HtmlComp</p>\n', encoding="utf-8")
        (src_dir / "lib/InlineComp.svelte").write_text('<p>InlineComp</p>\n', encoding="utf-8")
        html_entry_errs = scan(tmppath)
        if html_entry_errs:
            print(f"Self-test failed on index.html entry module: {html_entry_errs}", file=sys.stderr)
            return 1

        # 清理 index.html 额外文件
        (tmppath / "apps/desktop/scripts/bootstrap.js").unlink()
        (tmppath / "apps/desktop/scripts").rmdir()
        (src_dir / "lib/HtmlComp.svelte").unlink()
        (src_dir / "lib/InlineComp.svelte").unlink()
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

        # 7. 验证 export * from、模板字符串中动态 import，以及模板 URL 后的真实导入均可被识别
        (src_dir / "lib/InsideTpl.svelte").write_text('<p>InsideTpl</p>\n', encoding="utf-8")
        (src_dir / "lib/ExportStar.svelte").write_text('<p>ExportStar</p>\n', encoding="utf-8")
        (src_dir / "lib/ExportStarAs.svelte").write_text('<p>ExportStarAs</p>\n', encoding="utf-8")
        (src_dir / "lib/TplUrlTarget.svelte").write_text('<p>TplUrlTarget</p>\n', encoding="utf-8")
        (src_dir / "App.svelte").write_text(
            '<script>\n'
            'import Photo from "./lib/Photo.svelte";\n'
            'export * from "./lib/ExportStar.svelte";\n'
            'export * as MyStar from "./lib/ExportStarAs.svelte";\n'
            'const loadTpl = `${import("./lib/InsideTpl.svelte")}`;\n'
            'const url = `https://example.com`; import TplUrlTarget from "./lib/TplUrlTarget.svelte";\n'
            '</script>\n',
            encoding="utf-8",
        )
        tpl_errs = scan(tmppath)
        if tpl_errs:
            print(f"Self-test failed: export * from or import inside/after template failed to be recognized: {tpl_errs}", file=sys.stderr)
            return 1

        (src_dir / "lib/InsideTpl.svelte").unlink()
        (src_dir / "lib/ExportStar.svelte").unlink()
        (src_dir / "lib/ExportStarAs.svelte").unlink()
        (src_dir / "lib/TplUrlTarget.svelte").unlink()

        # 8. 反例：注释中的 export/import 与混淆长注释不能产生依赖边 -> 孤立组件必须判红（分别验证重导出与两种静态导入，以及模板单引号后的注释）
        (src_dir / "lib/LiveExport.svelte").write_text('<p>LiveExport</p>\n', encoding="utf-8")
        (src_dir / "lib/LiveImport.svelte").write_text('<p>LiveImport</p>\n', encoding="utf-8")
        (src_dir / "lib/LiveCompact.svelte").write_text('<p>LiveCompact</p>\n', encoding="utf-8")
        (src_dir / "App.svelte").write_text(
            '<script>\n// import Photo from "./lib/Photo.svelte";\n/* import Photo from "./lib/Photo.svelte"; */\n'
            'export { /* \n } from "./lib/Photo.svelte"\n */ };\n'
            'export { /* xxxxxxxxxxxxxxxxxxxxxxxx import("./lib/Photo.svelte") */ } from "./lib/LiveExport.svelte";\n'
            'import { /* } from "./lib/Photo.svelte" */ } from "./lib/LiveImport.svelte";\n'
            'import"./lib/LiveCompact.svelte";\n'
            'logger . import("./lib/Photo.svelte");\n'
            'const label = `It\'s fine`;\n'
            '// import("./lib/Photo.svelte");\n'
            '</script>\n'
            '<p>Example: import("./lib/Photo.svelte")</p>\n',
            encoding="utf-8",
        )
        comment_errs = scan(tmppath)
        if (
            not any("Photo.svelte" in e for e in comment_errs)
            or any("LiveExport.svelte" in e for e in comment_errs)
            or any("LiveImport.svelte" in e for e in comment_errs)
            or any("LiveCompact.svelte" in e for e in comment_errs)
        ):
            print("Self-test failed: comment import wrongly kept component alive or killed real import/export", file=sys.stderr)
            return 1

        (src_dir / "lib/LiveExport.svelte").unlink()
        (src_dir / "lib/LiveImport.svelte").unlink()
        (src_dir / "lib/LiveCompact.svelte").unlink()

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
