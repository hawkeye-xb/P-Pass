#!/usr/bin/env python3
"""#1062：Rust 改动按 Cargo 依赖图归属到端（plan-builds.sh 的 test tag 判定调用）。

本质：某端的产物只包含它入口包的传递依赖。改了一个 workspace crate，只有依赖它的端
需要重新构建；拿不准（读不出依赖图、对不上号、解析失败）一律算所有端——宁可多构建，不可漏构建。

用法：rust-impact.py --base <tag> --meta <cargo metadata JSON>... < 改动路径（每行一个）
  --meta：`cargo metadata --no-deps --format-version 1` 的输出。第一个是根 workspace，
  其余（桌面壳 apps/desktop/src-tauri 是独立 workspace）只用来补入口包的 path 依赖。
  没有可用的 --meta（cargo 不在 / metadata 失败）⇒ 本脚本认领的路径一律 all。
输出：每个输入路径一行「<归属>\t<路径>」，顺序与输入相同：
  归属 = 空格分隔的端（android ios macos windows）/ all / none / -（不归本脚本管，交回 classify）。

本脚本认领的路径：
  - 根 workspace 成员目录下的文件（crates/*、tools/testclient/）⇒ 依赖该成员的端。
    crate 里的 tests/、benches/ 也算（保守：不区分是否进产物，宁可多构建）。
  - crates/ 下不属于任何成员的路径 ⇒ all（新 crate 还没进 workspace、或成员被删，拿不准）。
  - 根 Cargo.toml：只变了 [workspace.package].version ⇒ 两个桌面端（这个号就是桌面版本线，
    tools/bump-version.sh 的 desktop 线改它；本仓只有 daemon 读 CARGO_PKG_VERSION，
    Android / iOS 产物的版本号来自 release/versions.json，不读它）。其余任何变化 ⇒ all。
  - 根 Cargo.lock：见 lock_impact()。
  桌面壳（apps/desktop/src-tauri/，含它自己的 Cargo.lock）不认领，仍由 classify 归到桌面两端。
"""
import argparse
import json
import os
import subprocess
import sys
import tomllib

ALL_ENDS = ("android", "ios", "macos", "windows")

# 各端的入口包与它们构建时开的 feature（默认 feature 一律算开）。与构建命令的一致性由
# tools/test-release-plan.sh 看守：
#   Android  tools/build-android-iroh-blobs-bridge.sh   cargo build -p transport --features android-jni
#   iOS      tools/build-ios-transport-xcframework.sh   cargo rustc -p transport --features ios-ffi
#                                                       （绑定生成器 --features ios-bindgen）
#   macOS    release.yml macos-arm64                    cargo build --release -p daemon + 桌面壳
#   Windows  release.yml windows-x64                    cargo build --release -p daemon -p testclient + 桌面壳
DESKTOP_SHELL = "p-pass-desktop"
ENTRIES = {
    "android": [("transport", ["android-jni"])],
    "ios": [("transport", ["ios-ffi", "ios-bindgen"])],
    "macos": [("daemon", []), (DESKTOP_SHELL, [])],
    "windows": [("daemon", []), ("testclient", []), (DESKTOP_SHELL, [])],
}


class Unsure(Exception):
    """拿不准 ⇒ 调用方算 all。"""


def git_show(rev, path):
    r = subprocess.run(["git", "show", f"{rev}:{path}"], capture_output=True)
    if r.returncode != 0:
        raise Unsure(f"git show {rev}:{path} 失败")
    return r.stdout.decode()


# ── workspace 依赖图（cargo metadata --no-deps：不联网、不下载 crate）─────────────
class Graph:
    def __init__(self, metas, root):
        self.root = root
        self.pkgs = {}  # 包名 → metadata 里的 package（同名以第一个 workspace 为准）
        self.by_dir = {}  # crate 目录（绝对路径）→ 包名
        self.members = set()  # 根 workspace 的成员（本脚本认领它们的目录）
        for i, meta in enumerate(metas):
            for p in meta["packages"]:
                if p["name"] in self.pkgs:
                    continue
                self.pkgs[p["name"]] = p
                d = os.path.dirname(os.path.realpath(p["manifest_path"]))
                self.by_dir[d] = p["name"]
                if i == 0:
                    self.members.add(p["name"])

    def member_dirs(self):
        """[(相对仓库根的目录, 包名)]，长的在前（最长前缀匹配）。"""
        out = []
        for d, n in self.by_dir.items():
            if n in self.members:
                out.append((os.path.relpath(d, self.root), n))
        return sorted(out, key=lambda x: -len(x[0]))

    def _path_deps(self, pkg, features):
        """pkg 进产物的 workspace path 依赖。features=None ⇒ 不按 feature 裁剪（可选依赖全算）。"""
        deps = [d for d in pkg["dependencies"] if d.get("path") and d.get("kind") != "dev"]
        if features is None:
            on = None
        else:
            on = set()
            todo = ["default"] + list(features)
            seen = set()
            feats = pkg.get("features", {})
            while todo:
                f = todo.pop()
                if f in seen:
                    continue
                seen.add(f)
                if f in feats:
                    for v in feats[f]:
                        if v.startswith("dep:"):
                            on.add(v[4:])
                        elif "/" in v:
                            on.add(v.split("/", 1)[0].rstrip("?"))
                        else:
                            todo.append(v)
                else:
                    on.add(f)  # 可选依赖的隐式同名 feature
        out = []
        for d in deps:
            if d.get("optional") and on is not None and (d.get("rename") or d["name"]) not in on:
                continue
            name = self.by_dir.get(os.path.realpath(d["path"]))
            if name is None:
                raise Unsure(f"{pkg['name']} 的 path 依赖 {d['path']} 不是已知的包")
            out.append(name)
        return out

    def closure(self, entry, features):
        """入口包进产物的全部 workspace 包。入口按构建时的 feature 裁剪；
        传递依赖不再裁剪（可选依赖全算）——只会多算，不会漏算。"""
        if entry not in self.pkgs:
            raise Unsure(f"入口包 {entry} 不在 cargo metadata 里")
        seen = {entry}
        todo = self._path_deps(self.pkgs[entry], features)
        while todo:
            n = todo.pop()
            if n in seen:
                continue
            seen.add(n)
            todo.extend(self._path_deps(self.pkgs[n], None))
        return seen

    def ends_using(self, crates):
        """依赖了 crates 里任一包的端。"""
        ends = []
        for end, entries in ENTRIES.items():
            for entry, feats in entries:
                if entry == DESKTOP_SHELL and entry not in self.pkgs:
                    continue  # 没传桌面壳的 metadata：它唯一的 path 依赖 platform 已在 daemon 的闭包里
                if self.closure(entry, feats) & crates:
                    ends.append(end)
                    break
        return ends


# ── Cargo.lock ───────────────────────────────────────────────────────────────
def lock_graph(text):
    """{节点: {依赖节点}}。workspace 成员（没有 source）的节点是 ("ws", 名字)——成员的版本号
    随桌面涨号整体变，不当成内容变化；外部包是 (名字, 版本, source)。"""
    try:
        pkgs = tomllib.loads(text)["package"]
    except Exception as e:  # noqa: BLE001 —— 解析不了就是拿不准
        raise Unsure(f"Cargo.lock 解析失败：{e}")
    key = {}
    by_name = {}
    for p in pkgs:
        k = ("ws", p["name"]) if "source" not in p else (p["name"], p["version"], p["source"])
        key[id(p)] = k
        by_name.setdefault(p["name"], []).append((p, k))

    def resolve(s):
        parts = s.split(" ", 2)
        cands = by_name.get(parts[0], [])
        if len(parts) >= 2:
            cands = [c for c in cands if c[0]["version"] == parts[1]]
        if len(parts) == 3:
            cands = [c for c in cands if f"({c[0].get('source')})" == parts[2]]
        if len(cands) != 1:
            raise Unsure(f"Cargo.lock 里的依赖 {s!r} 对不上唯一的包")
        return cands[0][1]

    graph, info = {}, {}
    for p in pkgs:
        k = key[id(p)]
        graph[k] = {resolve(d) for d in p.get("dependencies", [])}
        info[k] = (p.get("checksum"), tuple(sorted(p.get("dependencies", []))))
    return graph, info


def lock_impact(base, g):
    """Cargo.lock 变了：找出内容有变化的外部包（新增 / 删除 / checksum 或依赖表变化），
    沿 lock 自带的依赖图（基线 ∪ 本次）反查能走到它们的 workspace 成员，再映射到端。
    lock 图不区分 feature / target / dev 依赖，算出来是超集——只会多构建。"""
    old_g, old_i = lock_graph(git_show(base, "Cargo.lock"))
    with open(os.path.join(g.root, "Cargo.lock")) as f:
        new_g, new_i = lock_graph(f.read())
    changed = {k for k in set(old_i) | set(new_i) if k[0] != "ws" and old_i.get(k) != new_i.get(k)}
    if not changed:
        return []
    edges = {}
    for gr in (old_g, new_g):
        for k, ds in gr.items():
            edges.setdefault(k, set()).update(ds)
    hit = set()
    for k in edges:
        if k[0] != "ws":
            continue
        seen, todo = set(), list(edges[k])
        while todo:
            n = todo.pop()
            if n in seen:
                continue
            seen.add(n)
            todo.extend(edges.get(n, ()))
        if seen & changed:
            if k[1] not in g.pkgs:
                raise Unsure(f"Cargo.lock 里的成员 {k[1]} 不在 cargo metadata 里")
            hit.add(k[1])
    return g.ends_using(hit)


def cargo_toml_impact(base, g):
    try:
        old = tomllib.loads(git_show(base, "Cargo.toml"))
        with open(os.path.join(g.root, "Cargo.toml"), "rb") as f:
            new = tomllib.load(f)
    except tomllib.TOMLDecodeError as e:
        raise Unsure(f"Cargo.toml 解析失败：{e}")
    for t in (old, new):
        t.get("workspace", {}).get("package", {}).pop("version", None)
    if old != new:
        raise Unsure("根 Cargo.toml 除 [workspace.package].version 之外还有变化")
    return ["macos", "windows"]


def impact(path, base, g):
    if path == "Cargo.toml":
        return cargo_toml_impact(base, g)
    if path == "Cargo.lock":
        return lock_impact(base, g)
    for d, name in g.member_dirs():
        if path.startswith(d + "/"):
            return g.ends_using({name})
    if path.startswith("crates/"):
        raise Unsure("不属于任何 workspace 成员")
    return None


def claims(path, member_dirs):
    return (
        path in ("Cargo.toml", "Cargo.lock")
        or path.startswith("crates/")
        or any(path.startswith(d + "/") for d, _ in member_dirs)
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--meta", action="append", default=[])
    a = ap.parse_args()
    paths = [line.rstrip("\n") for line in sys.stdin if line.strip()]
    root = os.path.realpath(os.getcwd())
    try:
        metas = []
        for m in a.meta:
            with open(m) as f:
                metas.append(json.load(f))
        g = Graph(metas, root) if metas else None
    except Exception as e:  # noqa: BLE001
        print(f"rust-impact：读不出 cargo metadata（{e}）", file=sys.stderr)
        g = None
    member_dirs = g.member_dirs() if g else []
    for p in paths:
        if not claims(p, member_dirs):
            print(f"-\t{p}")
            continue
        if g is None:
            print(f"rust-impact：{p} ⇒ 没有可用的依赖图 ⇒ all", file=sys.stderr)
            print(f"all\t{p}")
            continue
        try:
            ends = impact(p, a.base, g)
        except Unsure as e:
            print(f"rust-impact：{p} ⇒ {e} ⇒ all", file=sys.stderr)
            print(f"all\t{p}")
            continue
        print(f"{' '.join(ends) if ends else 'none'}\t{p}")


if __name__ == "__main__":
    main()
