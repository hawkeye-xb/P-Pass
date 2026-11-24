#!/usr/bin/env python3
"""P-Pass V3 流程引擎确定性自测（替代旧 3000 行慢速 bash 套娃测试，秒级跑完，每条含反证）。"""
from __future__ import annotations
import os, shutil, subprocess, sys, tempfile, time, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools" / "flow"))
import flow  # noqa: E402


class CleanFlowEngineTests(unittest.TestCase):
    def test_1_pick_gates_never_falls_back_to_full_just_ci(self) -> None:
        # 未知配置文件（.gitignore / assets/contracts/*.json）绝不回退全仓 just ci
        g_misc = flow.pick_gates([".gitignore", "assets/contracts/truth.json"], str(ROOT))
        self.assertNotIn("just ci", g_misc)
        self.assertIn("just arch-check", g_misc)
        self.assertIn("just fitness-check", g_misc)
        # Rust 单包精准挑选
        g_crate = flow.pick_gates(["crates/platform/src/lib.rs"], str(ROOT))
        self.assertNotIn("just ci", g_crate)
        self.assertIn("cargo nextest run -p platform", g_crate)
        # 纯文档秒级快检
        g_doc = flow.pick_gates(["docs/a.md"], str(ROOT))
        self.assertEqual(g_doc, ["just md-check"])

    def test_2_blocks_exam_files_and_source_string_fake_tests(self) -> None:
        tmp = tempfile.mkdtemp(prefix="v3_ft_")
        try:
            # 1) 拦截新增/留存的 exam_* 假考卷；而物理删除旧 exam_*（工作区已不存在）允许放行
            os.makedirs(os.path.join(tmp, "crates/daemon/tests/v3"), exist_ok=True)
            Path(tmp, "crates/daemon/tests/v3/exam_1927.py").write_text("x = 1\n", encoding="utf-8")
            ok1, msg1 = flow.verify_real_tests_and_counterproof(tmp, tmp, "HEAD", ["crates/daemon/tests/v3/exam_1927.py"], "fix")
            self.assertFalse(ok1)
            self.assertIn("FAKE_TEST_BLOCKED", msg1)
            os.unlink(os.path.join(tmp, "crates/daemon/tests/v3/exam_1927.py"))
            ok_del, _ = flow.verify_real_tests_and_counterproof(tmp, tmp, "HEAD", ["crates/daemon/tests/v3/exam_1927.py"], "feature")
            self.assertTrue(ok_del, "物理删除存量 exam_* 文件应当合法放行")
            # 2) 拦截读取业务源码字符串的假单测
            os.makedirs(os.path.join(tmp, "tests"), exist_ok=True)
            fake_t = Path(tmp) / "tests" / "fake_check.py"
            fake_t.write_text('s = (ROOT / "crates/platform/src/lib.rs").read_text()\nassert "fn foo" in s\n', encoding="utf-8")
            ok2, msg2 = flow.verify_real_tests_and_counterproof(tmp, tmp, "HEAD", ["tests/fake_check.py"], "fix")
            self.assertFalse(ok2)
            self.assertIn("FAKE_TEST_BLOCKED", msg2)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_3_real_baseline_counterproof_red_to_green_and_rejects_passing_baseline(self) -> None:
        tmp = tempfile.mkdtemp(prefix="v3_cp_repo_")
        try:
            subprocess.run(["git", "init", "--template=", "-q", "-b", "main", tmp], check=True)
            subprocess.run(["git", "-C", tmp, "config", "user.name", "t"], check=True)
            subprocess.run(["git", "-C", tmp, "config", "user.email", "t@t"], check=True)
            os.makedirs(os.path.join(tmp, "pkg"), exist_ok=True)
            os.makedirs(os.path.join(tmp, "tests"), exist_ok=True)
            Path(tmp, "pkg", "__init__.py").write_text("def add(a, b): return a - b\n", encoding="utf-8")
            subprocess.run(["git", "-C", tmp, "add", "-A"], check=True)
            subprocess.run(["git", "-C", tmp, "commit", "-q", "-m", "base"], check=True)
            base_sha = subprocess.run(["git", "-C", tmp, "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()

            wt = os.path.join(tmp, ".worktrees", "101-fix")
            subprocess.run(["git", "-C", tmp, "worktree", "add", "-q", "-b", "fix/101-add", wt, base_sha], check=True)
            os.makedirs(os.path.join(wt, "tests"), exist_ok=True)
            Path(wt, "pkg", "__init__.py").write_text("def add(a, b): return a + b\n", encoding="utf-8")
            Path(wt, "tests", "test_add.py").write_text(
                "import unittest, pkg\nclass T(unittest.TestCase):\n    def test_a(self): self.assertEqual(pkg.add(2, 3), 5)\n",
                encoding="utf-8",
            )
            old_cmd = os.environ.get("PPASS_COUNTERPROOF_CMD")
            os.environ["PPASS_COUNTERPROOF_CMD"] = f"{sys.executable} -m unittest discover -s tests"
            try:
                # 正例：基线红（2-3 != 5）、当前绿 → 通过
                ok, msg = flow.verify_real_tests_and_counterproof(wt, tmp, base_sha, ["pkg/__init__.py", "tests/test_add.py"], "fix")
                self.assertTrue(ok, msg)
                # 反证：若测试恒真（在基线也绿），必须判 COUNTERPROOF_FAIL
                Path(wt, "tests", "test_add.py").write_text(
                    "import unittest\nclass T(unittest.TestCase):\n    def test_a(self): self.assertEqual(1, 1)\n",
                    encoding="utf-8",
                )
                ok_bad, msg_bad = flow.verify_real_tests_and_counterproof(wt, tmp, base_sha, ["pkg/__init__.py", "tests/test_add.py"], "fix")
                self.assertFalse(ok_bad)
                self.assertIn("COUNTERPROOF_FAIL", msg_bad)
            finally:
                if old_cmd is None: os.environ.pop("PPASS_COUNTERPROOF_CMD", None)
                else: os.environ["PPASS_COUNTERPROOF_CMD"] = old_cmd
                subprocess.run(["git", "-C", tmp, "worktree", "remove", "--force", wt], capture_output=True)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_4_adaptive_slots_and_watchdog_kills_runaway_process_and_readonly_gh(self) -> None:
        old_rem = os.environ.get("PPASS_REMOTE_WORKER")
        os.environ["PPASS_REMOTE_WORKER"] = "none"
        try:
            day_slots = flow.probe_slots(unattended=False)
            night_slots = flow.probe_slots(unattended=True)
            self.assertEqual(day_slots[0]["slots"], 1, "白天本机必须硬限 1 个后台重编译槽保主会话秒回")
            self.assertEqual(night_slots[0]["slots"], 2, "夜间无人模式允许 2 个槽")
        finally:
            if old_rem is None: os.environ.pop("PPASS_REMOTE_WORKER", None)
            else: os.environ["PPASS_REMOTE_WORKER"] = old_rem

        dev_dir = tempfile.mkdtemp(prefix="v3_dev_")
        try:
            Path(dev_dir, "ios.state").write_text("SCREEN_LOCKED\n", encoding="utf-8")
            old_dev = os.environ.get("PPASS_V3_DEV_DIR")
            os.environ["PPASS_V3_DEV_DIR"] = dev_dir
            try:
                t0 = time.time()
                res = flow.run_watchdog_tasks([
                    {"id": "locked_ios", "device": "ios", "cmd": ["sleep", "10"], "cwd": str(ROOT), "timeout": 5},
                    {"id": "hung_job", "cmd": ["sleep", "30"], "cwd": str(ROOT), "timeout": 1},
                    {"id": "mut_gh", "cmd": ["gh", "issue", "edit", "1"], "cwd": str(ROOT), "timeout": 5},
                ], unattended=True)
                elapsed = time.time() - t0
                by_id = {x["id"]: x for x in res}
                self.assertEqual(by_id["locked_ios"]["status"], "SUSPENDED_ENV")
                self.assertEqual(by_id["hung_job"]["status"], "SUSPENDED_TIMEOUT")
                self.assertEqual(by_id["mut_gh"]["status"], "FAILED", "worker 调 gh issue edit 必须被只读垫片拒绝")
                self.assertLess(elapsed, 6.0, "看门狗必须秒级强杀超时子进程组，不能傻等 30 秒")
            finally:
                if old_dev is None: os.environ.pop("PPASS_V3_DEV_DIR", None)
                else: os.environ["PPASS_V3_DEV_DIR"] = old_dev
        finally:
            shutil.rmtree(dev_dir, ignore_errors=True)

    def test_5_doctor_auto_cleans_disk_below_threshold(self) -> None:
        tmp = tempfile.mkdtemp(prefix="v3_doc_")
        marker = os.path.join(tmp, "cleaned.ok")
        repo = os.path.join(tmp, "repo")
        os.makedirs(os.path.join(repo, ".github"), exist_ok=True)
        try:
            subprocess.run(["git", "init", "--template=", "-q", "-b", "main", repo], check=True)
            subprocess.run(["git", "-C", repo, "config", "user.name", "Flow Test"], check=True)
            subprocess.run(["git", "-C", repo, "config", "user.email", "flow@test.invalid"], check=True)
            Path(repo, ".github/allowed-identities.txt").write_text("Flow Test <flow@test.invalid>\n", encoding="utf-8")
            env = {
                "PPASS_DOCTOR_FAKE_FREE_GB": "12",
                "PPASS_DOCTOR_FAKE_AFTER_CLEAN_GB": "40",
                "PPASS_DOCTOR_CLEAN_CMD": f"touch '{marker}'",
            }
            r = subprocess.run(
                [sys.executable, "-B", "-I", str(ROOT / "tools/flow/flow.py"), "doctor"],
                cwd=repo,
                env={**os.environ, **env},
                capture_output=True,
                text=True,
                timeout=30,
            )
            self.assertEqual(r.returncode, 0, f"doctor exit={r.returncode}: {r.stdout} {r.stderr}")
            self.assertTrue(os.path.exists(marker), f"磁盘低于阈值必须自动触发清理：{r.stdout} {r.stderr}")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
