#!/usr/bin/env python3
"""P-Pass V3 协作工作流门禁与队列核心（`tools/flow/v3_harness.py`，单核 <= 400 行）：四类门禁分流 + 基线核心黑名单 + SHA256 封条 + 无人队列 + 串行变基重验。"""
from __future__ import annotations
from concurrent.futures import ThreadPoolExecutor
import hashlib, json, os, re, shutil, subprocess, sys, tempfile, threading, time
from pathlib import Path
from typing import Callable

WorkerFn = Callable[[str, str, str, int], tuple[int, str, float]]
ReviewFn = Callable[[dict, str], tuple[bool, str]]
GIT_LOCK = threading.Lock()
SEAL_BLOCK_RE = re.compile(r"```v3-seal\s*\n(.*?)```", re.S)
_GIT_LOC_VARS = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR", "GIT_PREFIX", "GIT_NAMESPACE")


def sha256_file(path: str) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest() if os.path.isfile(path) else ""


def has_issue_seal(issue_body: str) -> bool:
    return SEAL_BLOCK_RE.search(issue_body or "") is not None


def parse_issue_seal(issue_body: str) -> dict:
    m = SEAL_BLOCK_RE.search(issue_body or "")
    if not m:
        raise ValueError("missing ```v3-seal block in issue body")
    data = json.loads(m.group(1).strip())
    if data.get("mode") not in ("fix", "speculate_then_fix", "feature", "verify"):
        raise ValueError(f"invalid v3-seal mode: {data.get('mode')}")
    return data


def run_cmd(cmd: list[str], cwd: str, timeout: int = 120, extra_path: str | None = None) -> subprocess.CompletedProcess:
    env = {k: v for k, v in os.environ.items() if k not in _GIT_LOC_VARS}
    env.update({"GIT_TEMPLATE_DIR": "", "LC_ALL": "en_US.UTF-8"})
    if extra_path:
        env["PATH"] = f"{extra_path}:{env.get('PATH', '')}"
    try:
        return subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode(errors="replace") if isinstance(e.stdout, bytes) else (e.stdout or "")
        err = e.stderr.decode(errors="replace") if isinstance(e.stderr, bytes) else (e.stderr or "")
        return subprocess.CompletedProcess(cmd, 124, out, f"{err}\nCOMMAND_TIMEOUT after {timeout}s")


def git_head(repo: str) -> str:
    return run_cmd(["git", "rev-parse", "HEAD"], cwd=repo).stdout.strip()


def check_device_ready(dev_dir: str, device_name: str | None, unattended: bool = True) -> tuple[bool, str]:
    if not device_name:
        return True, "no_device_needed"
    state_file = os.path.join(dev_dir, f"{device_name}.state")
    state = Path(state_file).read_text(encoding="utf-8").strip() if os.path.exists(state_file) else "OFFLINE"
    if state != "UNLOCKED":
        mode_tag = "unattended mode skips human unlock" if unattended else "device requires human unlock"
        return False, f"device {device_name} unavailable (state={state}); {mode_tag}"
    lock_file = os.path.join(dev_dir, f"{device_name}.lock")
    if os.path.exists("/usr/bin/lockf") and subprocess.run(["/usr/bin/lockf", "-k", "-t", "0", lock_file, "true"], capture_output=True).returncode != 0:
        return False, f"device {device_name} lock busy"
    return True, "ok"


def changed_files_since(wt_dir: str, base_sha: str) -> list[str]:
    r1 = run_cmd(["git", "-c", "core.quotepath=false", "diff", "--no-renames", "--name-only", base_sha], cwd=wt_dir)
    r2 = run_cmd(["git", "-c", "core.quotepath=false", "ls-files", "--others", "--exclude-standard"], cwd=wt_dir)
    if r1.returncode != 0 or r2.returncode != 0:
        raise RuntimeError(f"git diff/ls-files failed (rc={r1.returncode}/{r2.returncode})")
    return sorted({f.strip() for f in (r1.stdout.splitlines() + r2.stdout.splitlines()) if f.strip()})


def _glob_match(rel_path: str, pat: str) -> bool:
    pat = pat.strip()
    while pat.startswith("./"):
        pat = pat[2:]
    if not pat:
        return False
    rx = "^" + re.escape(pat).replace(r"\*\*/", "(?:.*/)?").replace(r"\*\*", ".*").replace(r"\*", "[^/]*").replace(r"\?", "[^/]") + "$"
    return re.match(rx, rel_path) is not None


def core_rules_from_git(repo: str, sha: str) -> tuple[list[str], list[str], list[str]]:
    plus, zones, minus = [], [], []
    for candidate in (".github/core-paths.txt", ".core-paths.txt"):
        r = run_cmd(["git", "show", f"{sha}:{candidate}"], cwd=repo)
        if r.returncode == 124:
            return ["**"], [], []
        if r.returncode == 0 and r.stdout.strip():
            plus.append(candidate)
            for raw in r.stdout.splitlines():
                ln = raw.strip()
                if not ln or ln.startswith("#"):
                    continue
                if ln.startswith("+ "):
                    plus.append(ln[2:].strip())
                elif ln.startswith("zone "):
                    zones.append(ln[5:].strip())
                elif ln.startswith("- "):
                    minus.append(ln[2:].strip())
                else:
                    plus.append(ln)
            return plus, zones, minus
    return ["**"], [], []


def is_core_path(rel_path: str, rules: tuple[list[str], list[str], list[str]]) -> bool:
    plus, zones, minus = rules
    return any(_glob_match(rel_path, p) for p in plus) or (
        any(_glob_match(rel_path, z) for z in zones) and not any(_glob_match(rel_path, m) for m in minus)
    )


def _default_cmds(wt_dir: str, exam_rel: str, task: dict) -> tuple[list[str], list[str], list[str]]:
    exam_cmd = task.get("exam_cmd") or [sys.executable, "-m", "unittest", exam_rel]
    suite_cmd = task.get("suite_cmd") or ([sys.executable, "-m", "unittest", "discover", "-s", "tests"] if os.path.isdir(os.path.join(wt_dir, "tests")) else exam_cmd)
    fit_cmd = task["fitness_cmd"] if task.get("fitness_cmd") is not None else (
        [sys.executable, "tools/fitness_check.py"] if os.path.isfile(os.path.join(wt_dir, "tools/fitness_check.py"))
        else (["bash", "-c", "python3 tools/check-disk-growth.py && python3 tools/check-egress.py && python3 tools/check-autostart.py"] if os.path.isfile(os.path.join(wt_dir, "tools/check-disk-growth.py")) else [sys.executable, "-c", "pass"])
    )
    return exam_cmd, suite_cmd, fit_cmd


def _is_compile_or_syntax_error(out_text: str) -> bool:
    return any(m in out_text for m in ("SyntaxError", "IndentationError", "ImportError", "ModuleNotFoundError", "error[E", "could not compile"))


def verify_gate(wt_dir: str, main_repo: str, base_sha: str, task: dict, locked_sha: str, review_fn: ReviewFn | None = None) -> tuple[bool, str]:
    mode, exam_rel = task["mode"], task["exam_rel"]
    exam_abs = os.path.join(wt_dir, exam_rel)
    if sha256_file(exam_abs) != locked_sha:
        return False, f"TAMPER_BLOCKED: locked test {exam_rel} SHA256 mismatch"
    exam_cmd, suite_cmd, fitness_cmd = _default_cmds(wt_dir, exam_rel, task)
    try:
        changed = [f for f in changed_files_since(wt_dir, base_sha) if f != exam_rel]
    except Exception as e:
        return False, f"GIT_STATE_ERROR: {e}"

    if mode == "verify":
        illegal = [f for f in changed if f != "verdict.json"]
        if illegal:
            return False, f"VERIFY_CARD_MUTATED_CODE: verify card must not edit repo files: {illegal}"
        vp = os.path.join(wt_dir, "verdict.json")
        if not os.path.isfile(vp):
            return False, "VERIFY_MISSING_VERDICT: verdict.json not produced"
        try:
            vdata = json.loads(Path(vp).read_text(encoding="utf-8"))
        except Exception as e:
            return False, f"VERIFY_BAD_JSON: {e}"
        if not isinstance(vdata, dict):
            return False, "VERIFY_BAD_JSON: verdict.json must be an object"
        cp = run_cmd(exam_cmd, cwd=wt_dir, timeout=60)
        combined = (cp.stdout or "") + "\n" + (cp.stderr or "")
        actual = "PASS" if cp.returncode == 0 else ("TIMEOUT" if cp.returncode == 124 else ("INVALID" if _is_compile_or_syntax_error(combined) else "FAIL"))
        if actual in ("TIMEOUT", "INVALID") or vdata.get("verdict") != actual or len(str(vdata.get("root_cause", "")).strip()) < 8:
            return False, f"VERIFY_MISMATCH: reported={vdata.get('verdict')} vs actual={actual}"
        return True, f"VERIFIED_REPORTED (verdict={actual}, root_cause={str(vdata['root_cause'])[:80]})"

    for fg in (".github/core-paths.txt", ".core-paths.txt", "tools/fitness_check.py", "tools/flow/v3_harness.py"):
        if fg in changed and not task.get("gate_self_upgrade", False):
            return False, f"TAMPER_BLOCKED: immutable gate file {fg} was modified"
    rules = core_rules_from_git(main_repo, base_sha)
    if not task.get("core_approved", False):
        hits = [f for f in changed if is_core_path(f, rules)]
        if hits:
            return False, f"CORE_PATH_BLOCKED: {hits} protected by core-paths (core_approved=false)"

    if mode in ("fix", "speculate_then_fix"):
        base_wt = tempfile.mkdtemp(prefix="v3_base_")
        try:
            with GIT_LOCK:
                add_r = run_cmd(["git", "worktree", "add", "--detach", base_wt, base_sha], cwd=main_repo)
            if add_r.returncode != 0:
                return False, f"COUNTERPROOF_WORKTREE_ERROR: {add_r.stderr.strip()[-160:]}"
            dst_exam = os.path.join(base_wt, exam_rel)
            os.makedirs(os.path.dirname(dst_exam), exist_ok=True)
            shutil.copy2(exam_abs, dst_exam)
            cp = run_cmd(exam_cmd, cwd=base_wt, timeout=90)
            combined = (cp.stdout or "") + "\n" + (cp.stderr or "")
            if cp.returncode == 0:
                return False, "COUNTERPROOF_FAIL: test passed on unpatched baseline"
            if cp.returncode == 124 or _is_compile_or_syntax_error(combined):
                return False, f"COUNTERPROOF_INVALID: baseline failed on timeout/syntax/compile (rc={cp.returncode}): {combined[-180:]}"
        finally:
            with GIT_LOCK:
                run_cmd(["git", "worktree", "remove", "--force", base_wt], cwd=main_repo)
            shutil.rmtree(base_wt, ignore_errors=True)

    ut = run_cmd(suite_cmd, cwd=wt_dir, timeout=120)
    if ut.returncode != 0:
        return False, f"TESTS_RED: {(ut.stdout + ut.stderr)[-240:]}"
    ft = run_cmd(fitness_cmd, cwd=wt_dir, timeout=60)
    if ft.returncode != 0:
        return False, f"FITNESS_RED: {(ft.stderr or ft.stdout).strip()[-240:]}"

    if task.get("require_review", mode == "feature") and not task.get("defer_review_to_pr", False):
        if review_fn is None:
            return False, "REVIEW_MISSING: review required by task/mode=feature, but review_fn is None"
        diff_scope = task.get("review_paths") or ["."]
        run_cmd(["git", "add", "-N", *diff_scope], cwd=wt_dir)
        diff_txt = run_cmd(["git", "diff", base_sha, "--", *diff_scope], cwd=wt_dir).stdout
        rev_ok, rev_msg = review_fn(task, diff_txt)
        if not rev_ok:
            return False, f"REVIEW_BLOCKED: {rev_msg}"
    return True, f"GATE_PASS (mode={mode}, hash_locked + green + fitness_ok)"


def speculate_repro(task: dict, main_repo: str, worker_fn: WorkerFn, timeout_sec: int) -> tuple[str | None, str]:
    spec_wt = tempfile.mkdtemp(prefix="v3_spec_")
    try:
        with GIT_LOCK:
            run_cmd(["git", "worktree", "add", "--detach", spec_wt, "HEAD"], cwd=main_repo)
        exam_rel = task["exam_rel"]
        exam_cmd, _, _ = _default_cmds(spec_wt, exam_rel, task)
        prompt = f"缺陷复现测试编写（禁止修改业务源码）。现象：{task['goal']}\n只新建 `{exam_rel}` 并在当前基线运行期变红。"
        worker_fn(f"{task['id']}_spec", prompt, spec_wt, timeout_sec)
        exam_abs = os.path.join(spec_wt, exam_rel)
        if not os.path.isfile(exam_abs):
            return None, "speculate produced no test file"
        cp = run_cmd(exam_cmd, cwd=spec_wt, timeout=60)
        combined = (cp.stdout or "") + "\n" + (cp.stderr or "")
        if cp.returncode in (0, 124) or _is_compile_or_syntax_error(combined):
            return None, f"speculate test did not fail at runtime (rc={cp.returncode})"
        fd, locked_copy = tempfile.mkstemp(prefix=f"v3_locked_{task['id']}_", suffix=os.path.splitext(exam_rel)[1])
        os.close(fd)
        shutil.copy2(exam_abs, locked_copy)
        return locked_copy, sha256_file(locked_copy)
    finally:
        with GIT_LOCK:
            run_cmd(["git", "worktree", "remove", "--force", spec_wt], cwd=main_repo)
        shutil.rmtree(spec_wt, ignore_errors=True)


def _restore_protected_files(wt: str, base_sha: str, rules: tuple[list[str], list[str], list[str]], core_approved: bool, mode: str) -> None:
    for f in changed_files_since(wt, base_sha):
        if (mode == "verify" and f != "verdict.json") or (not core_approved and is_core_path(f, rules)) or f in (".github/core-paths.txt", ".core-paths.txt", "tools/fitness_check.py"):
            if run_cmd(["git", "cat-file", "-e", f"{base_sha}:{f}"], cwd=wt).returncode == 0:
                run_cmd(["git", "checkout", base_sha, "--", f], cwd=wt)
            elif os.path.exists(os.path.join(wt, f)):
                os.remove(os.path.join(wt, f))


def develop_in_worktree(
    task: dict, main_repo: str, wt: str, base_sha: str, worker_fn: WorkerFn, review_fn: ReviewFn | None,
    max_attempts: int, timeout_sec: int, initial_reason: str = "", id_prefix: str = "",
) -> tuple[bool, str, int]:
    tid, mode, exam_rel = task["id"], task["mode"], task["exam_rel"]
    exam_src, locked_sha = task["exam_src"], task["exam_sha256"]
    exam_abs = os.path.join(wt, exam_rel)
    os.makedirs(os.path.dirname(exam_abs), exist_ok=True)
    rules = core_rules_from_git(main_repo, base_sha)
    last_reason, used = initial_reason, 0
    for attempt in range(1, max_attempts + 1):
        used = attempt
        _restore_protected_files(wt, base_sha, rules, bool(task.get("core_approved", False)), mode)
        shutil.copy2(exam_src, exam_abs)
        fb = f"\n【上次门禁打回原因】：{last_reason}\n请按打回原因修正（严禁修改 `{exam_rel}` 或未授权核心文件）。" if last_reason else ""
        prompt = f"验证卡 {tid}：{task['title']}\n{task['goal']}{fb}" if mode == "verify" else f"任务 {tid}（mode={mode}, core_approved={task.get('core_approved', False)}）：{task['title']}\n目标：{task['goal']}\n只读锁定验收测试：`{exam_rel}`（严禁修改）。{fb}"
        rc, agent_log, _ = worker_fn(f"{id_prefix}{tid}#{attempt}", prompt, wt, timeout_sec)
        if rc == 124:
            return False, agent_log, used
        ok, msg = verify_gate(wt, main_repo, base_sha, task, locked_sha, review_fn)
        if ok:
            return True, msg, used
        last_reason = msg
    return False, last_reason, used


def _squash_merge(main_repo: str, tid: str, title: str) -> tuple[bool, str]:
    st = run_cmd(["git", "status", "--porcelain", "--untracked-files=no"], cwd=main_repo)
    if st.returncode != 0 or st.stdout.strip():
        return False, "merge aborted: main_repo has uncommitted tracked changes"
    m = run_cmd(["git", "merge", "--squash", f"goal/{tid}"], cwd=main_repo)
    if m.returncode == 0:
        c = run_cmd(["git", "commit", "--no-verify", "-m", f"feat/fix({tid}): {title}"], cwd=main_repo)
        if c.returncode == 0:
            return True, ""
        m = c
    run_cmd(["git", "reset", "--merge"], cwd=main_repo)
    return False, f"merge failed: {(m.stderr or m.stdout).strip()[:160]}"


def run_v3_queue(
    tasks: list[dict], main_repo: str, dev_dir: str, worker_fn: WorkerFn, review_fn: ReviewFn | None = None,
    max_attempts: int = 2, timeout_sec: int = 110, unattended: bool = True,
) -> list[dict]:
    wt_root = os.path.join(main_repo, ".worktrees")
    os.makedirs(wt_root, exist_ok=True)
    digest: list[dict] = []
    spec_temps: list[str] = []
    idx = 0
    try:
        while idx < len(tasks):
            grp = tasks[idx].get("parallel_group")
            batch = [tasks[idx]]
            idx += 1
            while grp and idx < len(tasks) and tasks[idx].get("parallel_group") == grp:
                batch.append(tasks[idx])
                idx += 1
            start_sha = git_head(main_repo)
            active = []
            for t in batch:
                tid = t["id"]
                ok_dev, dev_msg = check_device_ready(dev_dir, t.get("device"), unattended=unattended)
                if not ok_dev:
                    digest.append({"id": tid, "status": "SUSPENDED_ENV", "attempts": 0, "sec": 0.0, "reason": dev_msg})
                    continue
                tc = dict(t)
                if tc["mode"] == "speculate_then_fix" and not tc.get("exam_sha256"):
                    t0 = time.time()
                    esrc, sha_or_err = speculate_repro(tc, main_repo, worker_fn, timeout_sec)
                    if not esrc:
                        digest.append({"id": tid, "status": "UNREPRODUCED_SKIPPED", "attempts": 1, "sec": round(time.time() - t0, 2), "reason": sha_or_err})
                        continue
                    spec_temps.append(esrc)
                    tc["exam_src"], tc["exam_sha256"] = esrc, sha_or_err
                wt = os.path.join(wt_root, tid)
                with GIT_LOCK:
                    run_cmd(["git", "worktree", "remove", "--force", wt], cwd=main_repo)
                    if run_cmd(["git", "rev-parse", "-q", "--verify", f"refs/heads/goal/{tid}"], cwd=main_repo).returncode == 0:
                        digest.append({"id": tid, "status": "SUSPENDED_BRANCH_EXISTS", "attempts": 0, "sec": 0.0, "reason": f"preserved branch goal/{tid} already exists"})
                        continue
                    run_cmd(["git", "worktree", "add", "-b", f"goal/{tid}", wt, start_sha], cwd=main_repo)
                active.append((tc, wt, time.time()))

            def _exec_one(item):
                tc, wt, t0 = item
                ok, msg, used = develop_in_worktree(tc, main_repo, wt, start_sha, worker_fn, review_fn, max_attempts, timeout_sec)
                return tc, wt, ok, msg, used, round(time.time() - t0, 2)

            results = list(ThreadPoolExecutor(max_workers=len(active)).map(_exec_one, active)) if active else []
            for tc, wt, ok, msg, used, elapsed in results:
                tid, mode, keep_branch = tc["id"], tc["mode"], False
                try:
                    if not ok:
                        final_st, final_msg = "SUSPENDED_CIRCUIT_BREAK", msg
                    elif mode == "verify":
                        final_st, final_msg = "VERIFIED_REPORTED", msg
                    else:
                        run_cmd(["git", "add", "-A"], cwd=wt)
                        run_cmd(["git", "commit", "--no-verify", "-m", f"work({tid})"], cwd=wt)
                        cur_main = git_head(main_repo)
                        if cur_main != start_sha:
                            rb = run_cmd(["git", "rebase", "main"], cwd=wt)
                            if rb.returncode != 0:
                                run_cmd(["git", "rebase", "--abort"], cwd=wt)
                                final_st, final_msg = "SUSPENDED_CONFLICT", f"auto-rebase conflict onto {cur_main[:7]}; safely aborted"
                            else:
                                re_ok, re_msg = verify_gate(wt, main_repo, cur_main, tc, tc["exam_sha256"], review_fn)
                                if not re_ok:
                                    re_ok, re_msg, extra = develop_in_worktree(tc, main_repo, wt, cur_main, worker_fn, review_fn, 1, timeout_sec, initial_reason=f"合并最新 main 后出现语义冲突：{re_msg}", id_prefix="rebase_")
                                    used += extra
                                    if re_ok:
                                        run_cmd(["git", "add", "-A"], cwd=wt)
                                        run_cmd(["git", "commit", "--no-verify", "-m", f"rebased-fix({tid})"], cwd=wt)
                                if re_ok:
                                    m_ok, m_err = _squash_merge(main_repo, tid, tc["title"])
                                    final_st, final_msg, keep_branch = (("MERGED_AFTER_REBASE", re_msg, False) if m_ok else ("SUSPENDED_MERGE_FAILED", m_err, True))
                                else:
                                    final_st, final_msg = "SUSPENDED_SEMANTIC_CONFLICT", re_msg
                        else:
                            m_ok, m_err = _squash_merge(main_repo, tid, tc["title"])
                            final_st, final_msg, keep_branch = (("MERGED", msg, False) if m_ok else ("SUSPENDED_MERGE_FAILED", m_err, True))
                finally:
                    with GIT_LOCK:
                        run_cmd(["git", "worktree", "remove", "--force", wt], cwd=main_repo)
                        if not keep_branch:
                            run_cmd(["git", "branch", "-D", f"goal/{tid}"], cwd=main_repo)
                digest.append({"id": tid, "status": final_st, "attempts": used, "sec": elapsed, "reason": final_msg})
    finally:
        for sp in spec_temps:
            os.path.exists(sp) and os.remove(sp)
        if os.path.exists(wt_root) and not os.listdir(wt_root):
            os.rmdir(wt_root)
    return digest


def main_cli(argv: list[str]) -> int:
    if len(argv) >= 2 and argv[1] == "parse-seal":
        print(json.dumps(parse_issue_seal(sys.stdin.read()), ensure_ascii=False))
        return 0
    if len(argv) >= 5 and argv[1] == "check-card":
        wt_dir, main_repo, base_sha = argv[2], argv[3], argv[4]
        body = sys.stdin.read()
        if not has_issue_seal(body):
            return 0
        seal = parse_issue_seal(body)
        seal["core_approved"] = bool(seal.get("core_approved", False) or ("--core-approved" in argv[5:]))
        seal["defer_review_to_pr"] = True
        ok, msg = verify_gate(wt_dir, main_repo, base_sha, seal, seal.get("exam_sha256", ""), None)
        print(msg, file=(sys.stdout if ok else sys.stderr))
        return 0 if ok else 1
    print("usage: v3_harness.py [parse-seal | check-card <wt> <main_repo> <base_sha> [--core-approved]] < issue.md", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main_cli(sys.argv))
