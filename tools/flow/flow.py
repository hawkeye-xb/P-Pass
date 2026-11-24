#!/usr/bin/env python3
"""P-Pass V3 统一研发协作引擎：doctor / triage / start / done / dispatch / stuck / owner-stuck / pick-gates / probe-slots / review。"""
from __future__ import annotations
import base64, hashlib, json, os, queue, re, shlex, shutil, signal, subprocess, sys, tempfile, threading, time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

FLOW_DIR = Path(__file__).resolve().parent
TEST_RE = re.compile(r"(\.(test|spec)\.[^/]*$)|((^|/)(PPassTests|Tests|tests|test|__tests__|androidTest|sharedTest)/)")
FAKE_SRC_READ_RE = re.compile(r"""(\.(?:rs|kt|swift|svelte)\b[^\n]{0,120}read_text|open\([^)\n]*\.(?:rs|kt|swift|svelte)["'])""")
NONE_VAL_RE = re.compile(r"^(无|没有|不涉及|none|无。)$", re.I)
_GIT_VARS = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR", "GIT_PREFIX")

PRIO_MATRIX = {
    ("不可挽回", "停线"): "P0", ("不可挽回", "截止日"): "P1", ("不可挽回", "线性"): "P1", ("不可挽回", "无"): "P1",
    ("面广", "停线"): "P0", ("面广", "截止日"): "P1", ("面广", "线性"): "P2", ("面广", "无"): "P3",
    ("局部", "停线"): "P0", ("局部", "截止日"): "P2", ("局部", "线性"): "P3", ("局部", "无"): "P3",
    ("可挽回·局部", "停线"): "P0", ("可挽回·局部", "截止日"): "P2", ("可挽回·局部", "线性"): "P3", ("可挽回·局部", "无"): "P3",
}


def die(msg: str, code: int = 1) -> int:
    print(f"✗ {msg}", file=sys.stderr)
    return code


def run_p(cmd: list[str], cwd: str, timeout: int = 600, extra_env: dict | None = None, stdin_text: str | None = None) -> subprocess.CompletedProcess:
    env = {k: v for k, v in os.environ.items() if k not in _GIT_VARS}
    env.setdefault("GIT_TEMPLATE_DIR", "")
    env.setdefault("LC_ALL", "en_US.UTF-8")
    for k, v in (extra_env or {}).items():
        if v is None:
            env.pop(k, None)
        else:
            env[k] = v
    p = subprocess.Popen(
        cmd, cwd=cwd, env=env,
        stdin=subprocess.PIPE if stdin_text is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True,
    )
    try:
        out, err = p.communicate(input=stdin_text, timeout=timeout)
        return subprocess.CompletedProcess(cmd, p.returncode, out, err)
    except subprocess.TimeoutExpired:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(p.pid, sig)
                time.sleep(0.2)
            except (ProcessLookupError, PermissionError):
                try:
                    p.kill()
                except OSError:
                    pass
                break
        out, err = p.communicate()
        return subprocess.CompletedProcess(cmd, 124, out or "", f"{err or ''}\nTIMEOUT after {timeout}s")


def repo_roots(cwd: str | None = None) -> tuple[str, str]:
    d = cwd or os.getcwd()
    top = run_p(["git", "rev-parse", "--show-toplevel"], d, 15)
    com = run_p(["git", "rev-parse", "--path-format=absolute", "--git-common-dir"], d, 15)
    if top.returncode != 0 or com.returncode != 0:
        raise RuntimeError("当前目录不在 git 仓库里")
    return os.path.realpath(top.stdout.strip()), os.path.realpath(os.path.dirname(com.stdout.strip()))


def repo_slug(cwd: str) -> str:
    r = os.environ.get("PPASS_HOOK_REPO") or os.environ.get("PPASS_OWNER_REPO") or ""
    if not r:
        u = run_p(["git", "config", "--get", "remote.origin.url"], cwd, 10).stdout.strip().rstrip("/")
        m = re.search(r"[:/]([^/:]+/[^/:]+)$", u[:-4] if u.endswith(".git") else u)
        r = m.group(1) if m else ""
    if not re.fullmatch(r"[^/\s]+/[^/\s]+", r):
        raise RuntimeError("解析不出 GitHub 仓库（设 PPASS_HOOK_REPO=<owner>/<repo>）")
    return r


def gh_issue(repo: str, num: str, cwd: str) -> dict:
    r = run_p(
        ["gh", "issue", "view", str(num), "-R", repo, "--json", "state,title,labels,body",
         "--jq", '"state:" + .state, "title:" + .title, "labels:" + ([.labels[].name] | join(",")), "body:", .body'],
        cwd, 30,
    )
    if r.returncode != 0:
        raise RuntimeError(f"读取 {repo}#{num} 失败：{r.stderr.strip() or r.stdout.strip()}")
    ls = r.stdout.replace("\r", "").splitlines()
    t_api = run_p(["gh", "api", f"repos/{repo}/issues/{num}", "--jq", ".type.name // empty"], cwd, 15)
    itype = t_api.stdout.strip() if t_api.returncode == 0 else ""
    return {
        "state": ls[0][6:] if ls else "",
        "title": ls[1][6:] if len(ls) > 1 else "",
        "labels": [x for x in (ls[2][7:] if len(ls) > 2 else "").split(",") if x],
        "body": "\n".join(ls[4:]) if len(ls) > 4 else "",
        "type": itype,
    }


def extract_field(text: str, field_name: str) -> str:
    """提取 Markdown 中 **字段名**：后面的非注释有效内容。"""
    clean = re.sub(r"<!--.*?-->", "", (text or "").replace("\r", ""), flags=re.S)
    pat = re.compile(rf"^\*\*{re.escape(field_name)}(?:（[^）]*）)?\*\*[：:]?[ \t]*(.*)$", re.M)
    m = pat.search(clean)
    if not m:
        return ""
    lines = [m.group(1).strip()] if m.group(1).strip() else []
    for ln in clean[m.end():].splitlines():
        s = ln.strip()
        if not s:
            continue
        if re.match(r"^(\*\*[^*]+\*\*|#)", s):
            break
        lines.append(s)
    return "\n".join(lines).strip()


def check_device_ready(dev_dir: str, dev_name: str | None, unattended: bool = True) -> tuple[bool, str]:
    if not dev_name or dev_name in ("无", "none"):
        return True, "no_device_needed"
    owner_f, state_f = Path(dev_dir) / f"owner-{dev_name}", Path(dev_dir) / f"{dev_name}.state"
    who = owner_f.read_text(encoding="utf-8").split("\t")[0].strip() if owner_f.is_file() else ""
    if who and who != os.environ.get("PPASS_DEVICE_OWNER", ""):
        return False, f"device {dev_name} claimed by {who}"
    st = state_f.read_text(encoding="utf-8").strip() if state_f.is_file() else ("UNLOCKED" if dev_name in ("mac", "android", "ios", "win") else "OFFLINE")
    if st != "UNLOCKED":
        return False, f"device {dev_name} unavailable (state={st})"
    for lf in (Path(dev_dir) / f"lock-{dev_name}", Path(dev_dir) / f"{dev_name}.lock"):
        if os.path.exists("/usr/bin/lockf") and lf.exists():
            if subprocess.run(["/usr/bin/lockf", "-k", "-t", "0", str(lf), "/usr/bin/true"], capture_output=True).returncode != 0:
                return False, f"device {dev_name} lock busy"
    return True, "ok"


def pick_gates(files: list[str], repo_dir: str) -> list[str]:
    """按改动精准挑本机验证命令，绝不因未知配置文件（.gitignore / assets/contracts/ 等）罚跑全仓 just ci。"""
    gates: list[str] = []
    add = lambda g: gates.append(g) if g not in gates else None
    code_touched = False
    for f in [x.strip() for x in files if x.strip()]:
        if f.startswith(("docs/", "release/notes/")) or f.endswith(".md"):
            add("just ci-docs" if f == "AGENTS.md" else "just md-check")
            continue
        code_touched = True
        if f.startswith("apps/android/"):
            add("just android-test")
            if "strings" in os.path.basename(f) and f.endswith(".xml"):
                add("just mobile-static-check")
        elif f.startswith("tools/ios/test-") and f.endswith(".sh"):
            if os.path.isfile(os.path.join(repo_dir, f)):
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
        elif f.startswith("apps/desktop/src-tauri/"):
            for sub in (
                "nextest run --manifest-path apps/desktop/src-tauri/Cargo.toml -p p-pass-desktop",
                "clippy --manifest-path apps/desktop/src-tauri/Cargo.toml --all-targets -- -D warnings",
                "fmt --manifest-path apps/desktop/src-tauri/Cargo.toml -- --check",
            ):
                add(f"cargo {sub}")
        elif f.startswith("apps/desktop/src/"):
            add("pnpm -C apps/desktop test")
        elif f.startswith("crates/") and len(Path(f).parts) >= 2:
            ctoml = Path(repo_dir) / "crates" / Path(f).parts[1] / "Cargo.toml"
            m = re.search(r'^name\s*=\s*"([^"]+)"', ctoml.read_text(encoding="utf-8"), re.M) if ctoml.is_file() else None
            if m:
                add(f"cargo nextest run -p {m.group(1)}")
                add(f"cargo clippy -p {m.group(1)} --all-targets -- -D warnings")
                add("cargo fmt --all -- --check")
        elif f.startswith("tools/flow/") or f == "tools/test-flow.py":
            add("python3 -B -I tools/test-flow.py")
        elif f.startswith("tools/e3/"):
            add("bash tools/test-e3.sh")
        elif f.startswith(".github/workflows/"):
            add("actionlint")
    if code_touched:
        add("just arch-check")
        add("just fitness-check")
    elif not gates:
        add("just md-check")
    return gates


def cmd_doctor(cwd: str) -> int:
    try:
        top, main_root = repo_roots(cwd)
    except RuntimeError as e:
        return die(str(e))
    if os.path.exists(os.path.join(top, ".ppass-verify-clone")) or os.path.exists(os.path.join(main_root, ".ppass-verify-clone")):
        return die("Windows 回归专用克隆不能当日常工作目录")
    hk = os.path.join(top, "tools/hooks/install.sh")
    if os.path.isfile(hk) and run_p(["bash", hk, "--check"], top, 15).returncode != 0:
        return die("本地提交拦截未安装（运行 bash tools/hooks/install.sh）")
    name = run_p(["git", "config", "user.name"], top, 5).stdout.strip()
    email = run_p(["git", "config", "user.email"], top, 5).stdout.strip()
    wl = Path(top) / ".github/allowed-identities.txt"
    if wl.is_file() and f"{name} <{email}>" not in wl.read_text(encoding="utf-8").splitlines():
        return die(f"提交身份 {name} <{email}> 不在 .github/allowed-identities.txt")
    min_gb = int(os.environ.get("PPASS_DOCTOR_MIN_FREE_GB", "15"))
    clean_gb = int(os.environ.get("PPASS_DOCTOR_AUTOCLEAN_GB", "25"))
    free_gb = int(os.environ.get("PPASS_DOCTOR_FAKE_FREE_GB", str(shutil.disk_usage(main_root).free // (1024 ** 3))))
    if free_gb < clean_gb:
        clean_cmd, cleaner = os.environ.get("PPASS_DOCTOR_CLEAN_CMD"), os.path.join(main_root, "tools/clean-local-builds.sh")
        if clean_cmd:
            run_p(["bash", "-c", clean_cmd], main_root, 300)
        elif os.path.isfile(cleaner):
            print(f"==> 磁盘剩余 {free_gb}G < {clean_gb}G：自动运行 cleanup-local 回收缓存...")
            run_p(["bash", cleaner, "--cache", "--targets", "--apply"], main_root, 300)
        free_gb = int(os.environ.get("PPASS_DOCTOR_FAKE_AFTER_CLEAN_GB", str(shutil.disk_usage(main_root).free // (1024 ** 3))))
    if free_gb < min_gb:
        return die(f"磁盘剩余 {free_gb}G < {min_gb}G")
    print(f"==> doctor ok（main={main_root}，free={free_gb}G）")
    return 0


def cmd_triage(argv: list[str], cwd: str) -> int:
    if not argv or not argv[0].isdigit():
        return die("用法: just triage <issue号> [--mode fix|feature|verify] [--priority P0..P3] [--needs-product]", 2)
    num, mode, prio, needs_prod, i = argv[0], "fix", "", False, 1
    while i < len(argv):
        if argv[i] == "--mode" and i + 1 < len(argv):
            mode, i = argv[i + 1], i + 2
        elif argv[i] == "--priority" and i + 1 < len(argv):
            prio, i = argv[i + 1], i + 2
        elif argv[i] == "--needs-product":
            needs_prod, i = True, i + 1
        else:
            return die(f"未知参数: {argv[i]}（已废除方案文件填表，直接用 --priority/--mode）", 2)
    if mode not in ("fix", "feature", "verify"):
        return die("mode 仅限 fix/feature/verify", 2)
    repo = repo_slug(cwd)
    info = gh_issue(repo, num, cwd)
    if not prio:
        imp = extract_field(info["body"], "影响").splitlines()[0].strip() if extract_field(info["body"], "影响") else ""
        urg = extract_field(info["body"], "时间性").splitlines()[0].strip() if extract_field(info["body"], "时间性") else ""
        prio = PRIO_MATRIX.get((imp, urg), "P2")
    if prio not in ("P0", "P1", "P2", "P3"):
        return die("priority 仅限 P0..P3", 2)
    if info["title"].startswith("[MAIN-RED]"):
        prio = "P0"
    target = "needs:product" if needs_prod else "status:ready"
    rm = ",".join(l for l in info["labels"] if (l.startswith("status:") and l != target) or (l in ("P0", "P1", "P2", "P3") and l != prio))
    cmd = ["gh", "issue", "edit", num, "-R", repo, "--add-label", f"status:inbox,needs:product,{prio}" if needs_prod else f"{target},{prio}"]
    if rm:
        cmd += ["--remove-label", rm]
    if run_p(cmd, cwd, 20).returncode != 0:
        return die(f"更新 #{num} 标签失败")
    print(f"TRIAGE #{num} {target} mode={mode}\nPRIORITY #{num} {prio}")
    return 0


def validate_cards_for_start(cards: list[str], repo: str, cwd: str, unattended: bool) -> tuple[int, str, list[dict]]:
    """开工前逐张校验全部关联卡：OPEN + status:ready + 有验收场景 + Bug 卡有复现路径 + 无人模式逐台查设备。"""
    infos: list[dict] = []
    req_devs: list[str] = []
    for c in cards:
        info = gh_issue(repo, c, cwd)
        if info["state"] != "OPEN":
            return 1, f"#{c} 不是 OPEN 状态（当前: {info['state']}）", []
        if "status:ready" not in info["labels"]:
            return 1, f"#{c} 没有 status:ready 标签（当前: {info['labels']}）", []
        accept = extract_field(info["body"], "验收场景")
        if not accept or NONE_VAL_RE.match(accept.splitlines()[0].strip()):
            return 1, f"#{c} 缺少可读的 **验收场景**，不能领卡", []
        is_bug = info.get("type") == "Bug" or "bug" in info["labels"]
        if is_bug:
            repro = extract_field(info["body"], "复现路径")
            if not repro or NONE_VAL_RE.match(repro.splitlines()[0].strip()):
                return 1, f"#{c} 是 Bug 卡但缺少可读的 **复现路径**，不能领卡", []
        bn = info["body"].replace("：", ":")
        for m_dev in re.finditer(r"^\*\*设备\*\*:\s*(\S+)", bn, re.M):
            if m_dev.group(1) not in req_devs:
                req_devs.append(m_dev.group(1))
        if re.search(r"真机验证[^:]*:\s*需要", bn) and not req_devs:
            req_devs.append("ios")
        infos.append(info)
    if unattended:
        dev_dir = os.environ.get("PPASS_V3_DEV_DIR", os.path.expanduser("~/.cache/ppass-e3"))
        for d in req_devs:
            ok_d, msg_d = check_device_ready(dev_dir, d, unattended=True)
            if not ok_d:
                return 3, f"SUSPENDED_ENV #{cards[0]}: {msg_d}", []
    return 0, "ok", infos


def cmd_start(argv: list[str], cwd: str) -> int:
    cards, name, t_ovr, unattended, i = [], "", "", os.environ.get("PPASS_UNATTENDED") == "1", 0
    while i < len(argv):
        a = argv[i]
        if a == "--name" and i + 1 < len(argv):
            name, i = argv[i + 1], i + 2
        elif a == "--type" and i + 1 < len(argv):
            t_ovr, i = argv[i + 1], i + 2
        elif a == "--unattended":
            unattended, i = True, i + 1
        elif a.isdigit():
            if a not in cards:
                cards.append(a)
            i += 1
        else:
            return die(f"用法: just start <issue号> [<issue号>...] [--name <slug>] [--unattended]（未知 {a}）", 2)
    if not cards:
        return die("用法: just start <issue号>", 2)
    if cmd_doctor(cwd) != 0:
        return 1
    _, main_root = repo_roots(cwd)
    repo = repo_slug(cwd)
    rc_v, msg_v, infos = validate_cards_for_start(cards, repo, cwd, unattended)
    if rc_v == 3:
        print(msg_v)
        return 3
    if rc_v != 0:
        return die(msg_v)
    first = infos[0]
    has_feat = any(x.get("type") == "Feature" or "enhancement" in x["labels"] for x in infos)
    btype = t_ovr or ("feat" if has_feat else "fix")
    slug = re.sub(r"[^a-z0-9]+", "-", (name or re.sub(r"^\[[^\]]*\]", "", first["title"])).lower()).strip("-")[:36] or "task"
    branch = f"{btype}/{cards[0]}-{slug}"
    wt_root = os.environ.get("PPASS_WT_ROOT") or os.path.join(main_root, ".worktrees")
    wt_dir = os.path.join(wt_root, f"{cards[0]}-{slug}")
    os.makedirs(wt_root, exist_ok=True)
    run_p(["git", "fetch", "-q", "origin", "--prune"], main_root, 30)
    if os.path.exists(wt_dir) or run_p(["git", "rev-parse", "-q", "--verify", f"refs/heads/{branch}"], main_root, 10).returncode == 0:
        return die(f"分支 {branch} 或目录 {wt_dir} 已存在")
    if run_p(["git", "worktree", "add", wt_dir, "-b", branch, "origin/main"], main_root, 30).returncode != 0:
        return die(f"创建仓内 worktree 失败：{wt_dir}")
    run_p(["git", "branch", "--unset-upstream"], wt_dir, 10)
    if len(cards) > 1:
        run_p(["git", "config", f"branch.{branch}.ppasscards", " ".join(cards)], wt_dir, 10)
    for rel in ("apps/android/local.properties", ".env.ppass-dev"):
        for cand in (os.path.join(main_root, rel), os.path.join(os.path.dirname(main_root), rel)):
            if os.path.isfile(cand) and not os.path.exists(os.path.join(wt_dir, rel)):
                os.makedirs(os.path.dirname(os.path.join(wt_dir, rel)), exist_ok=True)
                shutil.copy2(cand, os.path.join(wt_dir, rel))
    for c in cards:
        run_p(["gh", "issue", "edit", c, "-R", repo, "--add-label", "status:doing", "--remove-label", "status:ready"], wt_dir, 20)
    print(f"✅ 已领 #{cards[0]}（仓内目录：{wt_dir}，分支：{branch}）")
    return 0


def verify_real_tests_and_counterproof(wt: str, main_root: str, base_sha: str, files: list[str], mode: str) -> tuple[bool, str]:
    exam_hits = [f for f in files if re.search(r"(^|/)exam_[^/]*$", f) and os.path.exists(os.path.join(wt, f))]
    if exam_hits:
        return False, f"FAKE_TEST_BLOCKED: 严禁新增一次性考卷文件 {exam_hits}"
    test_files = [f for f in files if TEST_RE.search(f) and os.path.isfile(os.path.join(wt, f))]
    for tf in test_files:
        if FAKE_SRC_READ_RE.search(Path(wt, tf).read_text(encoding="utf-8", errors="ignore")):
            return False, f"FAKE_TEST_BLOCKED: 测试 {tf} 读取业务源码字符串充当断言"
    if mode != "fix" or os.environ.get("PPASS_SKIP_COUNTERPROOF") == "1":
        return True, "ok"
    if not test_files:
        return False, "COUNTERPROOF_MISSING_TEST: fix 卡必须在正式测试目录新增或更新回归单测"
    t_gates = [g for g in pick_gates(test_files, wt) if not g.startswith(("just arch-check", "just fitness-check", "cargo fmt", "cargo clippy"))]
    cp_cmd = os.environ.get("PPASS_COUNTERPROOF_CMD") or (" && ".join(t_gates) if t_gates else "")
    if not cp_cmd:
        return True, "ok"
    bwt = tempfile.mkdtemp(prefix="v3_cp_")
    try:
        if run_p(["git", "worktree", "add", "-q", "--detach", bwt, base_sha], main_root, 30).returncode != 0:
            return False, "COUNTERPROOF_WORKTREE_ERR"
        for tf in test_files:
            os.makedirs(os.path.dirname(os.path.join(bwt, tf)), exist_ok=True)
            shutil.copy2(os.path.join(wt, tf), os.path.join(bwt, tf))
        r = run_p(["bash", "-c", cp_cmd], bwt, 180)
        out = (r.stdout or "") + "\n" + (r.stderr or "")
        if r.returncode == 0:
            return False, "COUNTERPROOF_FAIL: 回归单测在未修复的基线上通过了"
        if r.returncode == 124 or any(x in out for x in ("SyntaxError", "IndentationError", "error[E", "cannot find")):
            return False, f"COUNTERPROOF_COMPILE_ERR: 基线编译/语法错误：{out[-160:]}"
        return True, "counterproof_ok"
    finally:
        run_p(["git", "worktree", "remove", "--force", bwt], main_root, 20)
        shutil.rmtree(bwt, ignore_errors=True)


def cmd_done(argv: list[str], cwd: str) -> int:
    unattended = "--unattended" in argv or os.environ.get("PPASS_UNATTENDED") == "1"
    rebase_gate = unattended or "--rebase" in argv or os.environ.get("PPASS_REBASE_GATE") == "1"
    top, main_root = repo_roots(cwd)
    if top == main_root:
        return die("不能在主仓运行 just done，请进 .worktrees/<卡目录>")
    branch = run_p(["git", "symbolic-ref", "--quiet", "--short", "HEAD"], top, 10).stdout.strip()
    m = re.match(r"^(feat|fix|docs|test|ci)/([0-9]+)-", branch)
    if not m:
        return die(f"当前分支 {branch} 不是卡分支")
    mode = "feature" if ("--feature" in argv or m.group(1) != "fix") else "fix"
    num = m.group(2)
    extra_cards = run_p(["git", "config", "--get", f"branch.{branch}.ppasscards"], top, 5).stdout.split()
    cards = [num] + [c for c in extra_cards if c != num and c.isdigit()]
    if run_p(["git", "status", "--porcelain"], top, 10).stdout.strip():
        return die("工作区有未提交改动")
    repo = repo_slug(top)
    run_p(["git", "fetch", "-q", "origin", "+refs/heads/main:refs/remotes/origin/main"], top, 30)
    if int(run_p(["git", "rev-list", "--count", "origin/main..HEAD"], top, 10).stdout.strip() or "0") == 0:
        return die("相对 origin/main 没有任何提交")
    evid = Path(main_root) / ".worktrees" / ".evidence" / num
    evid.mkdir(parents=True, exist_ok=True)
    fail_f = evid / "fail-count"

    def fail_local(reason: str) -> int:
        cnt = int(fail_f.read_text() if fail_f.is_file() else "0") + 1
        fail_f.write_text(str(cnt))
        if unattended and cnt >= 2:
            print(f"SUSPENDED_CIRCUIT_BREAK #{num}: 连续 {cnt} 轮未过门禁（{reason}）", file=sys.stderr)
            return 4
        return die(f"本地门禁未过（第 {cnt} 次）：{reason}")

    if rebase_gate and run_p(["git", "merge-base", "--is-ancestor", "origin/main", "HEAD"], top, 10).returncode != 0:
        if run_p(["git", "rebase", "origin/main"], top, 30).returncode != 0:
            run_p(["git", "rebase", "--abort"], top, 10)
            print("SUSPENDED_CONFLICT: auto-rebase failed; safely aborted", file=sys.stderr)
            return 3
    infos = [gh_issue(repo, c, top) for c in cards]
    is_core = any("core" in x["labels"] for x in infos)
    need_verify = any(re.search(r"真机验证[^:]*:\s*需要", x["body"].replace("：", ":")) for x in infos)
    files = [x for x in run_p(["git", "-c", "core.quotepath=false", "diff", "--name-only", "--no-renames", "origin/main...HEAD"], top, 15).stdout.splitlines() if x.strip()]
    diff_f, core_f = str(evid / "branch.diff"), str(evid / "base-core.txt")
    Path(diff_f).write_text(run_p(["git", "-c", "core.quotepath=false", "diff", "--no-renames", "origin/main...HEAD"], top, 20).stdout, encoding="utf-8")
    Path(core_f).write_text(run_p(["git", "show", "origin/main:.github/core-paths.txt"], top, 10).stdout or Path(top, ".github/core-paths.txt").read_text(encoding="utf-8"), encoding="utf-8")
    if run_p(["bash", os.path.join(top, "tools/ci-paths.sh"), "core", "-", core_f, "--diff", diff_f], top, 15, stdin_text="\n".join(files) + "\n").stdout.strip() != "false" and not is_core:
        for c in cards:
            run_p(["gh", "issue", "edit", c, "-R", repo, "--add-label", "status:blocked", "--remove-label", "status:doing"], top, 20)
        return die(f"CORE_PATH_BLOCKED: #{num} 无 core 标签禁止修改核心路径")
    ok_cp, msg_cp = verify_real_tests_and_counterproof(top, main_root, run_p(["git", "merge-base", "origin/main", "HEAD"], top, 10).stdout.strip(), files, mode)
    if not ok_cp:
        return fail_local(msg_cp)
    gates = pick_gates(files, top)
    if need_verify and run_p(["just", "--show", "verify"], top, 10).returncode == 0:
        gates.append(f"just verify {num}")
    heavy = os.path.join(top, "tools/heavy-lock")
    for g in gates:
        r = run_p(([heavy, "bash", "-c", g] if os.path.isfile(heavy) and not os.environ.get("PPASS_NO_LOCK") else ["bash", "-c", g]), top, 900)
        if r.returncode != 0:
            return fail_local(f"{g} 失败: {(r.stdout + r.stderr)[-200:]}")
    if run_p(["git", "push", "-u"] + (["--force-with-lease"] if rebase_gate else []) + ["origin", f"HEAD:refs/heads/{branch}"], top, 60).returncode != 0:
        return die("git push 失败")
    fail_f.unlink(missing_ok=True)
    receipt, pr_body = evid / "receipt.md", evid / "pr-body.md"
    receipt.write_text(f"**worker 已交卡**\n\n- 分支：`{branch}`\n- 门禁：`{' + '.join(gates)}` 通过\n", encoding="utf-8")
    closes_hdr = "\n".join(f"closes #{c}" for c in cards)
    pr_body.write_text(f"{closes_hdr}\n\n" + receipt.read_text(encoding="utf-8"), encoding="utf-8")
    for c in cards:
        run_p(["gh", "issue", "comment", c, "-R", repo, "--body-file", str(receipt)], top, 20)
        run_p(["gh", "issue", "edit", c, "-R", repo, "--add-label", "status:review", "--remove-label", "status:doing,status:blocked"], top, 20)
    print(f"gh pr create -R '{repo}' --base main --head '{branch}' --title '{run_p(['git', 'log', '-1', '--format=%s'], top, 5).stdout.strip()}' --body-file '{pr_body}'\ngh pr merge --auto --squash <PR号> --repo {repo}")
    return 0


def probe_slots(unattended: bool) -> list[dict]:
    """自适应探测当前可用资源槽位：白天本机硬限 1 槽保秒回；若探测到空闲远端节点则登记为独立 remote 槽。"""
    ssh_bin = os.environ.get("PPASS_SSH_BIN", "ssh")
    slots = [{"kind": "local", "host": "localhost", "slots": 2 if unattended else 1}]
    rem = os.environ.get("PPASS_REMOTE_WORKER", "")
    cand = "" if rem == "none" else (rem or ("ppass-win" if Path("~/.ssh/ppass_win").expanduser().is_file() else ""))
    if cand and subprocess.run([ssh_bin, "-o", "BatchMode=yes", "-o", "ConnectTimeout=1", cand, "echo ok"], capture_output=True).returncode == 0:
        slots.insert(0, {"kind": "remote", "host": cand, "slots": 1})
    return slots


def run_watchdog_tasks(tasks: list[dict], unattended: bool = False, timeout_sec: int = 900) -> list[dict]:
    """自适应分流执行器：跨平台/非 macOS 专属任务真实经 SSH 分流到空闲远端槽，本机严格受 local_cap 信号量保护（白天最多 1 槽）。"""
    shim_dir = FLOW_DIR / ".shim-bin"
    shim_dir.mkdir(exist_ok=True)
    if not (shim_dir / "gh").exists():
        (shim_dir / "gh").symlink_to(FLOW_DIR / "gh-readonly-shim.sh")
    slots = probe_slots(unattended)
    local_cap = next((s["slots"] for s in slots if s["kind"] == "local"), 1)
    remote_hosts = [s["host"] for s in slots if s["kind"] == "remote"]
    local_sem = threading.Semaphore(local_cap)
    remote_q: queue.Queue[str] = queue.Queue()
    for h in remote_hosts:
        remote_q.put(h)
    ssh_bin = os.environ.get("PPASS_SSH_BIN", "ssh")
    rem_cwd = os.environ.get("PPASS_REMOTE_CWD", "")
    dev_dir = os.environ.get("PPASS_V3_DEV_DIR", os.path.expanduser("~/.cache/ppass-e3"))

    def _one(t: dict) -> dict:
        req_dev = t.get("device")
        ok_d, msg_d = check_device_ready(dev_dir, req_dev, unattended=unattended)
        if not ok_d:
            return {"id": t["id"], "status": "SUSPENDED_ENV", "target": "none", "reason": msg_d}
        can_remote = bool(remote_hosts) and req_dev not in ("ios", "mac") and not t.get("local_only", False)
        rhost = None
        if can_remote:
            try:
                rhost = remote_q.get_nowait()
            except queue.Empty:
                rhost = None
        tmo = int(t.get("timeout", timeout_sec))
        if rhost:
            try:
                rcmd_str = " ".join(shlex.quote(x) for x in t["cmd"])
                full_rem = f"cd {shlex.quote(rem_cwd)} && {rcmd_str}" if rem_cwd else rcmd_str
                r = run_p([ssh_bin, "-o", "BatchMode=yes", rhost, full_rem], t["cwd"], timeout=tmo)
                st = "SUSPENDED_TIMEOUT" if r.returncode == 124 else ("OK" if r.returncode == 0 else "FAILED")
                return {"id": t["id"], "status": st, "target": f"remote:{rhost}", "rc": r.returncode, "out": (r.stdout + r.stderr)[-200:]}
            finally:
                remote_q.put(rhost)
        with local_sem:
            env = {"PATH": f"{shim_dir}:{os.environ.get('PATH', '')}", "PPASS_WORKER_NO_SUBSESSION": "1"}
            r = run_p(t["cmd"], t["cwd"], timeout=tmo, extra_env=env)
            st = "SUSPENDED_TIMEOUT" if r.returncode == 124 else ("OK" if r.returncode == 0 else "FAILED")
            return {"id": t["id"], "status": st, "target": "local", "rc": r.returncode, "out": (r.stdout + r.stderr)[-200:]}

    total_workers = local_cap + len(remote_hosts)
    with ThreadPoolExecutor(max_workers=max(1, total_workers)) as ex:
        return list(ex.map(_one, tasks))


def cmd_dispatch(argv: list[str], cwd: str) -> int:
    """生产级自适应派发入口：just dispatch [--unattended] [--timeout <sec>] -- <cmd...>（或 --spec <tasks.json>）。"""
    unattended, tmo, spec_f, i = "--unattended" in argv, 900, "", 0
    cmd_part: list[str] = []
    while i < len(argv):
        if argv[i] == "--unattended":
            i += 1
        elif argv[i] == "--timeout" and i + 1 < len(argv):
            tmo, i = int(argv[i + 1]), i + 2
        elif argv[i] == "--spec" and i + 1 < len(argv):
            spec_f, i = argv[i + 1], i + 2
        elif argv[i] == "--":
            cmd_part = argv[i + 1:]
            break
        else:
            return die(f"用法: just dispatch [--unattended] [--timeout <秒>] [--spec <json> | -- <命令...>]", 2)
    if spec_f:
        tasks = json.loads(Path(spec_f).read_text(encoding="utf-8"))
        for t in tasks:
            t.setdefault("cwd", cwd)
    elif cmd_part:
        tasks = [{"id": "task-1", "cmd": cmd_part, "cwd": cwd, "timeout": tmo}]
    else:
        return die("需要提供 --spec <tasks.json> 或 -- <命令...>", 2)
    res = run_watchdog_tasks(tasks, unattended=unattended, timeout_sec=tmo)
    print(json.dumps(res, ensure_ascii=False))
    return 0 if all(x["status"] == "OK" for x in res) else 1


def cmd_owner_stuck(argv: list[str], cwd: str, is_worker: bool = False) -> int:
    """统一停卡出口：支持 just stuck <号> "<原因>" 与 just owner-stuck "<原因>" [--issue N | --pr N] [--product "<一>" "<二>"] [--log <文件>]。"""
    repo = repo_slug(cwd)
    if is_worker:
        if len(argv) < 2 or not argv[0].isdigit() or not argv[1].strip():
            return die('用法: just stuck <issue号> "<原因>"', 2)
        num, reason = argv[0], " ".join(argv[1:]).strip()
        r1 = run_p(["gh", "issue", "comment", num, "-R", repo, "--body", f"**卡住（status:blocked）**：{reason}"], cwd, 20)
        r2 = run_p(["gh", "issue", "edit", num, "-R", repo, "--add-label", "status:blocked", "--remove-label", "status:doing,status:ready"], cwd, 20)
        if r1.returncode != 0 or r2.returncode != 0:
            return die(f"写入 #{num} 停卡状态失败")
        print(f"ok: #{num} status:blocked")
        return 0
    if not argv or not argv[0].strip():
        return die('用法: just owner-stuck "<原因>" [--issue N | --pr N] [--product "<选项一>" "<选项二>"] [--log <文件>]', 2)
    reason, issue_n, pr_n, log_f, prod_opts, i = argv[0].strip(), "", "", "", [], 1
    while i < len(argv):
        if argv[i] == "--issue" and i + 1 < len(argv):
            issue_n, i = argv[i + 1], i + 2
        elif argv[i] == "--pr" and i + 1 < len(argv):
            pr_n, i = argv[i + 1], i + 2
        elif argv[i] == "--log" and i + 1 < len(argv):
            log_f, i = argv[i + 1], i + 2
        elif argv[i] == "--product":
            if i + 2 >= len(argv) or not argv[i + 1].strip() or not argv[i + 2].strip():
                return die("--product 必须同时给出两个非空选项", 2)
            prod_opts, i = [argv[i + 1].strip(), argv[i + 2].strip()], i + 3
        else:
            return die(f"未知参数: {argv[i]}", 2)
    body = f"**停下原因**：{reason}\n"
    if prod_opts:
        body += f"\n- **选项一**：{prod_opts[0]}\n- **选项二**：{prod_opts[1]}\n"
    if log_f and os.path.isfile(log_f):
        tail = "\n".join(Path(log_f).read_text(encoding="utf-8", errors="ignore").splitlines()[-30:])
        body += f"\n```\n{tail}\n```\n"
    labels = "status:blocked,needs:product" if prod_opts else "status:blocked"
    if issue_n:
        if run_p(["gh", "issue", "comment", issue_n, "-R", repo, "--body", body], cwd, 20).returncode != 0:
            return die(f"评论 #{issue_n} 失败")
        if run_p(["gh", "issue", "edit", issue_n, "-R", repo, "--add-label", labels, "--remove-label", "status:ready,status:doing"], cwd, 20).returncode != 0:
            return die(f"给 #{issue_n} 打 blocked 失败")
        print(f"ok: issue #{issue_n} {labels}")
        return 0
    if pr_n:
        if run_p(["gh", "pr", "comment", pr_n, "-R", repo, "--body", body], cwd, 20).returncode != 0:
            return die(f"评论 PR #{pr_n} 失败")
        print(f"ok: pr #{pr_n} commented")
        return 0
    r = run_p(["gh", "issue", "create", "-R", repo, "--title", f"[BLOCKED] {reason[:72]}", "--label", labels, "--body", body], cwd, 20)
    if r.returncode != 0:
        return die(f"创建 blocked issue 失败：{r.stderr.strip()}")
    print(f"ok: {r.stdout.strip()}")
    return 0


def cmd_review(argv: list[str], cwd: str) -> int:
    """独立只读全量 diff 评审（彻底废除 incremental 增量盲区：每次推送只要整体 diff 变了一律全量评审）。"""
    pr, model, i = "", os.environ.get("PPASS_REVIEW_MODEL", ""), 0
    while i < len(argv):
        if argv[i] == "--model" and i + 1 < len(argv):
            model, i = argv[i + 1], i + 2
        elif not argv[i].startswith("-") and not pr:
            pr, i = argv[i], i + 1
        else:
            return die("用法: review <PR号> [--model <m>]", 2)
    if not pr.isdigit():
        return die("需要数字 PR 号", 2)
    repo, (top, _) = repo_slug(cwd), repo_roots(cwd)
    phase = os.environ.get("PPASS_REVIEW_PHASE", "")
    work = Path(os.environ["PPASS_REVIEW_STATE"]) if phase in ("prepare", "publish") else Path(tempfile.mkdtemp())
    work.mkdir(parents=True, exist_ok=True)
    wt = work / "checkout"
    try:
        if phase != "publish":
            r = run_p(["gh", "pr", "view", pr, "-R", repo, "--json", "state,headRefOid,title,body", "--jq", '"state:" + .state, "sha:" + .headRefOid, "title:" + .title, "body:", .body'], top, 30)
            if r.returncode != 0:
                return die(f"读取 PR #{pr} 失败")
            ls = r.stdout.replace("\r", "").splitlines()
            st, sha, title, pr_body = ls[0][6:], ls[1][4:], ls[2][6:], "\n".join(ls[4:])
            if st != "OPEN" or not re.fullmatch(r"[0-9a-f]{40}", sha):
                return die(f"PR #{pr} 非 OPEN 或头提交无效")
            author = run_p(["gh", "pr", "view", pr, "-R", repo, "--json", "author", "--jq", ".author.login"], top, 15).stdout.strip()
            is_dep = author in ("app/dependabot", "dependabot", "dependabot[bot]")
            cards = [] if is_dep else sorted(set(re.findall(r"(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|refs?)\s+#([0-9]+)", pr_body, re.I)), key=int)
            if not cards and not is_dep:
                return die(f"#{pr} 正文缺少 closes/refs #N")
            card_txt = "Dependabot 依赖升级" if is_dep else "\n".join(f"### #{c}: {gh_issue(repo, c, top)['title']}\n{gh_issue(repo, c, top)['body']}" for c in cards)
            (work / "pr.files").write_text(run_p(["gh", "pr", "diff", pr, "-R", repo, "--name-only"], top, 30).stdout, encoding="utf-8")
            full_diff = run_p(["gh", "pr", "diff", pr, "-R", repo], top, 30).stdout
            (work / "pr.full.diff").write_text(full_diff, encoding="utf-8")
            diff_id = hashlib.sha1(f"blob {len(full_diff.encode())}\0".encode() + full_diff.encode()).hexdigest()
            (work / "core-paths.txt").write_text(run_p(["git", "show", "origin/main:.github/core-paths.txt"], top, 10).stdout, encoding="utf-8")
            fcmd = ["git"] + (["-c", f"http.https://github.com/.extraheader=AUTHORIZATION: basic {base64.b64encode(('x-access-token:' + os.environ['GH_TOKEN']).encode()).decode()}"] if os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("GH_TOKEN") else [])
            if run_p(fcmd + ["fetch", "-q", "origin", f"refs/pull/{pr}/head"], top, 30).returncode != 0 or run_p(["git", "rev-parse", "FETCH_HEAD"], top, 10).stdout.strip() != sha:
                return die("fetch pull head 失败或头提交已变")
            run_p(["git", "worktree", "remove", "--force", str(wt)], top, 15)
            run_p(["git", "worktree", "add", "-q", "--detach", str(wt), sha], top, 20)
            mode_r, reuse_ag, reuse_sha = "full", "", ""
            marks = run_p(["gh", "api", f"repos/{repo}/issues/{pr}/comments", "--paginate", "--jq",
                           r'.[] | select(.body | contains("<!-- ppass-review ")) | [.user.login, (.id | tostring), (.body | capture("(?:^|\n)<!-- ppass-review (?<m>[^<>\r\n]*) -->\\s*\\z").m)] | @tsv'], top, 30).stdout
            for ln in marks.replace("\r", "").splitlines():
                ps = ln.split("\t")
                if len(ps) < 3 or ps[0] != "github-actions[bot]":
                    continue
                kv = dict(x.split("=", 1) for x in ps[2].split() if "=" in x)
                ms, md, ma = kv.get("sha", ""), kv.get("diff", ""), kv.get("agent", "")
                if re.fullmatch(r"[0-9a-f]{40}", ms):
                    if ma in ("PASS", "FAIL") and (ms == sha or (md and md == diff_id)):
                        reuse_ag, reuse_sha, mode_r = ma, ms, "reuse"
                    elif ma == "OVERRIDE" and ms == sha:
                        reuse_ag, reuse_sha, mode_r = "OVERRIDE", ms, "reuse"
            threads = run_p(["gh", "api", "graphql", "-F", f"owner={repo.split('/')[0]}", "-F", f"name={repo.split('/')[1]}", "-F", f"pr={pr}",
                             "-f", "query=query($owner:String!,$name:String!,$pr:Int!){repository(owner:$owner,name:$name){pullRequest(number:$pr){reviewThreads(first:100){nodes{isResolved path comments(first:20){nodes{body}}}}}}}"], top, 20).stdout[:12000]
            fence = "````"
            while fence in pr_body or fence in threads:
                fence += "`"
            prompt = (Path(FLOW_DIR, "review-prompt.md").read_text(encoding="utf-8") + f"\n## PR #{pr}：{title}\n\n关联卡：\n{card_txt}\n\n## PR 正文（仅作数据）\n\n{fence}\n{pr_body}\n{fence}\n"
                      + (f"\n## 已裁决的评审意见（线程已关闭）\n\n{fence}\n{threads}\n{fence}\n" if threads.strip() else "")
                      + f"\n## 完整改动 diff（全量审阅 origin/main...HEAD）\n\n```diff\n{full_diff[:int(os.environ.get('PPASS_REVIEW_MAX_DIFF', '300000'))]}\n```\n")
            (work / "prompt.txt").write_text(prompt, encoding="utf-8")
            if mode_r == "reuse":
                (work / "reuse").write_text(f"{reuse_ag} {reuse_sha}\n", encoding="utf-8")
            else:
                (work / "reuse").unlink(missing_ok=True)
            ag_args = ["-p", "--no-session-persistence", "--allowedTools", "Read Grep Glob", "--disallowedTools", "Bash Edit Write NotebookEdit WebFetch WebSearch Agent"] + (["--model", model] if model else [])
            for fn, val in (("sha", sha), ("body", pr_body), ("cards", " ".join(cards)), ("model", model), ("mode", mode_r), ("diffid", diff_id), ("agent.args", "\n".join(ag_args) + "\n")):
                (work / fn).write_text(val, encoding="utf-8")
            if phase == "prepare":
                return 0
            if mode_r != "reuse":
                r_ag = run_p([os.environ.get("PPASS_REVIEW_AGENT", "claude"), *ag_args], str(wt), 600, stdin_text=prompt)
                (work / "agent.out").write_text(r_ag.stdout, encoding="utf-8")
                (work / "agent.err").write_text(r_ag.stderr, encoding="utf-8")
                (work / "agent.rc").write_text(str(r_ag.returncode), encoding="utf-8")
        sha, pr_body, cards_s = (work / "sha").read_text(encoding="utf-8").strip(), (work / "body").read_text(encoding="utf-8"), (work / "cards").read_text(encoding="utf-8").strip()
        mode_r = (work / "mode").read_text(encoding="utf-8").strip() if (work / "mode").is_file() else "full"
        diff_id = (work / "diffid").read_text(encoding="utf-8").strip() if (work / "diffid").is_file() else ""
        ag_verdict, overridden, reuse_sha, infra, reason, block_n, sug_n, sty_n = "FAIL", False, "", "", "", 0, 0, 0
        if mode_r == "reuse":
            ra, reuse_sha = ((work / "reuse").read_text(encoding="utf-8").split() + ["", ""])[:2]
            if ra in ("PASS", "OVERRIDE"):
                ag_verdict, overridden = "PASS", (ra == "OVERRIDE")
        else:
            rc_s = (work / "agent.rc").read_text(encoding="utf-8").strip() if (work / "agent.rc").is_file() else "1"
            ag_out = (work / "agent.out").read_text(encoding="utf-8") if (work / "agent.out").is_file() else ""
            ag_err = (work / "agent.err").read_text(encoding="utf-8") if (work / "agent.err").is_file() else ""
            ne = [x.strip() for x in ag_out.replace("\r", "").splitlines() if x.strip()]
            if not rc_s.isdigit() or int(rc_s) != 0:
                infra = f"agent rc={rc_s}: {ag_err[:300]}"
            elif not ne or ne[-1] not in ("VERDICT: PASS", "VERDICT: FAIL"):
                infra = "缺少末尾 VERDICT: PASS/FAIL"
            else:
                cnt = lambda t: len(re.findall(rf"^\s*(?:[-*]\s*)?(?:\*\*)?\[{t}\]", ag_out, re.M))
                block_n, sug_n, sty_n = cnt("阻断"), cnt("建议"), cnt("风格")
                if block_n == 0 and (ne[-1] == "VERDICT: PASS" or (sug_n + sty_n) > 0):
                    ag_verdict = "PASS"
        if infra:
            (work / "infra.md").write_text(f"**独立评审：评审没跑成**（`{sha[:10]}`）\n\n原因：{re.sub(r'<!-- *ppass-review', '<!- ppass-review', infra)}\n", encoding="utf-8")
            run_p(["gh", "pr", "comment", pr, "-R", repo, "--body-file", str(work / "infra.md")], top, 20)
            if run_p(["gh", "api", "-X", "POST", f"repos/{repo}/statuses/{sha}", "-f", "state=error", "-f", "context=review/agent", "-f", "description=评审没跑成"], top, 20).returncode != 0:
                return die("写 error 状态失败")
            print("REVIEW_STATUS_WRITTEN=error")
            return 1
        if mode_r != "reuse" and wt.is_dir() and run_p(["git", "status", "--porcelain"], str(wt), 10).stdout.strip():
            ag_verdict, reason = "FAIL", "评审 agent 修改了只读检出，评审作废。"
        verdict = ag_verdict
        (work / "body.check").write_text(pr_body + "\n", encoding="utf-8")
        if verdict == "PASS":
            head_args = ["--head-dir", str(wt)] if wt.is_dir() else []
            g_r = run_p(["bash", str(FLOW_DIR / "acceptance-gate.sh"), "check", "--repo", top, *head_args, "--cards", cards_s, "--core-rules", str(work / "core-paths.txt"), "--diff", str(work / "pr.full.diff"), "--files", str(work / "pr.files"), "--body", str(work / "body.check")], top, 20)
            if g_r.returncode != 0:
                verdict, reason = "FAIL", (g_r.stdout + g_r.stderr).replace("\n", " ").strip()
        state, desc = ("success", "独立评审通过") if verdict == "PASS" else ("failure", "独立评审未通过")
        if mode_r == "reuse":
            desc = f"{'owner 复核放行' if overridden else desc}（复用 {reuse_sha[:10]} 的结论）"
        else:
            clean_out = re.sub(r"<!--\s*ppass-review[^>]*-->", "", re.sub(r"(?m)^\s*VERDICT:\s*(?:PASS|FAIL)\s*$", "", (work / "agent.out").read_text(encoding="utf-8"))).replace("<!-- ppass-review", "<!- ppass-review")
            hdr = f"**独立评审：{'通过' if verdict == 'PASS' else '未通过'}**（头提交 `{sha[:10]}`，全量审阅）\n\n" + (f"{reason}\n\n" if reason else "") + (f"阻断 {block_n} 条：修掉后推新提交重评。\n\n" if block_n else "") + (f"建议 {sug_n} 条、风格 {sty_n} 条：不挡合入。\n\n" if sug_n + sty_n else "")
            (work / "comment.md").write_text(f"{hdr}{clean_out.strip()}\n\n<!-- ppass-review sha={sha} diff={diff_id} agent={ag_verdict} -->\n", encoding="utf-8")
            if run_p(["gh", "pr", "comment", pr, "-R", repo, "--body-file", str(c_file := work / "comment.md")], top, 20).returncode != 0:
                return die("贴评审评论失败")
        if run_p(["gh", "api", "-X", "POST", f"repos/{repo}/statuses/{sha}", "-f", f"state={state}", "-f", "context=review/agent", "-f", f"description={desc}"], top, 20).returncode != 0:
            return die("写评审状态失败")
        print(f"REVIEW_STATUS_WRITTEN={state}")
        if os.environ.get("PPASS_REVIEW_NO_MERGE") != "1":
            run_p(["gh", "pr", "merge", "--auto", "--squash", pr, "--repo", repo] if verdict == "PASS" else ["gh", "pr", "merge", pr, "-R", repo, "--disable-auto"], top, 20)
        return 0 if verdict == "PASS" else 1
    finally:
        if phase != "prepare":
            run_p(["git", "worktree", "remove", "--force", str(wt)], top, 15)
            if not phase:
                shutil.rmtree(work, ignore_errors=True)


def main(argv: list[str]) -> int:
    sub, cwd = (argv[1] if len(argv) >= 2 else ""), os.getcwd()
    if sub == "doctor":
        return cmd_doctor(cwd)
    if sub == "triage":
        return cmd_triage(argv[2:], cwd)
    if sub == "start":
        return cmd_start(argv[2:], cwd)
    if sub == "done":
        return cmd_done(argv[2:], cwd)
    if sub == "dispatch":
        return cmd_dispatch(argv[2:], cwd)
    if sub == "review":
        return cmd_review(argv[2:], cwd)
    if sub == "pick-gates":
        _, mr = repo_roots(cwd)
        for g in pick_gates(sys.stdin.read().splitlines(), mr):
            print(g)
        return 0
    if sub == "probe-slots":
        print(json.dumps(probe_slots("--unattended" in argv[2:]), ensure_ascii=False))
        return 0
    if sub == "stuck":
        return cmd_owner_stuck(argv[2:], cwd, is_worker=True)
    if sub == "owner-stuck":
        return cmd_owner_stuck(argv[2:], cwd, is_worker=False)
    return die("用法: flow.py <doctor|triage|start|done|dispatch|review|pick-gates|probe-slots|stuck|owner-stuck>", 2)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
