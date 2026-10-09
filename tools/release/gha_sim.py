"""REL-12（#711）：最小的 GitHub Actions job 执行器——给发布链 dry-run 用。

它不是通用的 act 替代品，只做发布链需要的那部分，但**每一处都按 runner 的真实语义**来，
因为 REL-10 那类事故恰恰出在「本地跑法比 runner 宽松」上：

- 每个 job 一个全新的工作区（runner 上每个 job 是一台新机器）；
- 每个 `run` 步骤是**独立的 bash 进程**：`bash -e <脚本>`（与 runner 上未写 shell: 的
  默认值相同），工作目录**每步重置**为工作区根（或 working-directory）；
- 环境变量**从空白开始**拼：runner 默认变量 + workflow env + job env + 前面步骤经
  `$GITHUB_ENV` 正式导出的 + 本步 env。上一步 shell 里定义 / export 的变量、cd 过的目录，
  到下一步一律不存在——依赖它们的脚本在这里必然红；
- `${{ }}` 表达式按 GitHub 的规则求值（`||` 返回第一个真值、字符串比较不分大小写、
  缺失属性为 null），用于 env / with / if / run 模板 / job outputs；**不认识的表达式直接报错**，
  免得 workflow 改了而 dry-run 悄悄按旧口径放行；
- `uses:` 只认发布链用到的 checkout / download-artifact，其余一律报错。

`run` 块原文取自 workflow 文件本身——跑的是 runner 真正会执行的同一份代码。
"""

from __future__ import annotations

import glob
import json
import os
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

import yaml


class SimError(Exception):
    """执行器自身无法继续（不认识的表达式 / action 等）——dry-run 判红。"""


# ── 表达式 ────────────────────────────────────────────────────────────

_TOKEN_RE = re.compile(
    r"\s*(?:(?P<str>'(?:[^']|'')*')|(?P<num>\d+(?:\.\d+)?)|(?P<op>==|!=|&&|\|\||<=|>=|[!()<>,\[\]])"
    r"|(?P<ident>[A-Za-z_][A-Za-z0-9_-]*(?:\.[A-Za-z_*][A-Za-z0-9_-]*)*))"
)


def _tokens(src: str):
    pos, out = 0, []
    src = src.strip()
    while pos < len(src):
        m = _TOKEN_RE.match(src, pos)
        if not m or m.end() == pos:
            raise SimError(f"表达式无法解析：{src!r}（位置 {pos}）")
        pos = m.end()
        kind = m.lastgroup
        val = m.group(kind)
        if kind == "str":
            out.append(("str", val[1:-1].replace("''", "'")))
        elif kind == "num":
            out.append(("num", float(val)))
        else:
            out.append((kind, val))
    return out


def truthy(v) -> bool:
    return v not in (None, False, "", 0, 0.0)


def render(v) -> str:
    if v is None:
        return ""
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, float) and v.is_integer():
        return str(int(v))
    if isinstance(v, (dict, list)):
        return json.dumps(v)
    return str(v)


def _eq(a, b) -> bool:
    if isinstance(a, str) and isinstance(b, str):
        return a.lower() == b.lower()
    if isinstance(a, bool) or isinstance(b, bool):
        return render(a).lower() == render(b).lower()
    return a == b


class Expr:
    """递归下降：or → and → eq → unary → primary。"""

    def __init__(self, src: str, ctx: "Ctx"):
        self.src, self.toks, self.i, self.ctx = src, _tokens(src), 0, ctx

    def peek(self):
        return self.toks[self.i] if self.i < len(self.toks) else (None, None)

    def take(self, val=None):
        t = self.peek()
        if val is not None and t[1] != val:
            raise SimError(f"表达式 {self.src!r}：期望 {val!r}，得到 {t[1]!r}")
        self.i += 1
        return t

    def parse(self):
        v = self.or_()
        if self.i != len(self.toks):
            raise SimError(f"表达式 {self.src!r} 有多余内容：{self.toks[self.i:]}")
        return v

    def or_(self):
        v = self.and_()
        while self.peek()[1] == "||":
            self.take()
            r = self.and_()
            v = v if truthy(v) else r
        return v

    def and_(self):
        v = self.eq()
        while self.peek()[1] == "&&":
            self.take()
            r = self.eq()
            v = r if truthy(v) else v
        return v

    def eq(self):
        v = self.unary()
        while self.peek()[1] in ("==", "!="):
            op = self.take()[1]
            r = self.unary()
            v = _eq(v, r) if op == "==" else not _eq(v, r)
        return v

    def unary(self):
        if self.peek()[1] == "!":
            self.take()
            return not truthy(self.unary())
        return self.primary()

    def primary(self):
        kind, val = self.take()
        if kind in ("str", "num"):
            return val
        if val == "(":
            v = self.or_()
            self.take(")")
            return v
        if kind == "ident":
            if self.peek()[1] == "(":
                self.take("(")
                args = []
                while self.peek()[1] != ")":
                    args.append(self.or_())
                    if self.peek()[1] == ",":
                        self.take()
                self.take(")")
                return self.ctx.call(val, args)
            if val in ("true", "false"):
                return val == "true"
            if val == "null":
                return None
            return self.ctx.lookup(val)
        raise SimError(f"表达式 {self.src!r}：意外的记号 {val!r}")


@dataclass
class Ctx:
    """一次表达式求值能看到的上下文。"""

    github: dict
    inputs: dict
    secrets: dict
    env: dict = field(default_factory=dict)
    needs: dict = field(default_factory=dict)
    steps: dict = field(default_factory=dict)
    job_status: str = "success"
    workspace: Path | None = None

    def lookup(self, dotted: str):
        head, *rest = dotted.split(".")
        roots = {
            "github": self.github,
            "inputs": self.inputs,
            "secrets": self.secrets,
            "env": self.env,
            "needs": self.needs,
            "steps": self.steps,
        }
        if head not in roots:
            raise SimError(f"不认识的上下文 {head!r}（{dotted}）——dry-run 需要跟着 workflow 更新")
        cur = roots[head]
        for k in rest:
            cur = cur.get(k) if isinstance(cur, dict) else None
        return cur

    def call(self, name: str, args):
        if name == "contains":
            hay, needle = args
            if isinstance(hay, list):
                return any(_eq(x, needle) for x in hay)
            return render(needle).lower() in render(hay).lower()
        if name == "startsWith":
            return render(args[0]).lower().startswith(render(args[1]).lower())
        if name == "endsWith":
            return render(args[0]).lower().endswith(render(args[1]).lower())
        if name == "cancelled":
            return False
        if name == "always":
            return True
        if name == "success":
            return self.job_status == "success"
        if name == "failure":
            return self.job_status == "failure"
        if name == "hashFiles":
            if self.workspace is None:
                raise SimError("hashFiles 只能在步骤里用")
            hits = []
            for pat in args:
                hits += [p for p in glob.glob(str(self.workspace / pat), recursive=True) if os.path.isfile(p)]
            if not hits:
                return ""
            import hashlib

            h = hashlib.sha256()
            for p in sorted(set(hits)):
                h.update(hashlib.sha256(Path(p).read_bytes()).digest())
            return h.hexdigest()
        raise SimError(f"不认识的函数 {name}()")


_TEMPLATE_RE = re.compile(r"\$\{\{(.*?)\}\}", re.S)


def evaluate(expr: str, ctx: Ctx):
    return Expr(expr, ctx).parse()


def template(text, ctx: Ctx) -> str:
    """把字符串里的 ${{ }} 换成求值结果（env / with / run 都这样处理）。"""
    if text is None:
        return ""
    if not isinstance(text, str):
        return render(text)
    return _TEMPLATE_RE.sub(lambda m: render(evaluate(m.group(1), ctx)), text)


def condition(cond, ctx: Ctx, default="success()") -> bool:
    if cond is None:
        cond = default
    if isinstance(cond, bool):
        return cond
    cond = str(cond).strip()
    m = re.fullmatch(r"\$\{\{(.*)\}\}", cond, re.S)
    if m:
        cond = m.group(1)
    # GitHub：if 里没有状态函数时隐含 success() &&
    if not re.search(r"\b(success|failure|cancelled|always)\s*\(", cond):
        cond = f"success() && ({cond})"
    return truthy(evaluate(cond, ctx))


# ── GITHUB_OUTPUT / GITHUB_ENV 文件 ─────────────────────────────────────


def parse_kv_file(path: Path) -> dict:
    out = {}
    if not path.exists():
        return out
    lines = path.read_text().split("\n")
    i = 0
    while i < len(lines):
        line = lines[i]
        i += 1
        if not line:
            continue
        m = re.match(r"^([^=<]+)<<(.+)$", line)
        if m:
            key, delim, buf = m.group(1), m.group(2), []
            while i < len(lines) and lines[i] != delim:
                buf.append(lines[i])
                i += 1
            i += 1
            out[key] = "\n".join(buf)
        elif "=" in line:
            k, v = line.split("=", 1)
            out[k] = v
        else:
            raise SimError(f"{path.name} 里有不合格式的行：{line!r}")
    return out


# ── job 执行 ──────────────────────────────────────────────────────────


@dataclass
class StepResult:
    name: str
    outcome: str  # success / failure / skipped
    conclusion: str
    log: str = ""
    rc: int | None = None
    outputs: dict = field(default_factory=dict)


@dataclass
class JobResult:
    job_id: str
    result: str  # success / failure / skipped
    outputs: dict
    steps: list
    workspace: Path | None

    def step(self, name: str) -> StepResult:
        for s in self.steps:
            if s.name == name:
                return s
        raise KeyError(f"{self.job_id} 没有步骤「{name}」：{[s.name for s in self.steps]}")

    @property
    def log(self) -> str:
        return "\n".join(f"--- [{s.name}] {s.outcome}\n{s.log}" for s in self.steps)


class Runner:
    """在一个沙箱目录里按 runner 语义执行 workflow 的 job。"""

    def __init__(self, root: Path, *, origin: Path, artifacts: Path, stub_bin: Path, repository: str, base_path: str):
        self.root, self.origin, self.artifacts = root, origin, artifacts
        self.stub_bin, self.repository, self.base_path = stub_bin, repository, base_path
        self._n = 0

    # ── uses: ──
    def _checkout(self, ws: Path, with_: dict, ctx: Ctx):
        dest = ws / with_.get("path", "") if with_.get("path") else ws
        ref = with_.get("ref") or ctx.github.get("ref") or ""
        depth = str(with_.get("fetch-depth", "1"))
        if dest.exists():
            shutil.rmtree(dest)
        dest.mkdir(parents=True)
        g = ["git", "-c", "core.hooksPath=/dev/null", "-C", str(dest)]
        q = {"stdout": subprocess.DEVNULL, "stderr": subprocess.PIPE, "check": True}
        subprocess.run(g + ["init", "-q"], **q)
        subprocess.run(g + ["remote", "add", "origin", f"file://{self.origin}"], **q)
        name = ref[len("refs/tags/"):] if ref.startswith("refs/tags/") else ref
        if depth == "0" or re.fullmatch(r"[0-9a-f]{40}", name):
            # actions/checkout fetch-depth: 0 ⇒ 全部历史 + 全部 tag。
            # 按提交号检出（github.workflow_sha）时本地 origin 不一定允许按 sha 浅取，取全量后再定位。
            subprocess.run(g + ["fetch", "-q", "--tags", "origin", "+refs/heads/*:refs/remotes/origin/*"], **q)
        else:
            # 浅检出一个 tag：本地只有这一个 tag（与 actions/checkout 相同）
            subprocess.run(
                g + ["fetch", "-q", "--no-tags", "--depth", depth, "origin", f"+refs/tags/{name}:refs/tags/{name}"], **q
            )
        subprocess.run(g + ["checkout", "-q", "--detach", name], **q)

    def _download_artifact(self, ws: Path, with_: dict):
        name = with_.get("name")
        src = self.artifacts / name
        if not src.is_dir():
            raise SimError(f"artifact {name!r} 不存在（dry-run 没造这个假产物）")
        dest = ws / with_.get("path", ".")
        dest.mkdir(parents=True, exist_ok=True)
        for p in src.iterdir():
            shutil.copy2(p, dest / p.name)

    # ── 一个 job ──
    def run_job(self, wf: dict, job_id: str, *, github: dict, inputs: dict, secrets: dict, needs: dict, until: str | None = None) -> JobResult:
        job = wf["jobs"][job_id]
        ctx = Ctx(github=github, inputs=inputs, secrets=secrets, needs=needs)
        wf_env = {k: template(v, ctx) for k, v in (wf.get("env") or {}).items()}
        ctx.env = dict(wf_env)
        # job 级 if 里的 success() = 所依赖的 job 全部成功（未写 if 时同样隐含它）
        ctx.job_status = "success" if all(n.get("result") == "success" for n in needs.values()) else "failure"
        if not condition(job.get("if"), ctx):
            return JobResult(job_id, "skipped", {}, [], None)
        ctx.job_status = "success"
        job_env = {k: template(v, ctx) for k, v in (job.get("env") or {}).items()}
        ctx.env = {**wf_env, **job_env}

        self._n += 1
        jobdir = self.root / f"{self._n:02d}-{job_id}"
        ws = jobdir / "work"
        tmp = jobdir / "runner-temp"
        for d in (ws, tmp):
            d.mkdir(parents=True)
        ctx.workspace = ws
        gh_env_file = jobdir / "github-env"
        gh_env_file.touch()
        results = []
        for idx, step in enumerate(job["steps"]):
            name = step.get("name") or step.get("uses") or f"step{idx}"
            ctx.env = {**wf_env, **job_env, **parse_kv_file(gh_env_file)}
            if not condition(step.get("if"), ctx):
                results.append(StepResult(name, "skipped", "skipped"))
                if "id" in step:
                    ctx.steps[step["id"]] = {"outputs": {}, "outcome": "skipped", "conclusion": "skipped"}
                continue
            step_env = {k: template(v, ctx) for k, v in (step.get("env") or {}).items()}
            outputs: dict = {}
            try:
                if "uses" in step:
                    with_ = {k: template(v, ctx) for k, v in (step.get("with") or {}).items()}
                    uses = step["uses"]
                    if uses.startswith("actions/checkout@"):
                        self._checkout(ws, with_, ctx)
                    elif uses.startswith("actions/download-artifact@"):
                        self._download_artifact(ws, with_)
                    else:
                        raise SimError(f"dry-run 不认识的 action：{uses}")
                    rc, log = 0, f"(uses {uses})"
                else:
                    rc, log, outputs = self._run_step(step, ctx, ws, tmp, gh_env_file, {**ctx.env, **step_env})
            except subprocess.CalledProcessError as e:
                rc, log = 1, f"{e}\n{(e.stderr or b'').decode(errors='replace')}"
            outcome = "success" if rc == 0 else "failure"
            conclusion = "success" if rc == 0 or step.get("continue-on-error") is True else "failure"
            results.append(StepResult(name, outcome, conclusion, log, rc, outputs))
            if "id" in step:
                ctx.steps[step["id"]] = {"outputs": outputs, "outcome": outcome, "conclusion": conclusion}
            if conclusion == "failure":
                ctx.job_status = "failure"
            if until and name == until:
                break
        result = ctx.job_status
        ctx.env = {**wf_env, **job_env}
        job_outputs = {k: template(v, ctx) for k, v in (job.get("outputs") or {}).items()} if result == "success" else {}
        return JobResult(job_id, result, job_outputs, results, ws)

    def _run_step(self, step, ctx: Ctx, ws: Path, tmp: Path, gh_env_file: Path, env_vars: dict):
        self._n += 1
        script = tmp.parent / f"step-{self._n:03d}.sh"
        script.write_text(template(step["run"], ctx))
        out_file = tmp.parent / f"step-{self._n:03d}.output"
        out_file.touch()
        cwd = ws / step["working-directory"] if step.get("working-directory") else ws
        env = {
            # runner 的默认变量（只放发布链用得到的）；其余一律不给
            "PATH": f"{self.stub_bin}:{self.base_path}",
            "HOME": os.environ.get("HOME", str(tmp)),
            "LANG": os.environ.get("LANG", "C.UTF-8"),
            "CI": "true",
            "GITHUB_ACTIONS": "true",
            "GITHUB_WORKSPACE": str(ws),
            "GITHUB_REPOSITORY": self.repository,
            "GITHUB_EVENT_NAME": ctx.github["event_name"],
            "GITHUB_REF": ctx.github.get("ref", ""),
            "GITHUB_REF_NAME": ctx.github.get("ref_name", ""),
            "GITHUB_OUTPUT": str(out_file),
            "GITHUB_ENV": str(gh_env_file),
            "GITHUB_STEP_SUMMARY": str(tmp.parent / "summary.md"),
            "RUNNER_TEMP": str(tmp),
            **{k: render(v) for k, v in env_vars.items()},
        }
        shell = step.get("shell", "bash")
        if shell != "bash":
            raise SimError(f"dry-run 只模拟 bash 步骤（shell: {shell}）")
        # runner 上未写 shell: ⇒ `bash -e {0}`；写了 shell: bash ⇒ `bash --noprofile --norc -eo pipefail {0}`
        argv = ["bash", "-e", str(script)] if "shell" not in step else ["bash", "--noprofile", "--norc", "-eo", "pipefail", str(script)]
        p = subprocess.run(argv, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        return p.returncode, p.stdout, parse_kv_file(out_file)


def load_workflow(path: Path) -> dict:
    wf = yaml.safe_load(path.read_text())
    # PyYAML 把 `on:` 解析成 True——与本执行器无关，丢掉即可
    wf.pop(True, None)
    return wf


# ── gh stub ──────────────────────────────────────────────────────────

GH_STUB = r'''#!/usr/bin/env python3
# dry-run 的 gh 替身：只实现发布链用到的 release 子命令，状态存在本地目录，**不访问网络**。
# 每次调用记一行 JSON 到 calls.jsonl。不认识的子命令 ⇒ 退出 2（dry-run 判红）。
import json, os, shutil, subprocess, sys, fnmatch, datetime
STATE = __STATE__
args = sys.argv[1:]
os.makedirs(STATE, exist_ok=True)
with open(os.path.join(STATE, "calls.jsonl"), "a") as f:
    f.write(json.dumps({"argv": args, "cwd": os.getcwd()}, ensure_ascii=False) + "\n")
def rel_dir(tag): return os.path.join(STATE, "releases", tag)
def meta(tag):
    p = os.path.join(rel_dir(tag), "meta.json")
    return json.load(open(p)) if os.path.exists(p) else None
def save(tag, m):
    os.makedirs(os.path.join(rel_dir(tag), "assets"), exist_ok=True)
    json.dump(m, open(os.path.join(rel_dir(tag), "meta.json"), "w"), ensure_ascii=False, indent=1)
def now(): return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
def opt(name, default=None):
    for i, a in enumerate(args):
        if a == name and i + 1 < len(args): return args[i + 1]
        if a.startswith(name + "="): return a.split("=", 1)[1]
    return default
def flag(name): return any(a == name or a.startswith(name + "=") for a in args)
def positional():
    out, skip = [], False
    takes = {"-R", "--repo", "-q", "--jq", "--json", "-p", "--pattern", "-O", "--output", "-L", "--limit",
             "--title", "--notes-file", "--notes", "--target", "-t"}
    for a in args[2:]:
        if skip: skip = False; continue
        if a in takes: skip = True; continue
        if a.startswith("-"): continue
        out.append(a)
    return out
def fail(msg, rc=1): sys.stderr.write(msg + "\n"); sys.exit(rc)
if args[:1] != ["release"]: fail(f"gh stub: unsupported {args}", 2)
sub = args[1] if len(args) > 1 else ""
pos = positional()
if sub == "view":
    m = meta(pos[0])
    if m is None: fail("release not found")
    if opt("--json"):
        data = {"isDraft": m["draft"], "isPrerelease": m["prerelease"], "tagName": pos[0], "body": m.get("body", "")}
        q = opt("-q") or opt("--jq") or "."
        r = subprocess.run(["jq", "-r", q], input=json.dumps(data), text=True, capture_output=True)
        sys.stdout.write(r.stdout); sys.exit(r.returncode)
    print(f"title:\t{m['title']}\ntag:\t{pos[0]}\ndraft:\t{str(m['draft']).lower()}")
elif sub == "create":
    tag = pos[0]
    if meta(tag) is not None: fail(f"release {tag} already exists")
    nf = opt("--notes-file")
    m = {"title": opt("--title", tag), "draft": flag("--draft"), "prerelease": flag("--prerelease"),
         "body": open(nf).read() if nf else "", "publishedAt": None}
    if not m["draft"]: m["publishedAt"] = now()
    save(tag, m)
elif sub == "edit":
    tag = pos[0]; m = meta(tag)
    if m is None: fail("release not found")
    if opt("--notes-file"): m["body"] = open(opt("--notes-file")).read()
    if flag("--draft"):
        m["draft"] = opt("--draft", "true") != "false"
        if not m["draft"] and not m["publishedAt"]: m["publishedAt"] = now()
    if flag("--prerelease"): m["prerelease"] = opt("--prerelease", "true") != "false"
    save(tag, m)
elif sub == "upload":
    tag, files = pos[0], pos[1:]
    if meta(tag) is None: fail("release not found")
    if not files: fail("no files to upload")
    for f in files:
        if not os.path.isfile(f): fail(f"upload: {f} not found")
        dst = os.path.join(rel_dir(tag), "assets", os.path.basename(f))
        if os.path.exists(dst) and not flag("--clobber"): fail(f"asset {os.path.basename(f)} already exists")
        shutil.copyfile(f, dst)
elif sub == "download":
    tag = pos[0]
    if meta(tag) is None: fail("release not found")
    assets = os.path.join(rel_dir(tag), "assets")
    pats = [args[i + 1] for i, a in enumerate(args) if a in ("-p", "--pattern")]
    hits = [n for n in sorted(os.listdir(assets)) if any(fnmatch.fnmatch(n, p) for p in pats)]
    if not hits: fail("no assets match the file pattern")
    out = opt("-O") or opt("--output")
    for n in hits: shutil.copyfile(os.path.join(assets, n), out if out else n)
elif sub == "list":
    rows = []
    for tag in sorted(os.listdir(os.path.join(STATE, "releases"))) if os.path.isdir(os.path.join(STATE, "releases")) else []:
        m = meta(tag)
        if flag("--exclude-drafts") and m["draft"]: continue
        rows.append({"tagName": tag, "publishedAt": m["publishedAt"] or "", "isDraft": m["draft"]})
    q = opt("-q") or opt("--jq") or "."
    r = subprocess.run(["jq", "-r", q], input=json.dumps(rows), text=True, capture_output=True)
    sys.stdout.write(r.stdout); sys.stderr.write(r.stderr); sys.exit(r.returncode)
else:
    fail(f"gh stub: unsupported release {sub}", 2)
'''


def write_gh_stub(bin_dir: Path, state: Path):
    bin_dir.mkdir(parents=True, exist_ok=True)
    p = bin_dir / "gh"
    p.write_text(GH_STUB.replace("__STATE__", json.dumps(str(state))))
    p.chmod(0o755)


def gh_calls(state: Path) -> list:
    f = state / "calls.jsonl"
    return [json.loads(line)["argv"] for line in f.read_text().splitlines()] if f.exists() else []
