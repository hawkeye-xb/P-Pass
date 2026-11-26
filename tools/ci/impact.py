#!/usr/bin/env python3
"""统一依赖图影响范围引擎（#2089）：云端 CI 与本地 pick_gates 共用同一份静态图。

仅使用 Python 标准库（优先 ``tomllib``，Python 3.10 回退到内置轻量 TOML 解析器）。
所有判定遵循 fail-closed：未知路径、空文件列表、未知 lane、git 异常、缺失工作流或
workflow/action 里的动态 ``tools/*$`` 引用一律保守返回要跑（``true``）。
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import posixpath
import re
import subprocess
import sys

try:
    import tomllib  # type: ignore[import-not-found]
except ModuleNotFoundError:  # Python 3.10 兜底
    tomllib = None  # type: ignore[assignment]

VALID_LANES = frozenset({
    "default",
    "rust-workspace",
    "android",
    "ios",
    "ios-ffi",
    "docs",
    "docs-flow",
})

EXCLUDE_SELF_DATA = frozenset({
    "tools/ci-needs-full-lane.sh",
    "tools/test-ci-needs-full-lane.sh",
    "tools/ci/impact.py",
    "tools/test-ci-impact.py",
})

CLOSURE_MAX = 300
DYN_TOOLS_RE = re.compile(r"tools/[A-Za-z0-9_./-]*[*$]")
USES_ACTION_RE = re.compile(r"""uses:\s*['"]?\./(\.github/actions/[A-Za-z0-9_-]+)['"]?""")
TOOL_REF_RE = re.compile(r"tools/[A-Za-z0-9_./-]*[A-Za-z0-9_-]")
INCLUDE_MACRO_RE = re.compile(r'include_(?:str|bytes)!\(\s*"([^"]+)"')
QUOTED_REPO_PATH_RE = re.compile(
    r'"(?:(?:\.\./)+)?((?:apps|assets|crates|config|docs|release|tests|third_party)/[^"\n\\]+)"'
)
URL_IMPORT_RE = re.compile(r'new\s+URL\(\s*"([^"]+)"\s*,\s*import\.meta\.url\s*\)')
READFILE_RE = re.compile(r'readFileSync\(\s*"([^"]+)"')
ROOT_FILE_JOIN_RE = re.compile(r'rootProject\.file\(\s*"([^"]+)"\s*\)')
GRADLE_INCLUDE_RE = re.compile(r'include\(([^)]+)\)')
DYNAMIC_SHIM_JUST_PATTERNS = ("justfile",)


def _parse_toml_fallback(text: str) -> dict:
    """轻量级 TOML 解析器，覆盖 Cargo.toml / Cargo.lock 在 Python 3.10 下的必需子集。"""

    def strip_comment(line: str) -> str:
        in_str = ""
        escaped = False
        for i, ch in enumerate(line):
            if escaped:
                escaped = False
                continue
            if ch == "\\" and in_str == '"':
                escaped = True
                continue
            if ch in ('"', "'"):
                if not in_str:
                    in_str = ch
                elif in_str == ch:
                    in_str = ""
            elif ch == "#" and not in_str:
                return line[:i]
        return line

    def parse_val(raw: str):
        s = raw.strip()
        if (s.startswith('"') and s.endswith('"')) or (s.startswith("'") and s.endswith("'")):
            return s[1:-1]
        if s == "true":
            return True
        if s == "false":
            return False
        if s.startswith("[") and s.endswith("]"):
            inner = s[1:-1].strip()
            if not inner:
                return []
            return [m.group(1) or m.group(2) for m in re.finditer(r'"([^"]*)"|\'([^\']*)\'', inner)]
        if s.startswith("{") and s.endswith("}"):
            out: dict = {}
            for m in re.finditer(r'([A-Za-z0-9_.-]+)\s*=\s*(?:"([^"]*)"|\'([^\']*)\'|([^,}\s]+))', s[1:-1]):
                k = m.group(1)
                if m.group(2) is not None:
                    out[k] = m.group(2)
                elif m.group(3) is not None:
                    out[k] = m.group(3)
                else:
                    out[k] = m.group(4)
            return out
        return s

    root: dict = {}
    cur: dict = root
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        line = strip_comment(lines[i]).strip()
        i += 1
        if not line:
            continue
        if line.startswith("[[") and line.endswith("]]"):
            sec = line[2:-2].strip()
            lst = root.setdefault(sec, [])
            cur = {}
            lst.append(cur)
            continue
        if line.startswith("[") and line.endswith("]"):
            sec = line[1:-1].strip()
            parts = [p.strip() for p in sec.split(".")]
            cur = root
            for p in parts:
                cur = cur.setdefault(p, {})
            continue
        if "=" not in line:
            continue
        k, v = line.split("=", 1)
        k = k.strip().strip('"').strip("'")
        v = v.strip()
        while (v.startswith("[") and v.count("[") > v.count("]")) or (
            v.startswith("{") and v.count("{") > v.count("}")
        ):
            if i >= len(lines):
                break
            v += " " + strip_comment(lines[i]).strip()
            i += 1
        cur[k] = parse_val(v)
    return root


def load_toml(text: str) -> dict:
    if tomllib is not None:
        return tomllib.loads(text)
    return _parse_toml_fallback(text)


def norm_rel(path: str) -> str:
    p = path.strip().replace("\\", "/")
    while p.startswith("./"):
        p = p[2:]
    return p


def _is_unsafe_or_empty(path: str) -> bool:
    if not path or path.startswith("/") or ".." in Path(path).parts:
        return True
    return False


def _strip_c_comments(text: str) -> str:
    """移除 // 行注释与 /* ... */ 块注释（保留字符串字面量内的内容），避免把文档注释当真依赖。"""
    out: list[str] = []
    i = 0
    n = len(text)
    in_str = ""
    while i < n:
        ch = text[i]
        if in_str:
            out.append(ch)
            if ch == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if ch == in_str:
                in_str = ""
            i += 1
            continue
        if ch in ('"', "'"):
            in_str = ch
            out.append(ch)
            i += 1
            continue
        if ch == "/" and i + 1 < n:
            nx = text[i + 1]
            if nx == "/":
                while i < n and text[i] != "\n":
                    i += 1
                continue
            if nx == "*":
                i += 2
                while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                    if text[i] == "\n":
                        out.append("\n")
                    i += 1
                i += 2
                continue
        out.append(ch)
        i += 1
    return "".join(out)


def _read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="ignore")
    except OSError:
        return ""


def _resolve_rel(from_file: str, target: str) -> str | None:
    if not target or target.startswith("/") or "://" in target:
        return None
    joined = posixpath.normpath(posixpath.join(posixpath.dirname(from_file), target))
    if joined == ".." or joined.startswith("../"):
        return None
    return joined


def _expand_member_globs(repo_root: Path, patterns: list[str]) -> list[str]:
    out: list[str] = []
    for pat in patterns:
        pat_clean = norm_rel(pat).rstrip("/")
        if "*" in pat_clean or "?" in pat_clean:
            for match in sorted(repo_root.glob(pat_clean)):
                if match.is_dir() and (match / "Cargo.toml").is_file():
                    out.append(match.relative_to(repo_root).as_posix())
        else:
            cand = repo_root / pat_clean / "Cargo.toml"
            if cand.is_file():
                out.append(pat_clean)
    return sorted(set(out))


def _iter_dep_tables(manifest: dict) -> list[dict]:
    tables: list[dict] = []
    for sec in ("dependencies", "build-dependencies", "dev-dependencies"):
        if isinstance(manifest.get(sec), dict):
            tables.append(manifest[sec])
    targets = manifest.get("target")
    if isinstance(targets, dict):
        for tdata in targets.values():
            if not isinstance(tdata, dict):
                continue
            for sec in ("dependencies", "build-dependencies", "dev-dependencies"):
                if isinstance(tdata.get(sec), dict):
                    tables.append(tdata[sec])
    return tables


def _iter_prod_dep_tables(manifest: dict) -> list[dict]:
    tables: list[dict] = []
    for sec in ("dependencies", "build-dependencies"):
        if isinstance(manifest.get(sec), dict):
            tables.append(manifest[sec])
    targets = manifest.get("target")
    if isinstance(targets, dict):
        for tdata in targets.values():
            if not isinstance(tdata, dict):
                continue
            for sec in ("dependencies", "build-dependencies"):
                if isinstance(tdata.get(sec), dict):
                    tables.append(tdata[sec])
    return tables


def _extract_path_deps(pkg_dir: str, tables: list[dict], dir_to_pkg: dict[str, str]) -> set[str]:
    out: set[str] = set()
    for tbl in tables:
        for dep_val in tbl.values():
            if isinstance(dep_val, dict) and isinstance(dep_val.get("path"), str):
                target = posixpath.normpath(posixpath.join(pkg_dir, norm_rel(dep_val["path"])))
                if target in dir_to_pkg:
                    out.add(dir_to_pkg[target])
    return out


class RepoGraph:
    """从仓库现行配置与源码动态推导的依赖图。"""

    def __init__(self, repo_root: Path) -> None:
        self.repo_root = repo_root
        self.root_member_dirs: dict[str, str] = {}
        self.patch_dirs: dict[str, str] = {}
        self.tauri_pkg: str | None = None
        self.tauri_dir = "apps/desktop/src-tauri"
        self.pkg_dirs: dict[str, str] = {}
        self.dir_to_pkg: dict[str, str] = {}
        self.prod_deps: dict[str, set[str]] = {}
        self.all_deps: dict[str, set[str]] = {}
        self.prod_rdeps: dict[str, set[str]] = {}
        self.all_rdeps: dict[str, set[str]] = {}

        # target path/prefix -> set of reader identifiers (pkg names or lanes)
        self.rust_readers: dict[str, set[str]] = {}
        self.desktop_ui_readers: set[str] = set()
        self.android_readers: set[str] = set()
        self.ios_readers: set[str] = set()
        self.ios_ffi_readers: set[str] = set()
        self.ios_ffi_inputs: list[str] = []
        self.android_ffi_inputs: list[str] = []

        self._parse_cargo_graph()
        self._parse_cross_references()
        self._parse_ffi_manifests()

    def _parse_cargo_graph(self) -> None:
        root_toml_path = self.repo_root / "Cargo.toml"
        manifests: dict[str, dict] = {}
        if root_toml_path.is_file():
            try:
                root_toml = load_toml(_read_text(root_toml_path))
            except Exception:
                root_toml = {}
            ws = root_toml.get("workspace") or {}
            members = ws.get("members") if isinstance(ws, dict) else None
            if isinstance(members, list):
                for mdir in _expand_member_globs(self.repo_root, [str(x) for x in members]):
                    try:
                        m = load_toml(_read_text(self.repo_root / mdir / "Cargo.toml"))
                    except Exception:
                        continue
                    name = (m.get("package") or {}).get("name") if isinstance(m.get("package"), dict) else None
                    if name:
                        self.root_member_dirs[mdir] = str(name)
                        self.pkg_dirs[str(name)] = mdir
                        self.dir_to_pkg[mdir] = str(name)
                        manifests[str(name)] = m
            patches = (root_toml.get("patch") or {}).get("crates-io")
            if isinstance(patches, dict):
                for pval in patches.values():
                    if isinstance(pval, dict) and isinstance(pval.get("path"), str):
                        pdir = norm_rel(pval["path"]).rstrip("/")
                        ct = self.repo_root / pdir / "Cargo.toml"
                        if ct.is_file():
                            try:
                                pm = load_toml(_read_text(ct))
                            except Exception:
                                continue
                            pname = (pm.get("package") or {}).get("name") if isinstance(pm.get("package"), dict) else None
                            if pname:
                                self.patch_dirs[pdir] = str(pname)
                                self.pkg_dirs[str(pname)] = pdir
                                self.dir_to_pkg[pdir] = str(pname)
                                manifests[str(pname)] = pm

        tauri_toml_path = self.repo_root / self.tauri_dir / "Cargo.toml"
        if tauri_toml_path.is_file():
            try:
                tm = load_toml(_read_text(tauri_toml_path))
                tname = (tm.get("package") or {}).get("name") if isinstance(tm.get("package"), dict) else None
                if tname:
                    self.tauri_pkg = str(tname)
                    self.pkg_dirs[str(tname)] = self.tauri_dir
                    self.dir_to_pkg[self.tauri_dir] = str(tname)
                    manifests[str(tname)] = tm
            except Exception:
                pass

        for pkg, m in manifests.items():
            pdir = self.pkg_dirs[pkg]
            self.prod_deps[pkg] = _extract_path_deps(pdir, _iter_prod_dep_tables(m), self.dir_to_pkg)
            self.all_deps[pkg] = _extract_path_deps(pdir, _iter_dep_tables(m), self.dir_to_pkg)

        # Cargo.lock 解析 patch crate（如 third_party/noq-udp）到根 workspace 成员的传递路径
        lock_path = self.repo_root / "Cargo.lock"
        if lock_path.is_file() and self.patch_dirs:
            try:
                lock_data = load_toml(_read_text(lock_path))
                pkgs = lock_data.get("package") or []
            except Exception:
                pkgs = []
            lock_rdeps: dict[str, set[str]] = {}
            for item in pkgs:
                if not isinstance(item, dict):
                    continue
                pname = item.get("name")
                if not isinstance(pname, str):
                    continue
                for dep in item.get("dependencies") or []:
                    if isinstance(dep, str) and dep:
                        dname = dep.split()[0]
                        lock_rdeps.setdefault(dname, set()).add(pname)
            for patch_pkg in self.patch_dirs.values():
                seen = {patch_pkg}
                stack = [patch_pkg]
                while stack:
                    cur = stack.pop()
                    for parent in lock_rdeps.get(cur, ()):
                        if parent in seen:
                            continue
                        seen.add(parent)
                        stack.append(parent)
                        if parent in self.pkg_dirs and parent != patch_pkg:
                            self.prod_deps.setdefault(parent, set()).add(patch_pkg)
                            self.all_deps.setdefault(parent, set()).add(patch_pkg)

        for pkg in self.pkg_dirs:
            self.prod_rdeps.setdefault(pkg, set())
            self.all_rdeps.setdefault(pkg, set())
        for pkg, deps in self.prod_deps.items():
            for d in deps:
                self.prod_rdeps.setdefault(d, set()).add(pkg)
        for pkg, deps in self.all_deps.items():
            for d in deps:
                self.all_rdeps.setdefault(d, set()).add(pkg)

    def rev_closure(self, pkgs: set[str], *, prod_only: bool = False) -> set[str]:
        graph = self.prod_rdeps if prod_only else self.all_rdeps
        out = set(pkgs)
        stack = list(pkgs)
        while stack:
            cur = stack.pop()
            for nxt in graph.get(cur, ()):
                if nxt not in out:
                    out.add(nxt)
                    stack.append(nxt)
        return out

    def owner_pkg_for_file(self, rel_path: str) -> str | None:
        best_dir = ""
        best_pkg: str | None = None
        for d, pkg in self.dir_to_pkg.items():
            if rel_path == d or rel_path.startswith(d + "/"):
                if len(d) > len(best_dir):
                    best_dir = d
                    best_pkg = pkg
        return best_pkg

    def _walk_files(self, rel_root: str, exts: tuple[str, ...]) -> list[Path]:
        base = self.repo_root / rel_root
        if not base.is_dir():
            return []
        found: list[Path] = []
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = sorted(
                d for d in dirnames if d not in ("target", "build", "node_modules", ".git", "DerivedData")
            )
            for name in sorted(filenames):
                if name.endswith(exts):
                    found.append(Path(dirpath) / name)
        return found

    def _parse_cross_references(self) -> None:
        # 1. Rust crates + src-tauri: include_str! / include_bytes! + quoted cross-dir repo paths
        rust_roots = ["crates"]
        if (self.repo_root / self.tauri_dir).is_dir():
            rust_roots.append(self.tauri_dir)
        for root_rel in rust_roots:
            for fp in self._walk_files(root_rel, (".rs",)):
                rel = fp.relative_to(self.repo_root).as_posix()
                owner = self.owner_pkg_for_file(rel)
                if not owner:
                    continue
                owner_dir = self.pkg_dirs[owner]
                txt = _strip_c_comments(_read_text(fp))
                for target in INCLUDE_MACRO_RE.findall(txt):
                    resolved = _resolve_rel(rel, target)
                    if not resolved:
                        continue
                    if not (resolved == owner_dir or resolved.startswith(owner_dir + "/")):
                        self.rust_readers.setdefault(resolved, set()).add(owner)
                if "CARGO_MANIFEST_DIR" in txt or "include_str!" in txt:
                    for qpath in QUOTED_REPO_PATH_RE.findall(txt):
                        qnorm = norm_rel(qpath)
                        if " " in qnorm or "$" in qnorm or "{" in qnorm or "}" in qnorm:
                            continue
                        if not (qnorm == owner_dir or qnorm.startswith(owner_dir + "/")):
                            self.rust_readers.setdefault(qnorm, set()).add(owner)

        # 2. Desktop frontend vitest / JS tests
        for fp in self._walk_files("apps/desktop/src", (".js", ".ts", ".mjs", ".svelte")):
            rel = fp.relative_to(self.repo_root).as_posix()
            txt = _strip_c_comments(_read_text(fp))
            for target in URL_IMPORT_RE.findall(txt) + READFILE_RE.findall(txt):
                resolved = _resolve_rel(rel, target)
                if resolved and not resolved.startswith("apps/desktop/src/") and "{" not in resolved and "}" not in resolved:
                    self.desktop_ui_readers.add(resolved)
            for qpath in QUOTED_REPO_PATH_RE.findall(txt):
                qnorm = norm_rel(qpath)
                if " " in qnorm or "$" in qnorm or "{" in qnorm or "}" in qnorm:
                    continue
                if not qnorm.startswith("apps/desktop/src/"):
                    self.desktop_ui_readers.add(qnorm)

        # 3. Android Kotlin + Gradle readers（仅测试目录与 build.gradle.kts，且要求真实文件读取上下文）
        for fp in self._walk_files("apps/android/app/src", (".kt", ".java")):
            rel = fp.relative_to(self.repo_root).as_posix()
            if "/src/test/" not in rel and "/src/androidTest/" not in rel and "/src/sharedTest/" not in rel:
                continue
            txt = _strip_c_comments(_read_text(fp))
            if not any(tok in txt for tok in ("File(", "Paths.get(", "readText", "Files.readString")):
                continue
            for qpath in QUOTED_REPO_PATH_RE.findall(txt):
                qnorm = norm_rel(qpath)
                if " " in qnorm or "$" in qnorm or "{" in qnorm or "}" in qnorm or qnorm.startswith("apps/android/"):
                    continue
                self.android_readers.add(qnorm)
        gradle_file = self.repo_root / "apps/android/app/build.gradle.kts"
        if gradle_file.is_file():
            gtxt = _strip_c_comments(_read_text(gradle_file))
            for ref in ROOT_FILE_JOIN_RE.findall(gtxt):
                # rootProject 在 apps/android/ 下（不是 apps/android/app/）
                resolved = _resolve_rel("apps/android/settings.gradle.kts", ref)
                if resolved:
                    self.android_readers.add(resolved)

        # 4. iOS Swift + tools/ios/*.py|sh readers（仅测试目录与 tools/ios/）
        for fp in self._walk_files("apps/ios", (".swift",)):
            rel = fp.relative_to(self.repo_root).as_posix()
            if "/PPassTests/" not in rel and "/Tests/" not in rel and "/TransportFFITests/" not in rel:
                continue
            txt = _strip_c_comments(_read_text(fp))
            if not any(tok in txt for tok in ("appendingPathComponent(", "repoFile(", "contentsOf")):
                continue
            for qpath in QUOTED_REPO_PATH_RE.findall(txt):
                qnorm = norm_rel(qpath)
                if " " in qnorm or "$" in qnorm or "{" in qnorm or "}" in qnorm or qnorm.startswith("apps/ios/"):
                    continue
                self.ios_readers.add(qnorm)
                if rel.startswith("apps/ios/TransportFFITests/"):
                    self.ios_ffi_readers.add(qnorm)
        gen_strings = self.repo_root / "tools/ios/gen-strings.py"
        if gen_strings.is_file():
            gs_txt = _read_text(gen_strings)
            if "strings.xml" in gs_txt and "values-zh" in gs_txt:
                self.ios_readers.add("apps/android/app/src/main/res/values/strings.xml")
                self.ios_readers.add("apps/android/app/src/main/res/values-zh/strings.xml")
        gen_tokens = self.repo_root / "tools/ios/gen-tokens.py"
        if gen_tokens.is_file() and "tokens.json" in _read_text(gen_tokens):
            self.ios_readers.add("assets/design/tokens.json")
        check_pm = self.repo_root / "tools/ios/check-privacy-manifest.py"
        if check_pm.is_file():
            for qpath in QUOTED_REPO_PATH_RE.findall(_read_text(check_pm)):
                qnorm = norm_rel(qpath)
                if " " in qnorm or "$" in qnorm:
                    continue
                self.ios_readers.add(qnorm)
                if qnorm.endswith("PrivacyInfo.xcprivacy"):
                    self.ios_ffi_readers.add(qnorm)

    def _parse_ffi_manifests(self) -> None:
        # iOS XCFramework inputs
        ios_ffi_script = self.repo_root / "tools/build-ios-transport-xcframework.sh"
        if ios_ffi_script.is_file():
            m = re.search(r"inputs\s*=\s*\[(.*?)\]", _read_text(ios_ffi_script), re.S)
            if m:
                self.ios_ffi_inputs = [norm_rel(x) for x in re.findall(r'"([^"]+)"', m.group(1))]

        # Android native bridge Gradle inputs
        gradle_file = self.repo_root / "apps/android/app/build.gradle.kts"
        if gradle_file.is_file():
            for grp in GRADLE_INCLUDE_RE.findall(_read_text(gradle_file)):
                for item in re.findall(r'"([^"]+)"', grp):
                    clean = norm_rel(item).removesuffix("/**").removesuffix("/*").rstrip("/")
                    if clean:
                        self.android_ffi_inputs.append(clean)

    def path_hits_any(self, rel_path: str, targets: set[str] | list[str]) -> bool:
        for t in targets:
            t_clean = norm_rel(t).rstrip("/")
            if not t_clean:
                continue
            if rel_path == t_clean or rel_path.startswith(t_clean + "/"):
                return True
        return False

    def ffi_crate_prefixes(self) -> set[str]:
        """transport 的传递生产依赖目录（含 patch 如 third_party/noq-udp）。"""
        prefixes: set[str] = set()
        if "transport" in self.pkg_dirs:
            seen = {"transport"}
            stack = ["transport"]
            while stack:
                cur = stack.pop()
                if cur in self.pkg_dirs:
                    prefixes.add(self.pkg_dirs[cur])
                for dep in self.prod_deps.get(cur, ()):
                    if dep not in seen:
                        seen.add(dep)
                        stack.append(dep)
        return prefixes


def _extract_workflow_jobs(text: str) -> dict[str, str]:
    jobs: dict[str, str] = {}
    in_jobs = False
    cur_job: str | None = None
    buf: list[str] = []
    for line in text.splitlines():
        if line == "jobs:":
            in_jobs = True
            continue
        if not in_jobs:
            continue
        if line and not line[0].isspace():
            break
        m = re.match(r"^  ([A-Za-z0-9_-]+):\s*(?:#.*)?$", line)
        if m:
            if cur_job is not None:
                jobs[cur_job] = "\n".join(buf)
            cur_job = m.group(1)
            buf = [line]
        elif cur_job is not None:
            buf.append(line)
    if cur_job is not None:
        jobs[cur_job] = "\n".join(buf)
    return jobs


def _noncomment_lines(text: str) -> str:
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))


def _lane_workflow_slices(lane: str, repo_root: Path) -> tuple[dict[str, str], bool]:
    """返回该 lane 活跃的 (工作流/action 相对路径 -> 有效非注释文本), 以及是否缺失/无效。"""
    specs: dict[str, list[tuple[str, tuple[str, ...] | None]]] = {
        "default": [
            (".github/workflows/ci-rust.yml", None),
            (".github/workflows/ci-desktop.yml", None),
        ],
        "rust-workspace": [
            (".github/workflows/ci-rust.yml", None),
            (".github/workflows/ci-desktop.yml", None),
        ],
        "android": [(".github/workflows/ci-android.yml", None)],
        "ios": [(".github/workflows/ci-ios.yml", None)],
        "ios-ffi": [(".github/workflows/ci-ios.yml", ("changes", "ios-ffi", "gate"))],
        "docs": [(".github/workflows/ci-docs.yml", ("changes", "acceptance-gate", "docs", "gate"))],
        "docs-flow": [(".github/workflows/ci-docs.yml", ("changes", "flow-tests", "gate"))],
    }
    slices: dict[str, str] = {}
    queue_actions: list[str] = []
    seen_actions: set[str] = set()
    for wf_rel, job_filter in specs[lane]:
        wf_path = repo_root / wf_rel
        if not wf_path.is_file():
            return {}, True
        raw = _read_text(wf_path)
        if job_filter is None:
            eff = _noncomment_lines(raw)
        else:
            jobs = _extract_workflow_jobs(raw)
            eff = "\n".join(_noncomment_lines(jobs[j]) for j in job_filter if j in jobs)
        slices[wf_rel] = eff
        for act in USES_ACTION_RE.findall(eff):
            if act not in seen_actions:
                seen_actions.add(act)
                queue_actions.append(act)

    while queue_actions:
        act = queue_actions.pop(0)
        act_rel = f"{act}/action.yml"
        act_path = repo_root / act_rel
        if not act_path.is_file():
            return {}, True
        act_eff = _noncomment_lines(_read_text(act_path))
        slices[act_rel] = act_eff
        for sub_act in USES_ACTION_RE.findall(act_eff):
            if sub_act not in seen_actions:
                seen_actions.add(sub_act)
                queue_actions.append(sub_act)

    return slices, False


def _git_grep_refs(repo_root: Path, stem: str) -> tuple[list[str], bool]:
    r = subprocess.run(
        ["git", "-c", "core.quotepath=off", "grep", "-lF", "-e", stem, "--"],
        cwd=str(repo_root),
        capture_output=True,
        text=True,
        errors="ignore",
    )
    if r.returncode > 1:
        return [], True
    return [norm_rel(line) for line in r.stdout.splitlines() if line.strip()], False


def _static_inert_rust(rel_path: str, lane: str, graph: RepoGraph) -> bool:
    """Rust / Desktop lane（default 与 rust-workspace）的静态惰性基线。"""
    # 先拦 Rust 测试/源码读取的跨目录目标（#1049 / #1066 / #1467）：
    # rust-workspace 只看根 workspace 成员消费的跨目录路径；default 额外拦 p-pass-desktop 消费方。
    readers = graph.rust_readers.get(rel_path, set())
    if readers and (lane != "rust-workspace" or any(pkg != graph.tauri_pkg for pkg in readers)):
        return False
    # 保底：即使在未含完整源码的极简夹具里也显式守住已知跨目录契约锚点
    if rel_path in {
        "docs/desktop/business-rules.zh-CN.md",
        "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/flow/FlowContract.kt",
        "apps/ios/Packages/PPassCore/Sources/PPassCore/Flow/FlowTypes.swift",
        "apps/desktop/src/i18n/en.json",
        "apps/desktop/src/i18n/zh.json",
        "assets/i18n/en.json",
        "assets/i18n/zh.json",
    }:
        return False
    if rel_path.startswith(("docs/", ".claude/", "release/notes/", ".github/ISSUE_TEMPLATE/")):
        return True
    if rel_path.endswith(".md"):
        return True
    if rel_path == ".coderabbit.yaml":
        return True
    if rel_path == "justfile" or (rel_path.startswith("tools/just/") and rel_path.endswith(".just")):
        return True
    if rel_path.startswith(("tools/flow/", "tools/e3/", "tools/hooks/")):
        return True
    if rel_path in {
        "tools/test-flow.py",
        "tools/test-acceptance-gate.sh",
        "tools/test-ci-review.sh",
        "tools/test-e3.sh",
        "tools/test-local-hooks.sh",
        "tools/test-release-acceptance.sh",
        "tools/ci-paths.sh",
        "tools/test-ci-paths.sh",
    } or (rel_path.startswith("tools/test-flow-") and rel_path.endswith(".sh")):
        return True
    if lane == "rust-workspace" and rel_path.startswith("apps/"):
        return True
    return False


def _is_non_rust_code_inert_for_docs(rel_path: str) -> bool:
    """对 ci-docs 确认无影响的代码/资源路径。"""
    if rel_path.startswith("crates/"):
        return rel_path.endswith((".rs", ".sql", ".sb", ".json", ".heic", ".mp4", ".png")) or (
            "/tests/" in rel_path and not rel_path.endswith(".sh")
        )
    if rel_path.startswith("third_party/"):
        return not rel_path.endswith(".sh")
    if rel_path.startswith("apps/android/"):
        if rel_path == "apps/android/app/build.gradle.kts":
            return False
        return not rel_path.endswith((".sh", ".bash", "package.json", ".npmrc", "pnpm-workspace.yaml"))
    if rel_path.startswith("apps/ios/"):
        return not rel_path.endswith((".sh", ".bash", "package.json", ".npmrc", "pnpm-workspace.yaml"))
    if rel_path.startswith("apps/desktop/"):
        if rel_path in {"apps/desktop/src-tauri/Cargo.toml"}:
            return False
        return not rel_path.endswith((".sh", ".bash", "package.json", ".npmrc", "pnpm-workspace.yaml"))
    if rel_path.startswith(("assets/i18n/", "assets/privacy/", "assets/contracts/")):
        return True
    if rel_path.startswith(("site/", ".claude/")):
        return not rel_path.endswith((".sh", ".bash", "package.json", ".npmrc", "pnpm-workspace.yaml"))
    if rel_path in {".coderabbit.yaml", "tools/egress-allowlist.txt"}:
        return True
    return False


def _static_inert_lane(rel_path: str, lane: str, graph: RepoGraph) -> bool:
    if lane in ("default", "rust-workspace"):
        return _static_inert_rust(rel_path, lane, graph)

    # 代码/测试消费者（含读 docs/ 的测试夹具）优先级高于纯文档静态排除
    if lane == "android" and (rel_path in graph.android_readers or graph.path_hits_any(rel_path, graph.android_ffi_inputs)):
        return False
    if lane == "ios" and (rel_path in graph.ios_readers or graph.path_hits_any(rel_path, graph.ios_ffi_inputs)):
        return False
    if lane == "ios-ffi" and (rel_path in graph.ios_ffi_readers or graph.path_hits_any(rel_path, graph.ios_ffi_inputs)):
        return False

    # 非 Rust lane 通用无害文件（与 docs 无关，docs 单独处理）
    if lane in ("android", "ios", "ios-ffi"):
        if rel_path.startswith(("docs/", ".claude/", "release/notes/", ".github/ISSUE_TEMPLATE/")):
            return True
        if rel_path.endswith(".md") or rel_path in {
            ".coderabbit.yaml",
            "CHANGELOG.md",
            "justfile",
        } or (rel_path.startswith("tools/just/") and rel_path.endswith(".just")):
            return True
        if rel_path.startswith(("tools/flow/", "tools/e3/", "tools/hooks/")):
            return True
        if rel_path in {
            "tools/test-flow.py",
            "tools/test-acceptance-gate.sh",
            "tools/test-ci-review.sh",
            "tools/test-e3.sh",
            "tools/test-local-hooks.sh",
            "tools/test-release-acceptance.sh",
        } or (rel_path.startswith("tools/test-flow-") and rel_path.endswith(".sh")):
            return True

    if lane == "android":
        if rel_path in graph.android_readers or graph.path_hits_any(rel_path, graph.android_ffi_inputs):
            return False
        if rel_path in {
            ".java-version",
            "Cargo.toml",
            "Cargo.lock",
            "rust-toolchain.toml",
            "assets/privacy/redact-vectors.json",
            "assets/contracts/ui-state-truth-table.json",
            "assets/design/tokens.json",
            "tests/blake3-vectors.json",
            "tests/flow-audit-item-events.json",
            "release/update-keys/test.pub",
        }:
            return False
        if rel_path.startswith(("apps/android/", "assets/i18n/")):
            return False
        if graph.path_hits_any(rel_path, graph.ffi_crate_prefixes() | {"crates/transport", "crates/proto", "crates/pair-pake"}):
            return False
        if rel_path.startswith(("apps/desktop/", "apps/ios/", "site/", "config/", "assets/")):
            return True
        if rel_path.startswith("crates/") or rel_path.startswith("third_party/"):
            return True
        if rel_path.startswith(".github/workflows/"):
            return rel_path != ".github/workflows/ci-android.yml"
        return False

    if lane == "ios":
        if rel_path in graph.ios_readers or graph.path_hits_any(rel_path, graph.ios_ffi_inputs):
            return False
        if rel_path in {
            "Cargo.toml",
            "Cargo.lock",
            "rust-toolchain.toml",
            "assets/design/tokens.json",
            "assets/privacy/redact-vectors.json",
            "assets/contracts/ui-state-truth-table.json",
            "tests/blake3-vectors.json",
            "apps/android/app/src/main/res/values/strings.xml",
            "apps/android/app/src/main/res/values-zh/strings.xml",
        }:
            return False
        if rel_path.startswith(("apps/ios/", "assets/i18n/")):
            return False
        if graph.path_hits_any(rel_path, graph.ffi_crate_prefixes() | {"crates/transport", "crates/proto", "crates/pair-pake"}):
            return False
        if rel_path.startswith(("apps/desktop/", "apps/android/", "site/", "config/", "assets/")):
            return True
        if rel_path.startswith("crates/") or rel_path.startswith("third_party/"):
            return True
        if rel_path.startswith(".github/workflows/"):
            return rel_path != ".github/workflows/ci-ios.yml"
        return False

    if lane == "ios-ffi":
        if rel_path in graph.ios_ffi_readers or graph.path_hits_any(rel_path, graph.ios_ffi_inputs):
            return False
        if rel_path in {
            "Cargo.toml",
            "Cargo.lock",
            "rust-toolchain.toml",
            "apps/ios/PPass/Resources/PrivacyInfo.xcprivacy",
            "tests/blake3-vectors.json",
        }:
            return False
        if rel_path.startswith("apps/ios/TransportFFITests/"):
            return False
        if graph.path_hits_any(rel_path, graph.ffi_crate_prefixes() | {"crates/transport", "crates/proto", "crates/pair-pake"}):
            return False
        if rel_path.startswith(("apps/", "site/", "config/", "assets/", "tests/")):
            return True
        if rel_path.startswith("crates/") or rel_path.startswith("third_party/"):
            return True
        if rel_path.startswith(".github/workflows/"):
            return rel_path != ".github/workflows/ci-ios.yml"
        return False

    if lane == "docs":
        if rel_path.startswith(("docs/", "release/")) or rel_path in {"AGENTS.md", "CLAUDE.md", "CHANGELOG.md", "justfile"}:
            return False
        if rel_path.startswith("tools/just/") and rel_path.endswith(".just"):
            return False
        if rel_path.endswith((".sh", ".bash", ".md")) and not _is_non_rust_code_inert_for_docs(rel_path):
            return False
        if rel_path.startswith(".github/workflows/") or rel_path.startswith(".github/actions/changes/"):
            return False
        if rel_path in {
            "Cargo.toml",
            "tools/testclient/Cargo.toml",
            "apps/desktop/src-tauri/Cargo.toml",
            "apps/android/app/build.gradle.kts",
            "assets/design/tokens.json",
            "assets/design/tokens.css",
            "tools/release-age-exclude-allowlist.txt",
        } or (rel_path.startswith("crates/") and rel_path.endswith("/Cargo.toml")):
            return False
        if posixpath.basename(rel_path) in {"pnpm-workspace.yaml", "package.json", ".npmrc"}:
            return False
        return _is_non_rust_code_inert_for_docs(rel_path)

    if lane == "docs-flow":
        if rel_path in {
            "justfile",
            "AGENTS.md",
            "CLAUDE.md",
            "release/versions.json",
            "Cargo.toml",
            "apps/desktop/src-tauri/Cargo.toml",
            "apps/android/app/build.gradle.kts",
        } or rel_path.startswith(("tools/", ".github/")):
            return False
        if rel_path.startswith(("docs/", "release/notes/", ".claude/", "crates/", "apps/", "assets/", "site/", "third_party/", "config/")):
            return True
        if rel_path in {".coderabbit.yaml", "CHANGELOG.md", "Cargo.lock"}:
            return True
        return False

    return False


def _tools_closure_inert(
    rel_path: str,
    lane: str,
    repo_root: Path,
    graph: RepoGraph,
    slices: dict[str, str],
    slices_bad: bool,
    dyn_dyn: bool,
) -> tuple[bool, str]:
    """判断 tools/ 下未落在静态清单中的文件，经引用闭包是否惰性。返回 (inert, reason)。"""
    if slices_bad:
        return False, f"lane「{lane}」门禁 workflow/action 缺失，无法验证引用闭包"
    if dyn_dyn:
        return False, "门禁 workflow/action 含有通配符或变量拼接 tools/ 路径 → 引用追不全"

    if not (repo_root / rel_path).exists():
        return False, f"「{rel_path}」在 HEAD 不存在（改名或删除）→ 引用方可能正因此坏掉"

    queue = [rel_path]
    seen = {rel_path}
    idx = 0
    while idx < len(queue):
        cur = queue[idx]
        idx += 1
        if idx > CLOSURE_MAX:
            return False, f"「{rel_path}」引用闭包超过 {CLOSURE_MAX} 个文件 → 保守判跑"

        base = posixpath.basename(cur)
        stem = base.rsplit(".", 1)[0] if "." in base and not base.startswith(".") else base
        if not stem:
            stem = base
        # 防止短名脚本（如 tools/ios/test.sh）退化为按 "test" 误击无关文件：
        # Python 模块按模块名/路径查（import / from），其余按带扩展名的文件名（无扩展名则按父目录/文件名）查。
        if cur.endswith(".py"):
            search_token = stem
        elif "." in base and not base.startswith("."):
            search_token = base
        else:
            search_token = "/".join(cur.rsplit("/", 2)[-2:])

        # 直接在当前 lane 活跃 workflow/action 非注释正文里命中 -> 必须跑
        for wrel, wtxt in slices.items():
            if base in wtxt or cur in wtxt or (cur.endswith(".py") and re.search(rf"\b{re.escape(stem)}\b", wtxt)):
                if cur == rel_path:
                    return False, f"「{rel_path}」被「{wrel}」引用（lane={lane}）→ 要跑"
                return False, f"「{rel_path}」经「{cur}」被「{wrel}」引用（lane={lane}）→ 要跑"

        refs, grep_err = _git_grep_refs(repo_root, search_token)
        if grep_err:
            return False, f"git grep「{search_token}」出错 → 判不了「{rel_path}」"

        for r in refs:
            if r in seen:
                continue
            if r in EXCLUDE_SELF_DATA and not (
                rel_path in ("tools/ci/impact.py", "tools/test-ci-impact.py")
                and r in ("tools/ci-needs-full-lane.sh", "tools/test-ci-needs-full-lane.sh")
            ):
                continue
            if r.startswith(".github/workflows/") or r.startswith(".github/actions/"):
                # workflow 与 active actions 已由上面 slices 非注释检查精准判定
                continue
            if r == "justfile" or (r.startswith("tools/just/") and r.endswith(".just")):
                if lane in ("docs", "docs-flow"):
                    return False, f"「{rel_path}」被「{r}」引用（lane={lane}）→ 要跑"
                continue
            if _static_inert_lane(r, lane, graph):
                continue
            if r.endswith((".kt", ".java", ".swift", ".rs", ".js", ".ts", ".svelte")):
                eff_r = _strip_c_comments(_read_text(repo_root / r))
                if search_token not in eff_r:
                    continue
            if r.startswith("tools/"):
                seen.add(r)
                queue.append(r)
                continue
            if cur == rel_path:
                return False, f"「{rel_path}」被「{r}」引用（门禁会用到或不认识）→ 要跑"
            return False, f"「{rel_path}」经「{cur}」被「{r}」引用（门禁会用到或不认识）→ 要跑"

    return True, f"「{rel_path}」的引用闭包（{len(queue)} 个 tools/ 文件）里没有 lane={lane} 入口 → 惰性"


def _lane_direct_workflow_hit(rel_path: str, lane: str, slices: dict[str, str]) -> str | None:
    if not rel_path.startswith("tools/") or not slices:
        return None
    base = posixpath.basename(rel_path)
    stem = base.rsplit(".", 1)[0] if "." in base and not base.startswith(".") else base
    if not stem:
        return None
    for wrel, wtxt in slices.items():
        if stem in wtxt and rel_path in wtxt:
            return wrel
    return None


def decide_ci(
    lane: str,
    files: list[str] | None,
    repo_dir: str | Path | None = None,
    *,
    graph: RepoGraph | None = None,
) -> tuple[bool, str]:
    """判定指定 CI lane 是否需要运行。返回 (need_run, reason)。"""
    if lane not in VALID_LANES:
        return True, f"未知 lane「{lane}」→ 不猜，保守判定：要跑"

    if files is None:
        return True, "取不到改动文件列表 → 保守判定：要跑"

    cleaned = [norm_rel(f) for f in files if f and f.strip()]
    if not cleaned:
        return True, "改动文件列表为空 → 说明没搞清状况，保守判定：要跑"

    repo_root = Path(repo_dir).resolve() if repo_dir is not None else Path.cwd().resolve()
    if not repo_root.is_dir():
        return True, "取不到仓库根 → 保守判定：要跑"

    if graph is None:
        graph = RepoGraph(repo_root)
    slices, slices_bad = _lane_workflow_slices(lane, repo_root)
    if slices_bad:
        return True, f"lane「{lane}」门禁 workflow/action 缺失，保守判定：要跑"
    dyn_dyn = any(bool(DYN_TOOLS_RE.search(txt)) for txt in slices.values())

    # 仅在确实触发过 tools/ 闭包校验或有动态 ref 时注意工作流真实存在；
    # 若变动文件直接命中 active workflow 或 composite action，直接返回要跑。
    active_files = set(slices.keys())

    for f in cleaned:
        if _is_unsafe_or_empty(f):
            return True, f"非法或相对越界路径「{f}」→ 要跑"
        if f in active_files or any(f.startswith(posixpath.dirname(a) + "/") for a in active_files if a.startswith(".github/actions/")):
            return True, f"改动了 lane={lane} 入口工作流或 action「{f}」→ 要跑"

        # 对 docs / docs-flow 保留明确规则与工具闭包
        if lane == "docs-flow":
            if f.startswith("tools/"):
                if f in {
                    "tools/ci/impact.py",
                    "tools/test-ci-impact.py",
                    "tools/ci-needs-full-lane.sh",
                    "tools/test-ci-needs-full-lane.sh",
                    "tools/ci-paths.sh",
                    "tools/test-ci-paths.sh",
                } or f.startswith(("tools/flow/", "tools/e3/", "tools/hooks/", "tools/just/", "tools/release/", "tools/tests/")):
                    return True, f"「{f}」属于 flow-tests 覆盖范围 → 要跑"
                if f.startswith("tools/test-") or f.endswith((".sh", ".py")):
                    return True, f"「{f}」属于 tools 脚本/测试 → 要跑"
                return True, f"「{f}」在 tools/ 下（docs-flow 默认全覆盖）→ 要跑"

        hit_wf = _lane_direct_workflow_hit(f, lane, slices)
        if hit_wf:
            return True, f"「{f}」被「{hit_wf}」直接调用（lane={lane}）→ 要跑"
        if dyn_dyn and f.startswith("tools/"):
            return True, f"门禁 workflow/action 含有动态 tools/ 引用，「{f}」不做静态排除 → 要跑"

        if _static_inert_lane(f, lane, graph):
            continue

        if f.startswith("tools/"):
            inert, reason = _tools_closure_inert(f, lane, repo_root, graph, slices, slices_bad, dyn_dyn)
            if inert:
                continue
            return True, reason

        return True, f"「{f}」不在无害清单里（lane={lane}）→ 要跑"

    return False, f"全部改动都落在无害清单里（lane={lane}）→ 可跳过"


def _git_changed_files(base: str, repo_root: Path) -> list[str] | None:
    if not base or not base.strip() or base == "0000000000000000000000000000000000000000":
        return None
    r = subprocess.run(
        ["git", "diff", "--no-renames", "--name-only", f"{base}...HEAD"],
        cwd=str(repo_root),
        capture_output=True,
        text=True,
        errors="ignore",
    )
    if r.returncode != 0:
        return None
    return [line for line in r.stdout.splitlines() if line.strip()]


def decide_ci_from_base(base: str, lane: str, repo_dir: str | Path | None = None) -> tuple[bool, str]:
    if repo_dir is None:
        r = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
        if r.returncode != 0 or not r.stdout.strip():
            return True, "取不到仓库根 → 保守判定：要跑"
        repo_root = Path(r.stdout.strip())
    else:
        repo_root = Path(repo_dir).resolve()

    if base == "-":
        files = sys.stdin.read().splitlines()
    else:
        files = _git_changed_files(base, repo_root)
    return decide_ci(lane, files, repo_root)


def compute_local_gates(files: list[str], repo_dir: str | Path) -> list[str]:
    """按改动与统一依赖图精准推导本机门禁列表；未知配置文件绝不回退全仓 just ci。"""
    repo_root = Path(repo_dir).resolve()
    graph = RepoGraph(repo_root)
    gates: list[str] = []

    def add(cmd: str) -> None:
        if cmd not in gates:
            gates.append(cmd)

    def add_rust_pkg(pkg: str) -> None:
        if pkg == graph.tauri_pkg:
            for sub in (
                "nextest run --manifest-path apps/desktop/src-tauri/Cargo.toml -p p-pass-desktop",
                "clippy --manifest-path apps/desktop/src-tauri/Cargo.toml --all-targets -- -D warnings",
                "fmt --manifest-path apps/desktop/src-tauri/Cargo.toml -- --check",
            ):
                add(f"cargo {sub}")
        elif pkg in graph.root_member_dirs.values():
            add(f"cargo nextest run -p {pkg}")
            add(f"cargo clippy -p {pkg} --all-targets -- -D warnings")
            add("cargo fmt --all -- --check")

    code_touched = False
    cleaned = [norm_rel(x) for x in files if x and x.strip()]

    for f in cleaned:
        # 1. 文档与配方拆分文件（仅无代码消费方时只跑文档闸，有消费方时继续向下传导）
        if f in {"AGENTS.md", "CLAUDE.md", "justfile"} or (f.startswith("tools/just/") and f.endswith(".just")):
            add("just ci-docs")
            continue

        is_pure_doc_like = f.startswith(("docs/", "release/notes/")) or f.endswith(".md")
        has_rust_readers = f in graph.rust_readers
        has_desktop_readers = f in graph.desktop_ui_readers
        has_android_readers = f in graph.android_readers
        has_ios_readers = f in graph.ios_readers or f in graph.ios_ffi_readers
        if (
            is_pure_doc_like
            and not has_rust_readers
            and not has_desktop_readers
            and not has_android_readers
            and not has_ios_readers
        ):
            add("just md-check")
            continue

        if is_pure_doc_like:
            add("just md-check")

        code_touched = True

        # 2. 跨目录静态消费者传导（含 i18n -> diag/p-pass-desktop、business-rules -> daemon/p-pass-desktop/vitest 等）
        if has_rust_readers:
            for reader_pkg in sorted(graph.rust_readers[f]):
                add_rust_pkg(reader_pkg)
        if has_desktop_readers:
            add("pnpm -C apps/desktop test")
        if f in graph.android_readers:
            add("just android-test")
        if f in graph.ios_readers and not f.startswith("assets/i18n/"):
            if f == "assets/design/tokens.json":
                add("just token-check")
                add("just mobile-static-check")
            elif not (f.startswith("apps/android/") and "strings" in posixpath.basename(f)):
                add("just ios-test")

        # 3. 本端路径规则
        if f.startswith("apps/android/"):
            add("just android-test")
            if "strings" in posixpath.basename(f) and f.endswith(".xml"):
                add("just mobile-static-check")
        elif f.startswith("tools/ios/test-") and f.endswith(".sh"):
            if (repo_root / f).is_file():
                add(f"bash {f}")
        elif f.startswith(("apps/ios/", "tools/ios/")):
            add("just ios-test")
            if f.endswith((".strings", ".xcstrings")):
                add("just ios-test --lang en")
                add("just ios-test --lang zh")
        elif f.startswith("assets/i18n/"):
            add("just mobile-static-check")
            add("just ios-test --lang en")
            add("just ios-test --lang zh")
        elif f.startswith("assets/design/"):
            add("just token-check")
            add("just mobile-static-check")
            add("pnpm -C apps/desktop test")
        elif f == "assets/contracts/ui-state-truth-table.json":
            add("just mobile-static-check")
        elif f.startswith("apps/desktop/src-tauri/"):
            add_rust_pkg(graph.tauri_pkg or "p-pass-desktop")
        elif f.startswith("apps/desktop/src/"):
            add("pnpm -C apps/desktop test")
        elif f.startswith("third_party/"):
            owner = graph.owner_pkg_for_file(f)
            if owner:
                for dep_pkg in sorted(graph.rev_closure({owner}, prod_only=True)):
                    if dep_pkg != owner:
                        add_rust_pkg(dep_pkg)
        elif f.startswith("crates/") and len(Path(f).parts) >= 2:
            owner = graph.owner_pkg_for_file(f)
            if not owner:
                ctoml = repo_root / "crates" / Path(f).parts[1] / "Cargo.toml"
                if ctoml.is_file():
                    m = re.search(r'^name\s*=\s*"([^"]+)"', _read_text(ctoml), re.M)
                    if m:
                        owner = m.group(1)
            if owner:
                add_rust_pkg(owner)
        elif f.startswith("tools/ci/") or f == "tools/test-ci-impact.py":
            add("python3 -B -I tools/test-ci-impact.py")
            add("bash tools/test-ci-needs-full-lane.sh")
            add("python3 -B -I tools/test-flow.py")
        elif f.startswith("tools/flow/") or f == "tools/test-flow.py":
            add("python3 -B -I tools/test-flow.py")
        elif f.startswith("tools/e3/"):
            add("bash tools/test-e3.sh")
        elif f.startswith("tools/tests/") and f.endswith(".py"):
            if (repo_root / f).is_file():
                add(f"python3 -B -I {f}")
        elif f.startswith("tools/test-") and f.endswith(".py"):
            if (repo_root / f).is_file():
                add(f"python3 -B -I {f}")
        elif f.startswith("tools/test-") and f.endswith(".sh"):
            if (repo_root / f).is_file():
                add(f"bash {f}")
        elif f.startswith(".github/workflows/"):
            add("actionlint")

    if code_touched:
        add("just arch-check")
        add("just fitness-check")
    elif not gates:
        add("just md-check")

    return gates


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_ci = sub.add_parser("ci", help="判定指定 CI lane 是否需要运行")
    p_ci.add_argument("--base", required=True, help="base commit SHA，或 '-' 从 stdin 读取改动文件")
    p_ci.add_argument("--lane", default="default", help="lane 名称")
    p_ci.add_argument("--repo", default=None, help="仓库根目录（默认按 git rev-parse 探测）")

    p_loc = sub.add_parser("local-gates", help="输出本机精准门禁列表")
    p_loc.add_argument("--repo", default=".", help="仓库根目录")
    p_loc.add_argument("--files-stdin", action="store_true", help="从 stdin 读取改动文件列表")
    p_loc.add_argument("files", nargs="*")

    p_gr = sub.add_parser("graph", help="输出当前仓库解析出的依赖图摘要")
    p_gr.add_argument("--repo", default=".", help="仓库根目录")
    p_gr.add_argument("--json", action="store_true")

    args = ap.parse_args()
    if args.cmd == "ci":
        need, reason = decide_ci_from_base(args.base, args.lane, args.repo)
        print(reason, file=sys.stderr)
        print("true" if need else "false")
        return 0

    if args.cmd == "local-gates":
        files = sys.stdin.read().splitlines() if args.files_stdin else args.files
        for g in compute_local_gates(files, args.repo):
            print(g)
        return 0

    if args.cmd == "graph":
        g = RepoGraph(Path(args.repo).resolve())
        payload = {
            "root_members": g.root_member_dirs,
            "patch_dirs": g.patch_dirs,
            "tauri_pkg": g.tauri_pkg,
            "ffi_crate_prefixes": sorted(g.ffi_crate_prefixes()),
            "rust_readers": {k: sorted(v) for k, v in sorted(g.rust_readers.items())},
            "desktop_ui_readers": sorted(g.desktop_ui_readers),
            "android_readers": sorted(g.android_readers),
            "ios_readers": sorted(g.ios_readers),
            "ios_ffi_readers": sorted(g.ios_ffi_readers),
            "ios_ffi_inputs": g.ios_ffi_inputs,
            "android_ffi_inputs": g.android_ffi_inputs,
        }
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return 0

    return 2


if __name__ == "__main__":
    raise SystemExit(main())
