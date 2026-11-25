#!/usr/bin/env python3
from __future__ import annotations
import json, os, shutil, subprocess, sys, tempfile, time, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

def _gh_stub_main() -> None:
    state_f = Path(os.environ["FAKE_GH_STATE"])
    log_f = Path(os.environ["FAKE_GH_LOG"])
    args = sys.argv[1:]
    with log_f.open("a", encoding="utf-8") as fh:
        fh.write(" ".join(args) + "\n")
    st = json.loads(state_f.read_text(encoding="utf-8"))
    def save() -> None:
        state_f.write_text(json.dumps(st, ensure_ascii=False), encoding="utf-8")
    def opt(flag: str) -> str:
        for i, x in enumerate(args[:-1]):
            if x == flag:
                return args[i + 1]
        return ""
    def eval_jq(payload: object, expr: str) -> str:
        if not expr:
            return json.dumps(payload)
        wrapped = f"({expr}) | if . == null then empty else . end"
        r = subprocess.run(["jq", "-r", wrapped], input=json.dumps(payload), text=True, capture_output=True, check=True)
        return r.stdout
    if args[:1] == ["api"]:
        ep = args[1] if len(args) > 1 else ""
        jq_e = opt("--jq")
        if "/actions/runs?" in ep:
            payload = {"workflow_runs": [{"status": "completed", "conclusion": "success", "event": "push", "head_branch": "main", "name": "CI Docs"}]}
            sys.stdout.write(eval_jq(payload, jq_e))
        elif "/commits/" in ep and ep.endswith("/status"):
            sys.stdout.write(eval_jq({"state": "success", "total_count": 0}, jq_e))
        else:
            sys.stdout.write("{}")
        sys.exit(0)
    if args[:2] == ["run", "list"]:
        runs = [{"databaseId": 45431869915, "headBranch": "release-run/v0.12.1-test.4"}] if st["dispatched"] else []
        sys.stdout.write(eval_jq(runs, opt("--jq")))
        sys.exit(0)
    if args[:2] == ["workflow", "run"]:
        st["dispatched"] = True
        save()
        sys.exit(0)
    if args[:2] == ["run", "watch"]:
        seq = st["watch_seq"]
        idx = min(st["watch_idx"], len(seq) - 1)
        st["watch_idx"] += 1
        save()
        item = seq[idx]
        if item.get("sleep", 0) > 0:
            time.sleep(item["sleep"])
        if item.get("stderr"):
            sys.stderr.write(item["stderr"] + "\n")
        sys.exit(int(item.get("rc", 0)))
    if args[:2] == ["run", "view"]:
        if "--log-failed" in args:
            sys.stdout.write("build-android\tstep\tfailed line\n")
            sys.exit(0)
        seq = st["view_seq"]
        idx = min(st["view_idx"], len(seq) - 1)
        st["view_idx"] += 1
        save()
        item = seq[idx]
        if item.get("stderr"):
            sys.stderr.write(item["stderr"] + "\n")
        rc = int(item.get("rc", 0))
        if rc != 0:
            sys.exit(rc)
        payload = {"status": item.get("status"), "conclusion": item.get("conclusion")}
        sys.stdout.write(eval_jq(payload, opt("--jq")))
        sys.exit(0)
    if args[:2] == ["release", "download"]:
        sys.stdout.write(json.dumps({"version": "0.12.1-test.4"}) + "\n")
        sys.exit(0)
    if args[:2] == ["issue", "create"]:
        sys.stdout.write("https://example.invalid/issues/999\n")
        sys.exit(0)
    sys.stderr.write("unexpected gh call: " + " ".join(args) + "\n")
    sys.exit(2)

def _run_release_test_scenario(watch_seq: list[dict], view_seq: list[dict], timeout_sec: int = 20, retry_interval_sec: int = 0) -> tuple[subprocess.CompletedProcess[str], str, list[str]]:
    tmp = Path(tempfile.mkdtemp(prefix="v3_reltest_"))
    try:
        home, tpl, bin_dir, state_dir = tmp / "home", tmp / "tpl", tmp / "bin", tmp / "state"
        origin, repo = tmp / "origin.git", tmp / "repo"
        for d in (home, tpl, bin_dir, state_dir):
            d.mkdir(parents=True, exist_ok=True)
        state_file = state_dir / "stub_state.json"
        calls_log = state_dir / "gh_calls.log"
        state_file.write_text(json.dumps({"dispatched": False, "watch_idx": 0, "view_idx": 0, "watch_seq": watch_seq, "view_seq": view_seq}, ensure_ascii=False), encoding="utf-8")
        calls_log.write_text("", encoding="utf-8")
        fake_gh = bin_dir / "gh"
        fake_gh.write_text("#!/usr/bin/env python3\nimport os, runpy\nrunpy.run_path(os.environ[\"FAKE_GH_IMPL\"], run_name=\"__gh_stub__\")\n", encoding="utf-8")
        fake_gh.chmod(0o755)
        vcs_env = {**{k: v for k, v in os.environ.items() if not k.startswith('GIT_')}, "HOME": str(home), "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": str(tmp / "gitconfig"), "GIT_TEMPLATE_DIR": str(tpl)}
        subprocess.run(["git", "config", "--global", "user.name", "Flow Test"], env=vcs_env, check=True)
        subprocess.run(["git", "config", "--global", "user.email", "flow@example.invalid"], env=vcs_env, check=True)
        subprocess.run(["git", "config", "--global", "init.defaultBranch", "main"], env=vcs_env, check=True)
        subprocess.run(["git", "init", "--template=", "-q", "--bare", str(origin)], env=vcs_env, check=True)
        subprocess.run(["git", "init", "--template=", "-q", "-b", "main", str(repo)], env=vcs_env, check=True)
        subprocess.run(["git", "-C", str(repo), "remote", "add", "origin", str(origin)], env=vcs_env, check=True)
        for sub in ("tools/flow", "tools/release", ".github", "release"):
            (repo / sub).mkdir(parents=True, exist_ok=True)
        for f in (ROOT / "tools" / "flow").iterdir():
            if f.is_file():
                shutil.copy2(f, repo / "tools" / "flow" / f.name)
        shutil.copy2(ROOT / "tools" / "release" / "with-timeout.sh", repo / "tools" / "release" / "with-timeout.sh")
        plan_stub = repo / "tools" / "release" / "plan-builds.sh"
        plan_stub.write_text("#!/usr/bin/env bash\nprintf \"%s\\n\" android=build macos=skip windows=skip ios=skip\n", encoding="utf-8")
        plan_stub.chmod(0o755)
        (repo / ".github" / "allowed-identities.txt").write_text("Flow Test <flow@example.invalid>\n", encoding="utf-8")
        (repo / "release" / "versions.json").write_text(json.dumps({"desktop": "0.12.0", "android": "0.12.0", "ios": "0.12.0"}) + "\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(repo), "add", "-A"], env=vcs_env, check=True)
        subprocess.run(["git", "-C", str(repo), "commit", "-q", "-m", "init"], env=vcs_env, check=True)
        subprocess.run(["git", "-C", str(repo), "push", "-q", "origin", "HEAD:refs/heads/main"], env=vcs_env, check=True)
        head_sha = subprocess.run(["git", "-C", str(repo), "rev-parse", "HEAD"], env=vcs_env, capture_output=True, text=True, check=True).stdout.strip()
        subprocess.run(["git", "-C", str(repo), "push", "-q", "origin", f"{head_sha}:refs/tags/v0.12.1-test.3"], env=vcs_env, check=True)
        run_env = {**vcs_env, "PATH": f"{bin_dir}:{os.environ.get('PATH', '')}", "FAKE_GH_IMPL": str(Path(__file__).resolve()), "FAKE_GH_STATE": str(state_file), "FAKE_GH_LOG": str(calls_log), "PPASS_OWNER_REPO": "o/r", "PPASS_DOCTOR_MIN_FREE_GB": "0", "PPASS_OWNER_RUN_WAIT": "5", "PPASS_OWNER_MAIN_CI_WAIT": "0", "PPASS_OWNER_MAIN_CI_EMPTY_WAIT": "0", "PPASS_OWNER_RELEASE_TIMEOUT": str(timeout_sec), "PPASS_OWNER_WATCH_RETRY_INTERVAL": str(retry_interval_sec)}
        proc = subprocess.run(["bash", "tools/flow/owner-release-test.sh", "android"], cwd=str(repo), env=run_env, capture_output=True, text=True, timeout=30)
        heads = subprocess.run(["git", "--git-dir", str(origin), "for-each-ref", "--format=%(refname)", "refs/heads/"], env=vcs_env, capture_output=True, text=True, check=True).stdout
        calls = [ln for ln in calls_log.read_text(encoding="utf-8").splitlines() if ln.strip()]
        return proc, heads, calls
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

class OwnerReleaseTestWatchTests(unittest.TestCase):
    def test_1_transient_watch_and_view_network_blip_recovers_without_stuck(self) -> None:
        proc, heads, calls = _run_release_test_scenario(watch_seq=[{"rc": 1, "stderr": "HTTP 502: Bad Gateway"}, {"rc": 1, "stderr": "read tcp: connection reset by peer"}, {"rc": 0}], view_seq=[{"rc": 0, "status": "in_progress", "conclusion": None}, {"rc": 1, "stderr": "HTTP 502: Bad Gateway"}, {"rc": 0, "status": "completed", "conclusion": "success"}], timeout_sec=20, retry_interval_sec=0)
        combined = (proc.stdout or "") + "\n" + (proc.stderr or "")
        self.assertEqual(proc.returncode, 0, f"瞬时断网后远端仍在跑且最终成功，不应失败：{combined}")
        self.assertIn("RELEASE-TEST OK v0.12.1-test.4 android", proc.stdout)
        self.assertNotIn("结论 未出", combined)
        self.assertFalse(any(c.startswith("issue create ") for c in calls), f"不应乱开阻塞卡：{calls}")
        self.assertNotIn("refs/heads/release-run/v0.12.1-test.4", heads, "成功后应清理临时触发分支")
        watch_calls = [c for c in calls if c.startswith("run watch ")]
        self.assertGreaterEqual(len(watch_calls), 3, f"应在断网后重连继续 watch：{calls}")

    def test_2_real_completed_failure_keeps_branch_and_reports_stuck(self) -> None:
        proc, heads, calls = _run_release_test_scenario(watch_seq=[{"rc": 1, "stderr": "HTTP 502: Bad Gateway"}, {"rc": 1}], view_seq=[{"rc": 0, "status": "in_progress", "conclusion": None}, {"rc": 0, "status": "completed", "conclusion": "failure"}], timeout_sec=20, retry_interval_sec=0)
        combined = (proc.stdout or "") + "\n" + (proc.stderr or "")
        self.assertNotEqual(proc.returncode, 0, "远端真正 completed+failure 必须非零退出")
        self.assertIn("结论 failure", combined)
        self.assertTrue(any(c.startswith("issue create ") and "status:blocked" in c for c in calls), f"真失败必须调 die_stuck 开阻塞卡：{calls}")
        self.assertIn("refs/heads/release-run/v0.12.1-test.4", heads, "失败时必须保留 release-run/* 分支")

    def test_3_timeout_while_still_in_progress_keeps_branch_and_reports_stuck(self) -> None:
        t0 = time.monotonic()
        proc, heads, calls = _run_release_test_scenario(watch_seq=[{"rc": 0, "sleep": 8}], view_seq=[{"rc": 0, "status": "in_progress", "conclusion": None}], timeout_sec=2, retry_interval_sec=1)
        elapsed = time.monotonic() - t0
        self.assertNotEqual(proc.returncode, 0, "超过总超时仍未完成必须非零退出")
        self.assertLess(elapsed, 12.0, f"总超时控制失效：{elapsed:.1f}s")
        self.assertTrue(any(c.startswith("issue create ") and "status:blocked" in c for c in calls), f"超时未完成必须调 die_stuck 开阻塞卡：{calls}")
        self.assertIn("refs/heads/release-run/v0.12.1-test.4", heads, "超时未完成必须保留 release-run/* 分支")

    def test_4_repeated_network_blips_exhausting_timeout_stops_and_reports_stuck(self) -> None:
        t0 = time.monotonic()
        proc, heads, calls = _run_release_test_scenario(watch_seq=[{"rc": 1, "stderr": "HTTP 502: Bad Gateway"}], view_seq=[{"rc": 0, "status": "in_progress", "conclusion": None}], timeout_sec=2, retry_interval_sec=1)
        elapsed = time.monotonic() - t0
        combined = (proc.stdout or "") + "\n" + (proc.stderr or "")
        self.assertNotEqual(proc.returncode, 0, "反复闪断耗尽总超时仍未完成必须非零退出")
        self.assertLess(elapsed, 12.0, f"重连循环未受总超时约束：{elapsed:.1f}s")
        self.assertIn("等待 2s 仍未完成", combined)
        self.assertTrue(any(c.startswith("issue create ") and "status:blocked" in c for c in calls), f"超时未完成必须调 die_stuck 开阻塞卡：{calls}")
        self.assertIn("refs/heads/release-run/v0.12.1-test.4", heads, "超时未完成必须保留 release-run/* 分支")

if __name__ == "__gh_stub__":
    _gh_stub_main()
elif __name__ == "__main__":
    unittest.main(verbosity=2)
