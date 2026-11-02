#!/usr/bin/env python3
"""CI 检查 → 本地命令对照表（tools/flow/ci-local-map.tsv）的检查与取步骤。说明见 docs/runbook/owner.md。

  ci-local-map.py check [--map F] [--workflows DIR]
      .github/workflows/ci-*.yml 与 e2e.yml 里每个 job 都要有映射；映射指向的 job 必须还在；
      mac / win 行要有命令，ci-only / meta 行要有理由；同一个 job 的 gate 一致。
      通过时最后一行 `CI-LOCAL-MAP OK <job 数> jobs`，否则逐条列出问题、退出 1。

  ci-local-map.py plan --where mac|win [--repo DIR] [--base REF] [--only WF:JOB]... [--map F]
      按 gate 判定（与 CI 同一脚本）输出要跑的步骤，tab 分隔，一行一条：
        RUN     <workflow:job/step>  <命令（占位符已替换）>
        SKIP    <workflow:job>       <理由>        gate 判定不用跑
        CIONLY  <workflow:job/step>  <理由>        只能 CI（不论 --where，都列出）
      --repo 是被验证的检出（默认当前目录）：workflow 与 gate 判据从那里读，命令也在那里跑。
      --only 指定时忽略 gate，只列这些 job。判不出来一律按「要跑」（与 CI 同一口径）。

check 缺 pyyaml 直接失败，不当作通过；plan 只有 paths 判定要读 workflow，读不了按「要跑」。
"""
import argparse
import glob
import json
import os
import subprocess
import sys

try:
    import yaml
except ImportError:
    yaml = None

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS_ROOT = os.path.dirname(os.path.dirname(HERE))
DEFAULT_MAP = os.path.join(HERE, "ci-local-map.tsv")
WHERES = ("mac", "win", "ci-only", "meta")


def load_map(path):
    rows, errors = [], []
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) != 6:
                errors.append(f"{path}:{n}: 要 6 列（tab 分隔），实际 {len(cols)} 列")
                continue
            wf, job, where, gate, step, cmd = (c.strip() for c in cols)
            rows.append(dict(line=n, wf=wf, job=job, where=where, gate=gate, step=step, cmd=cmd))
    return rows, errors


def workflow_files(wdir):
    files = sorted(glob.glob(os.path.join(wdir, "ci-*.yml")))
    e2e = os.path.join(wdir, "e2e.yml")
    if os.path.exists(e2e):
        files.append(e2e)
    return files


def load_jobs(wdir):
    jobs = {}
    for f in workflow_files(wdir):
        with open(f, encoding="utf-8") as fh:
            d = yaml.safe_load(fh) or {}
        jobs[os.path.basename(f)] = d.get("jobs") or {}
    return jobs


def check(args):
    if yaml is None:  # fail-closed：读不了 workflow 就判不了覆盖
        print("error: 缺 pyyaml（python3 -m pip install pyyaml），判不了对照表", file=sys.stderr)
        return 1
    rows, errors = load_map(args.map)
    jobs = load_jobs(args.workflows)
    if not jobs:
        errors.append(f"{args.workflows} 下没有 ci-*.yml / e2e.yml，判不了")
    mapped = {}
    for r in rows:
        key = (r["wf"], r["job"])
        mapped.setdefault(key, []).append(r)
        where = f"{args.map}:{r['line']}"
        if r["where"] not in WHERES:
            errors.append(f"{where}: where 只能是 {'/'.join(WHERES)}，实际「{r['where']}」")
        if not r["cmd"]:
            errors.append(f"{where}: 最后一列为空（mac/win 写命令，ci-only/meta 写理由）")
        if r["where"] in ("mac", "win"):
            if not (r["gate"] in ("always", "paths", "lane") or r["gate"].startswith("lane:")):
                errors.append(f"{where}: gate 只能是 always / paths / lane[:<名字>]，实际「{r['gate']}」")
            if not r["step"] or r["step"] == "-":
                errors.append(f"{where}: mac/win 行要有步骤名")
        if r["wf"] not in jobs:
            errors.append(f"{where}: workflow「{r['wf']}」不存在（或不在 ci-*.yml / e2e.yml 里）")
        elif r["job"] not in jobs[r["wf"]]:
            errors.append(f"{where}: {r['wf']} 里没有 job「{r['job']}」（改名或删了？对照表跟着改）")
    for key, rs in mapped.items():
        gates = {r["gate"] for r in rs if r["where"] in ("mac", "win")}
        if len(gates) > 1:
            errors.append(f"{key[0]}:{key[1]} 的步骤 gate 不一致：{sorted(gates)}")
    total = 0
    for wf, js in jobs.items():
        for job in js:
            total += 1
            if (wf, job) not in mapped:
                errors.append(f"{wf} 的 job「{job}」没有映射：在 {os.path.relpath(args.map)} 里补一行（mac / win / ci-only / meta）")
    for e in errors:
        print(f"✗ {e}", file=sys.stderr)
    if errors:
        print(f"CI-LOCAL-MAP FAIL {len(errors)} 处")
        return 1
    print(f"CI-LOCAL-MAP OK {total} jobs")
    return 0


def git(repo, *a):
    return subprocess.run(["git", "-C", repo, *a], capture_output=True, text=True)


def changes_paths(repo, wf):
    """该 workflow 的 changes job 传给 .github/actions/changes 的 paths；读不到返回 None。"""
    if yaml is None:
        return None
    try:
        with open(os.path.join(repo, ".github/workflows", wf), encoding="utf-8") as fh:
            d = yaml.safe_load(fh) or {}
        for s in d["jobs"]["changes"]["steps"]:
            if str(s.get("uses", "")).endswith("/actions/changes"):
                out = []
                for g in str(s["with"]["paths"]).splitlines():
                    g = g.strip()
                    if g and not g.startswith("#"):
                        out.append(g)
                return out or None
    except (OSError, KeyError, TypeError):
        pass
    return None


def gate_hit(repo, base, wf, gate, cache):
    """(要不要跑, 理由)。判不出来按要跑。判据脚本从 --repo 读，与那次提交上的 CI 一致。"""
    key = (wf, gate)
    if key in cache:
        return cache[key]
    if gate == "always":
        res = (True, "always")
    elif gate == "paths":
        globs = changes_paths(repo, wf)
        if not globs:
            res = (True, f"读不到 {wf} 的 changes paths → 按要跑")
        else:
            p = subprocess.run(["bash", os.path.join(repo, "tools/ci-paths.sh"), "hit", base, *globs],
                               cwd=repo, capture_output=True, text=True)
            out = p.stdout.strip()
            res = (out != "false", f"ci-paths.sh hit → {out or '无输出（按要跑）'}")
    elif gate == "lane" or gate.startswith("lane:"):
        lane = gate.split(":", 1)[1] if ":" in gate else ""
        script = os.path.join(repo, "tools/ci-needs-full-lane.sh")
        p = subprocess.run(["bash", script, base, *([lane] if lane else [])],
                           cwd=repo, capture_output=True, text=True)
        out = p.stdout.strip().splitlines()[-1:] or [""]
        res = (out[0] != "false", f"ci-needs-full-lane.sh {lane or '默认'} → {out[0] or '无输出（按要跑）'}")
    else:
        res = (True, f"看不懂的 gate「{gate}」→ 按要跑")
    cache[key] = res
    return res


def ppf_decoder_cmd(repo, where):
    p = subprocess.run(["cargo", "metadata", "--no-deps", "--format-version", "1"],
                       cwd=repo, capture_output=True, text=True)
    pkg = None
    if p.returncode == 0:
        for pk in json.loads(p.stdout)["packages"]:
            if any(t["name"] == "ppf-decoder" and "bin" in t["kind"] for t in pk["targets"]):
                pkg = pk["name"]
                break
    if pkg:
        return f"cargo build -p {pkg} --bin ppf-decoder"
    return "true" if where == "mac" else "ver >nul"


def plan(args):
    rows, errors = load_map(args.map)
    if errors:
        for e in errors:
            print(f"✗ {e}", file=sys.stderr)
        return 1
    repo = os.path.abspath(args.repo)
    base = args.base
    if not base:
        p = git(repo, "merge-base", "HEAD", "origin/main")
        base = p.stdout.strip() or "origin/main"
    only = set(args.only or [])
    if only:
        known = {f"{r['wf']}:{r['job']}" for r in rows}
        bad = sorted(only - known)
        if bad:
            print(f"error: --only 里的 {bad} 不在对照表里", file=sys.stderr)
            return 2
    cache, skipped, decoder = {}, set(), None
    for r in rows:
        jid = f"{r['wf']}:{r['job']}"
        if only and jid not in only:
            continue
        if r["where"] == "ci-only":
            print(f"CIONLY\t{jid}/{r['step']}\t{r['cmd']}")
            continue
        if r["where"] != args.where:
            continue
        if not only:
            run, why = gate_hit(repo, base, r["wf"], r["gate"], cache)
            if not run:
                if jid not in skipped:
                    skipped.add(jid)
                    print(f"SKIP\t{jid}\t{why}")
                continue
        cmd = r["cmd"].replace("@BASE@", base)
        if "@PPF_DECODER@" in cmd:
            decoder = decoder or ppf_decoder_cmd(repo, args.where)
            cmd = cmd.replace("@PPF_DECODER@", decoder)
        print(f"RUN\t{jid}/{r['step']}\t{cmd}")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--map", default=DEFAULT_MAP)
    c.add_argument("--workflows", default=os.path.join(TOOLS_ROOT, ".github/workflows"))
    p = sub.add_parser("plan")
    p.add_argument("--map", default=DEFAULT_MAP)
    p.add_argument("--where", required=True, choices=("mac", "win"))
    p.add_argument("--repo", default=".")
    p.add_argument("--base")
    p.add_argument("--only", action="append")
    a = ap.parse_args()
    return check(a) if a.cmd == "check" else plan(a)


if __name__ == "__main__":
    sys.exit(main())
