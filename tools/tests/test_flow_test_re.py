#!/usr/bin/env python3
"""Regression tests (#2034): flow.py TEST_RE and pick_gates recognize root tools/test-*.{sh,py}."""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "flow"))
import flow  # noqa: E402


class FlowRootTestScriptTests(unittest.TestCase):
    def test_test_re_matches_test_dash_sh_and_py_with_counterexamples(self) -> None:
        # Positive: root tools/test-*.{sh,py} and nested tools/<sub/>test-*.sh
        for p in (
            "tools/test-main-red.sh",
            "tools/test-flow.py",
            "tools/test-a11y-contrast.py",
            "tools/ios/test-packages.sh",
            "test-root.sh",
        ):
            self.assertIsNotNone(flow.TEST_RE.search(p), f"TEST_RE should match {p}")

        # Negative counterexamples: non-test scripts / components must not be misclassified as tests
        for non_test in (
            "tools/ios/testflight-upload.sh",
            "tools/ci-paths.sh",
            "tools/a11y-contrast.py",
            "apps/desktop/src/SpeedTest.svelte",
        ):
            self.assertIsNone(flow.TEST_RE.search(non_test), f"TEST_RE must NOT match {non_test}")

    def test_pick_gates_selects_existing_root_test_sh_and_py_without_missing_files(self) -> None:
        tmp = tempfile.mkdtemp(prefix="v3_pg_2034_")
        try:
            os.makedirs(os.path.join(tmp, "tools"), exist_ok=True)
            Path(tmp, "tools", "test-demo.sh").write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
            Path(tmp, "tools", "test-demo.py").write_text("print('ok')\n", encoding="utf-8")

            g_sh = flow.pick_gates(["tools/test-demo.sh"], tmp)
            self.assertIn("bash tools/test-demo.sh", g_sh)
            self.assertIn("just arch-check", g_sh)
            self.assertIn("just fitness-check", g_sh)

            g_py = flow.pick_gates(["tools/test-demo.py"], tmp)
            self.assertIn("python3 -B -I tools/test-demo.py", g_py)
            self.assertIn("just arch-check", g_py)

            # Deleted / non-existent test file must not emit a broken execution command
            g_del = flow.pick_gates(["tools/test-deleted.sh", "tools/test-deleted.py"], tmp)
            self.assertNotIn("bash tools/test-deleted.sh", g_del)
            self.assertNotIn("python3 -B -I tools/test-deleted.py", g_del)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_counterproof_runs_root_tools_test_sh_and_test_py_red_to_green(self) -> None:
        tmp = tempfile.mkdtemp(prefix="v3_cp_2034_")
        try:
            subprocess.run(["git", "init", "--template=", "-q", "-b", "main", tmp], check=True)
            subprocess.run(["git", "-C", tmp, "config", "user.name", "t"], check=True)
            subprocess.run(["git", "-C", tmp, "config", "user.email", "t@t"], check=True)
            os.makedirs(os.path.join(tmp, "tools"), exist_ok=True)
            Path(tmp, "tools", "worker.sh").write_text("#!/usr/bin/env bash\necho broken\n", encoding="utf-8")
            Path(tmp, "tools", "calc.py").write_text("VAL = 0\n", encoding="utf-8")
            subprocess.run(["git", "-C", tmp, "add", "-A"], check=True)
            subprocess.run(["git", "-C", tmp, "commit", "-q", "-m", "base"], check=True)
            base_sha = subprocess.run(
                ["git", "-C", tmp, "rev-parse", "HEAD"], capture_output=True, text=True, check=True
            ).stdout.strip()

            wt = os.path.join(tmp, ".worktrees", "2034-fix")
            subprocess.run(["git", "-C", tmp, "worktree", "add", "-q", "-b", "fix/2034-t", wt, base_sha], check=True)
            try:
                # Case A: fix branch touching tools/worker.sh + tools/test-worker.sh
                Path(wt, "tools", "worker.sh").write_text("#!/usr/bin/env bash\necho fixed\n", encoding="utf-8")
                Path(wt, "tools", "test-worker.sh").write_text(
                    "#!/usr/bin/env bash\n"
                    'out="$(bash tools/worker.sh)"\n'
                    '[ "$out" = "fixed" ]\n',
                    encoding="utf-8",
                )
                ok_sh, msg_sh = flow.verify_real_tests_and_counterproof(
                    wt, tmp, base_sha, ["tools/worker.sh", "tools/test-worker.sh"], "fix"
                )
                self.assertTrue(ok_sh, f"expected counterproof_ok for tools/test-*.sh, got: {msg_sh}")
                self.assertEqual(msg_sh, "counterproof_ok")

                # Counterexample A: trivial test passing on unfixed baseline must be rejected
                Path(wt, "tools", "test-worker.sh").write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
                ok_sh_bad, msg_sh_bad = flow.verify_real_tests_and_counterproof(
                    wt, tmp, base_sha, ["tools/worker.sh", "tools/test-worker.sh"], "fix"
                )
                self.assertFalse(ok_sh_bad)
                self.assertIn("COUNTERPROOF_FAIL", msg_sh_bad)

                # Case B: fix branch touching tools/calc.py + tools/test-calc.py
                Path(wt, "tools", "calc.py").write_text("VAL = 42\n", encoding="utf-8")
                Path(wt, "tools", "test-calc.py").write_text(
                    "import sys\n"
                    "sys.path.insert(0, 'tools')\n"
                    "import calc\n"
                    "assert calc.VAL == 42\n",
                    encoding="utf-8",
                )
                ok_py, msg_py = flow.verify_real_tests_and_counterproof(
                    wt, tmp, base_sha, ["tools/calc.py", "tools/test-calc.py"], "fix"
                )
                self.assertTrue(ok_py, f"expected counterproof_ok for tools/test-*.py, got: {msg_py}")
                self.assertEqual(msg_py, "counterproof_ok")

                # Counterexample C: fix branch touching only tools/worker.sh without any test file
                ok_none, msg_none = flow.verify_real_tests_and_counterproof(
                    wt, tmp, base_sha, ["tools/worker.sh"], "fix"
                )
                self.assertFalse(ok_none)
                self.assertIn("COUNTERPROOF_MISSING_TEST", msg_none)
            finally:
                subprocess.run(["git", "-C", tmp, "worktree", "remove", "--force", wt], capture_output=True)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
