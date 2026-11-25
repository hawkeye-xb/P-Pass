#!/usr/bin/env python3
"""Regression tests: tools/test-bump-version.sh must clean up all disposable worktrees."""
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SUT = ROOT / "tools" / "test-bump-version.sh"
_GIT_VARS = (
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_PREFIX",
)


def _clean_env(tmpdir: str) -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if k not in _GIT_VARS}
    env["GIT_TEMPLATE_DIR"] = ""
    env["LC_ALL"] = "en_US.UTF-8"
    env["TMPDIR"] = tmpdir
    return env


def _worktree_paths(repo: Path, env: dict[str, str]) -> set[str]:
    out = subprocess.check_output(
        ["git", "-C", str(repo), "worktree", "list", "--porcelain"],
        env=env,
        text=True,
    )
    return {line[9:] for line in out.splitlines() if line.startswith("worktree ")}


class BumpVersionWorktreeCleanupTests(unittest.TestCase):
    def test_full_run_leaves_zero_worktrees_or_temp_dirs(self) -> None:
        tmp_base = tempfile.mkdtemp(prefix="ppass_bv_ut_")
        env = _clean_env(tmp_base)
        before_wts = _worktree_paths(ROOT, env)
        after_wts = set(before_wts)
        try:
            r = subprocess.run(
                ["bash", str(SUT)],
                cwd=str(ROOT),
                env=env,
                capture_output=True,
                text=True,
                timeout=120,
            )
            after_wts = _worktree_paths(ROOT, env)
            leaked_wts = sorted(after_wts - before_wts)
            leaked_entries = sorted(os.listdir(tmp_base))
        finally:
            for wt in sorted(after_wts - before_wts):
                subprocess.run(
                    ["git", "-C", str(ROOT), "worktree", "remove", "--force", wt],
                    env=env,
                    capture_output=True,
                )
            shutil.rmtree(tmp_base, ignore_errors=True)
            subprocess.run(
                ["git", "-C", str(ROOT), "worktree", "prune"],
                env=env,
                capture_output=True,
            )

        self.assertEqual(
            r.returncode,
            0,
            f"test-bump-version.sh failed (rc={r.returncode}):\n{r.stdout}\n{r.stderr}",
        )
        self.assertEqual(
            leaked_wts,
            [],
            f"test-bump-version.sh leaked {len(leaked_wts)} git worktree(s): {leaked_wts}",
        )
        self.assertEqual(
            leaked_entries,
            [],
            f"test-bump-version.sh left temporary entries in TMPDIR: {leaked_entries}",
        )

    def test_mid_run_failure_still_cleans_up_created_worktrees(self) -> None:
        outer = tempfile.mkdtemp(prefix="ppass_bv_abort_")
        try:
            mini_repo = Path(outer) / "repo"
            run_tmp = Path(outer) / "tmp"
            (mini_repo / "tools").mkdir(parents=True)
            (mini_repo / "apps" / "desktop" / "src-tauri").mkdir(parents=True)
            run_tmp.mkdir(parents=True)

            shutil.copy2(SUT, mini_repo / "tools" / "test-bump-version.sh")
            (mini_repo / "tools" / "test-bump-version.sh").chmod(0o755)
            (mini_repo / "apps" / "desktop" / "src-tauri" / "Cargo.toml").write_text(
                '[package]\nname = "p-pass-desktop"\nversion = "0.1.0"\n',
                encoding="utf-8",
            )
            # First invocation (drift check on 0.0.1) fails with expected drift message;
            # second invocation (positive sandbox) fails to force an early non-zero exit
            # after two temporary worktrees have already been created.
            (mini_repo / "tools" / "bump-version.sh").write_text(
                "#!/usr/bin/env bash\n"
                'ROOT="$(cd "$(dirname "$0")/.." && pwd)"\n'
                'if grep -q \'version = "0.0.1"\' "$ROOT/apps/desktop/src-tauri/Cargo.toml"; then\n'
                '  echo "error: apps/desktop/src-tauri/Cargo.toml version drift" >&2\n'
                "  exit 1\n"
                "fi\n"
                'echo "injected mid-run failure" >&2\n'
                "exit 1\n",
                encoding="utf-8",
            )
            (mini_repo / "tools" / "bump-version.sh").chmod(0o755)

            env = _clean_env(str(run_tmp))
            subprocess.run(["git", "init", "--template=", "-q", "-b", "main", str(mini_repo)], env=env, check=True)
            subprocess.run(["git", "-C", str(mini_repo), "config", "user.name", "Test"], env=env, check=True)
            subprocess.run(["git", "-C", str(mini_repo), "config", "user.email", "t@test.invalid"], env=env, check=True)
            subprocess.run(["git", "-C", str(mini_repo), "add", "-A"], env=env, check=True)
            subprocess.run(["git", "-C", str(mini_repo), "commit", "-q", "-m", "init"], env=env, check=True)

            before_wts = _worktree_paths(mini_repo, env)
            r = subprocess.run(
                ["bash", str(mini_repo / "tools" / "test-bump-version.sh")],
                cwd=str(mini_repo),
                env=env,
                capture_output=True,
                text=True,
                timeout=30,
            )
            after_wts = _worktree_paths(mini_repo, env)
            leaked_wts = sorted(after_wts - before_wts)
            leaked_entries = sorted(os.listdir(run_tmp))

            self.assertNotEqual(r.returncode, 0, "expected mid-run failure to exit non-zero")
            self.assertIn("injected mid-run failure", r.stdout + r.stderr)
            self.assertEqual(
                leaked_wts,
                [],
                f"aborted run leaked {len(leaked_wts)} git worktree(s): {leaked_wts}",
            )
            self.assertEqual(
                leaked_entries,
                [],
                f"aborted run left temporary entries in TMPDIR: {leaked_entries}",
            )
        finally:
            shutil.rmtree(outer, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
