#!/usr/bin/env python3
"""P-Pass V3 流程引擎确定性自测（秒级跑完，每条均配正反双侧判据）。"""
from __future__ import annotations
import json, os, shutil, subprocess, sys, tempfile, time, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools" / "flow"))
sys.path.insert(0, str(ROOT / "tools" / "tests"))
import flow  # noqa: E402
from test_bump_version_cleanup import BumpVersionWorktreeCleanupTests  # noqa: E402,F401
from test_flow_test_re import FlowRootTestScriptTests  # noqa: E402,F401
from test_owner_release_test import OwnerReleaseTestWatchTests  # noqa: E402,F401


class CleanFlowEngineTests(unittest.TestCase):
    def test_1_pick_gates_never_falls_back_to_full_just_ci(self) -> None:
        g_misc = flow.pick_gates([".gitignore", "assets/contracts/truth.json"], str(ROOT))
        self.assertNotIn("just ci", g_misc)
        self.assertIn("just arch-check", g_misc)
        self.assertIn("just fitness-check", g_misc)
        g_crate = flow.pick_gates(["crates/platform/src/lib.rs"], str(ROOT))
        self.assertNotIn("just ci", g_crate)
        self.assertIn("cargo nextest run -p platform", g_crate)
        g_tool_sh = flow.pick_gates(["tools/test-bump-version.sh"], str(ROOT))
        self.assertIn("bash tools/test-bump-version.sh", g_tool_sh)
        g_tool_py = flow.pick_gates(["tools/tests/test_bump_version_cleanup.py"], str(ROOT))
        self.assertIn("python3 -B -I tools/tests/test_bump_version_cleanup.py", g_tool_py)
        g_doc = flow.pick_gates(["docs/a.md"], str(ROOT))
        self.assertEqual(g_doc, ["just md-check"])
        g_just = flow.pick_gates(["justfile"], str(ROOT))
        self.assertEqual(g_just, ["just ci-docs"])
        g_split_just = flow.pick_gates(["tools/just/checks.just"], str(ROOT))
        self.assertEqual(g_split_just, ["just ci-docs"])
        g_desk_i18n = flow.pick_gates(["apps/desktop/src/i18n/en.json"], str(ROOT))
        self.assertIn("pnpm -C apps/desktop test", g_desk_i18n)
        self.assertIn("cargo nextest run -p diag", g_desk_i18n)
        self.assertIn("cargo nextest run --manifest-path apps/desktop/src-tauri/Cargo.toml -p p-pass-desktop", g_desk_i18n)
        g_rules = flow.pick_gates(["docs/desktop/business-rules.zh-CN.md"], str(ROOT))
        self.assertIn("cargo nextest run -p daemon", g_rules)
        self.assertIn("cargo nextest run --manifest-path apps/desktop/src-tauri/Cargo.toml -p p-pass-desktop", g_rules)
        self.assertIn("pnpm -C apps/desktop test", g_rules)

    def test_2_blocks_exam_files_and_source_string_fake_tests(self) -> None:
        tmp = tempfile.mkdtemp(prefix="v3_ft_")
        try:
            os.makedirs(os.path.join(tmp, "crates/daemon/tests/v3"), exist_ok=True)
            Path(tmp, "crates/daemon/tests/v3/exam_1927.py").write_text("x = 1\n", encoding="utf-8")
            ok1, msg1 = flow.verify_real_tests_and_counterproof(tmp, tmp, "HEAD", ["crates/daemon/tests/v3/exam_1927.py"], "fix")
            self.assertFalse(ok1)
            self.assertIn("FAKE_TEST_BLOCKED", msg1)
            os.unlink(os.path.join(tmp, "crates/daemon/tests/v3/exam_1927.py"))
            ok_del, _ = flow.verify_real_tests_and_counterproof(tmp, tmp, "HEAD", ["crates/daemon/tests/v3/exam_1927.py"], "feature")
            self.assertTrue(ok_del, "物理删除存量 exam_* 文件应当合法放行")
            os.makedirs(os.path.join(tmp, "tests"), exist_ok=True)
            fake_t = Path(tmp) / "tests" / "fake_check.py"
            fake_ext = "rs"
            fake_t.write_text(f's = (ROOT / "crates/platform/src/lib.{fake_ext}").read_text()\nassert "fn foo" in s\n', encoding="utf-8")
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
                ok, msg = flow.verify_real_tests_and_counterproof(wt, tmp, base_sha, ["pkg/__init__.py", "tests/test_add.py"], "fix")
                self.assertTrue(ok, msg)
                Path(wt, "tests", "test_add.py").write_text(
                    "import unittest\nclass T(unittest.TestCase):\n    def test_a(self): self.assertEqual(1, 1)\n",
                    encoding="utf-8",
                )
                ok_bad, msg_bad = flow.verify_real_tests_and_counterproof(wt, tmp, base_sha, ["pkg/__init__.py", "tests/test_add.py"], "fix")
                self.assertFalse(ok_bad)
                self.assertIn("COUNTERPROOF_FAIL", msg_bad)
            finally:
                if old_cmd is None:
                    os.environ.pop("PPASS_COUNTERPROOF_CMD", None)
                else:
                    os.environ["PPASS_COUNTERPROOF_CMD"] = old_cmd
                subprocess.run(["git", "-C", tmp, "worktree", "remove", "--force", wt], capture_output=True)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_4_real_ssh_remote_routing_and_local_single_slot_cap_and_watchdog(self) -> None:
        tmp = tempfile.mkdtemp(prefix="v3_sched_")
        try:
            ssh_log = Path(tmp) / "ssh_calls.log"
            fake_ssh = Path(tmp) / "fake-ssh"
            fake_ssh.write_text(
                "#!/usr/bin/env bash\n"
                f"echo \"$*\" >> '{ssh_log}'\n"
                "echo REMOTE_EXEC_OK\n"
                "exit 0\n",
                encoding="utf-8",
            )
            fake_ssh.chmod(0o755)
            dev_dir = Path(tmp) / "dev"
            dev_dir.mkdir()
            (dev_dir / "ios.state").write_text("SCREEN_LOCKED\n", encoding="utf-8")

            saved = {k: os.environ.get(k) for k in ("PPASS_REMOTE_WORKER", "PPASS_SSH_BIN", "PPASS_V3_DEV_DIR")}
            os.environ["PPASS_REMOTE_WORKER"] = "fake-win-box"
            os.environ["PPASS_SSH_BIN"] = str(fake_ssh)
            os.environ["PPASS_V3_DEV_DIR"] = str(dev_dir)
            try:
                slots = flow.probe_slots(unattended=False)
                self.assertEqual([s["kind"] for s in slots], ["remote", "local"])
                local_slot = next(s for s in slots if s["kind"] == "local")
                self.assertEqual(local_slot["slots"], 1, "即使有远端节点，白天本机槽位依然必须硬限为 1")

                t0 = time.time()
                res = flow.run_watchdog_tasks([
                    {"id": "cross_plat", "cmd": ["cargo", "nextest", "run"], "cwd": str(ROOT), "timeout": 5},
                    {"id": "mac_only", "local_only": True, "cmd": ["echo", "on-mac"], "cwd": str(ROOT), "timeout": 5},
                    {"id": "locked_ios", "device": "ios", "cmd": ["sleep", "10"], "cwd": str(ROOT), "timeout": 5},
                    {"id": "hung_job", "local_only": True, "cmd": ["sleep", "30"], "cwd": str(ROOT), "timeout": 1},
                    {"id": "mut_gh", "local_only": True, "cmd": ["gh", "issue", "edit", "1"], "cwd": str(ROOT), "timeout": 5},
                ], unattended=False)
                elapsed = time.time() - t0
                by_id = {x["id"]: x for x in res}
                self.assertEqual(by_id["cross_plat"]["target"], "remote:fake-win-box", "跨平台任务必须真正路由到远端节点")
                self.assertEqual(by_id["cross_plat"]["status"], "OK")
                self.assertIn("fake-win-box cargo nextest run", ssh_log.read_text(encoding="utf-8"))
                self.assertEqual(by_id["mac_only"]["target"], "local", "mac 专属任务保留在本机单槽运行")
                self.assertEqual(by_id["locked_ios"]["status"], "SUSPENDED_ENV")
                self.assertEqual(by_id["hung_job"]["status"], "SUSPENDED_TIMEOUT")
                self.assertEqual(by_id["mut_gh"]["status"], "FAILED")
                self.assertLess(elapsed, 6.0)
            finally:
                for k, v in saved.items():
                    if v is None:
                        os.environ.pop(k, None)
                    else:
                        os.environ[k] = v
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_5_start_validates_all_cards_acceptance_bug_repro_and_triage_and_owner_stuck(self) -> None:
        tmp = tempfile.mkdtemp(prefix="v3_cards_")
        try:
            bin_dir = Path(tmp) / "bin"
            issues_dir = Path(tmp) / "issues"
            gh_log = Path(tmp) / "gh.log"
            bin_dir.mkdir()
            issues_dir.mkdir()

            def write_issue(num: int, state: str, labels: str, itype: str, body: str, title: str = "fix something") -> None:
                (issues_dir / f"{num}.json").write_text(
                    json.dumps({"state": state, "labels": labels, "type": itype, "body": body, "title": title}, ensure_ascii=False),
                    encoding="utf-8",
                )

            fake_gh = bin_dir / "gh"
            fake_gh.write_text(
                "#!/usr/bin/env python3\n"
                "import json, pathlib, sys\n"
                f"log = pathlib.Path({str(gh_log)!r})\n"
                f"idir = pathlib.Path({str(issues_dir)!r})\n"
                "args = sys.argv[1:]\n"
                "log.open('a', encoding='utf-8').write(' '.join(args) + '\\n')\n"
                "if args[:2] == ['issue', 'view']:\n"
                "    d = json.loads((idir / f'{args[2]}.json').read_text(encoding='utf-8'))\n"
                "    print(f\"state:{d['state']}\\ntitle:{d['title']}\\nlabels:{d['labels']}\\nbody:\\n{d['body']}\")\n"
                "elif args[0] == 'api' and '/issues/' in args[1]:\n"
                "    num = args[1].rstrip('/').split('/')[-1]\n"
                "    d = json.loads((idir / f'{num}.json').read_text(encoding='utf-8'))\n"
                "    print(d['type'])\n"
                "elif args[:2] == ['issue', 'create']:\n"
                "    print('https://github.com/o/r/issues/999')\n"
                "sys.exit(0)\n",
                encoding="utf-8",
            )
            fake_gh.chmod(0o755)

            old_path, old_repo = os.environ.get("PATH", ""), os.environ.get("PPASS_HOOK_REPO")
            os.environ["PATH"] = f"{bin_dir}:{old_path}"
            os.environ["PPASS_HOOK_REPO"] = "o/r"
            try:
                # 1) 缺验收场景的 ready 卡 → 拒绝领卡
                write_issue(11, "OPEN", "status:ready", "Task", "**现象**：a\n")
                rc1, msg1, _ = flow.validate_cards_for_start(["11"], "o/r", str(ROOT), False)
                self.assertEqual(rc1, 1)
                self.assertIn("验收场景", msg1)

                # 2) Bug 卡缺复现路径（或写“无”）→ 拒绝领卡
                write_issue(12, "OPEN", "status:ready,bug", "Bug", "**复现路径**：无\n\n**验收场景**：跑通单测\n")
                rc2, msg2, _ = flow.validate_cards_for_start(["12"], "o/r", str(ROOT), False)
                self.assertEqual(rc2, 1)
                self.assertIn("复现路径", msg2)

                # 3) 多卡启动：第 1 张合格、第 2 张非 OPEN 或缺验收场景 → 整批拒绝，不漏查第二张
                write_issue(13, "OPEN", "status:ready,bug", "Bug", "**复现路径**：cargo test\n\n**验收场景**：绿\n")
                write_issue(14, "CLOSED", "status:ready", "Task", "**验收场景**：绿\n")
                rc3, msg3, _ = flow.validate_cards_for_start(["13", "14"], "o/r", str(ROOT), False)
                self.assertEqual(rc3, 1)
                self.assertIn("#14", msg3)

                # 4) 正例：两张卡均合规 → 通过校验
                write_issue(15, "OPEN", "status:ready", "Task", "**验收场景**：绿\n")
                rc4, _, infos = flow.validate_cards_for_start(["13", "15"], "o/r", str(ROOT), False)
                self.assertEqual(rc4, 0)
                self.assertEqual(len(infos), 2)

                # 5) 极简 triage：拒绝方案文件参数，直接用 --priority/--mode 或卡面字段合成优先级
                self.assertNotEqual(flow.cmd_triage(["15", "some_plan.md"], str(ROOT)), 0)
                write_issue(16, "OPEN", "status:inbox", "Task", "**影响**：不可挽回\n**时间性**：截止日\n")
                self.assertEqual(flow.cmd_triage(["16", "--mode", "fix"], str(ROOT)), 0)
                self.assertIn("P1", gh_log.read_text(encoding="utf-8"))

                # 6) owner-stuck 真实建 blocked issue / 评论指定卡
                gh_log.write_text("", encoding="utf-8")
                self.assertEqual(flow.cmd_owner_stuck(["构建环境故障"], str(ROOT)), 0)
                self.assertIn("issue create", gh_log.read_text(encoding="utf-8"))
                self.assertIn("status:blocked", gh_log.read_text(encoding="utf-8"))
            finally:
                os.environ["PATH"] = old_path
                if old_repo is None:
                    os.environ.pop("PPASS_HOOK_REPO", None)
                else:
                    os.environ["PPASS_HOOK_REPO"] = old_repo
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_6_doctor_auto_cleans_disk_below_threshold(self) -> None:
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

    def test_7_multilang_fake_source_reads_and_zero_false_positives(self) -> None:
        ext_rs, ext_kt, ext_swift, ext_svelte = "rs", "kt", "swift", "svelte"
        # 1) Parity with decision-lib.sh single source of truth
        lib_res = subprocess.run(
            ["bash", "-c", f'source "{ROOT / "tools/flow/decision-lib.sh"}" && fake_src_read_spec'],
            capture_output=True,
            text=True,
            check=True,
        )
        self.assertEqual(flow.FAKE_SRC_SPEC, json.loads(lib_res.stdout))

        # 2) Multi-language negative fixtures (all must be blocked by flow.py)
        tmp = tempfile.mkdtemp(prefix="v3_ml_ft_")
        try:
            neg_samples = {
                "apps/android/app/src/test/java/com/hawkeyexb/ppass/FakeKtTest.kt": (
                    f'val s = File("src/main/java/MainActivity.{ext_kt}").readText()\n'
                ),
                "apps/android/app/src/test/java/com/hawkeyexb/ppass/FakeJavaTest.java": (
                    f'String s = Files.readString(Paths.get(dir, "Main.{ext_kt}"));\n'
                ),
                "apps/ios/PPassTests/FakeSwiftTests.swift": (
                    f'let s = try String(contentsOf: root.appendingPathComponent("Home.{ext_swift}"), encoding: .utf8)\n'
                ),
                "apps/ios/PPassTests/FakeSwiftDataTests.swift": (
                    f'let d = FileManager.default.contents(atPath: "Home.{ext_swift}")\n'
                ),
                "apps/desktop/src/fakeJs.test.js": (
                    f'const s = readFileSync(join(dirname(fileURLToPath(import.meta.url)), "App.{ext_svelte}"), "utf8");\n'
                ),
                "apps/desktop/src/fakeTs.test.ts": (
                    f'const s = await fs.promises.readFile("src/App.{ext_svelte}", "utf8");\n'
                ),
                "crates/daemon/tests/fake_rust.rs": (
                    f'let s = fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("src/lib.{ext_rs}")).unwrap();\n'
                ),
                "crates/daemon/tests/fake_include.rs": (
                    f'let s = include_str!("../src/lib.{ext_rs}");\n'
                ),
                "tests/fake_py_multiline.py": (
                    f'txt = Path(\n    "crates/platform/src/lib.{ext_rs}"\n).read_text()\n'
                ),
            }
            for rel, code in neg_samples.items():
                p = Path(tmp, rel)
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(code, encoding="utf-8")
                ok, msg = flow.verify_real_tests_and_counterproof(tmp, tmp, "HEAD", [rel], "feature")
                self.assertFalse(ok, f"expected FAKE_TEST_BLOCKED for {rel}")
                self.assertIn("FAKE_TEST_BLOCKED", msg)

            # 3) Positive fixtures: resource/JSON/strings/xml/comment-trap/cross-end constant sync
            pos_samples = {
                "apps/android/app/src/test/java/com/hawkeyexb/ppass/RealStringsTest.kt": (
                    'val xml = File("src/main/res/values/strings.xml").readText()\n'
                    f'// see MainActivity.{ext_kt}\n'
                ),
                "apps/ios/PPassTests/RealJsonTests.swift": (
                    'let d = try Data(contentsOf: url("ui-state-truth-table.json"))\n'
                    f'// reference Home.{ext_swift}\n'
                ),
                "apps/desktop/src/realConfig.test.ts": (
                    'const cfg = readFileSync("assets/i18n/en.json", "utf8");\n'
                    f'// App.{ext_svelte}\n'
                ),
                "crates/daemon/tests/real_fixture.rs": (
                    'let doc = include_str!("../../../docs/desktop/business-rules.zh-CN.md");\n'
                ),
                "crates/daemon/tests/flow_health.rs": (
                    f'let a = std::fs::read_to_string(root.join("apps/android/FlowContract.{ext_kt}")).unwrap();\n'
                    f'let b = std::fs::read_to_string(root.join("apps/ios/FlowTypes.{ext_swift}")).unwrap();\n'
                ),
                "tests/real_comment_trap.py": (
                    'sample = "foo." + "rs"\n'
                    'cfg = Path("fixture.json").read_text()\n'
                    f'with open("data.json") as f:\n    pass\n# lib.{ext_rs}\n'
                ),
            }
            for rel, code in pos_samples.items():
                p = Path(tmp, rel)
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(code, encoding="utf-8")
                ok, msg = flow.verify_real_tests_and_counterproof(tmp, tmp, "HEAD", [rel], "feature")
                self.assertTrue(ok, f"unexpected failure for {rel}: {msg}")

            # Counterproof: flow_health.rs reading non-allowlisted UI file must still be blocked
            Path(tmp, "crates/daemon/tests/flow_health.rs").write_text(
                f'let s = include_str!("../../../apps/desktop/src/App.{ext_svelte}");\n',
                encoding="utf-8",
            )
            ok_fh_bad, msg_fh_bad = flow.verify_real_tests_and_counterproof(
                tmp, tmp, "HEAD", ["crates/daemon/tests/flow_health.rs"], "feature"
            )
            self.assertFalse(ok_fh_bad)
            self.assertIn("FAKE_TEST_BLOCKED", msg_fh_bad)

            # 4) Baseline diff ratchet: editing pre-existing test file without adding fake reads passes; adding one fails
            repo = Path(tmp, "repo")
            repo.mkdir()
            subprocess.run(["git", "init", "--template=", "-q", "-b", "main", str(repo)], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.name", "t"], check=True)
            subprocess.run(["git", "-C", str(repo), "config", "user.email", "t@t"], check=True)
            legacy_rel = "apps/ios/PPassTests/LegacyTests.swift"
            (repo / legacy_rel).parent.mkdir(parents=True, exist_ok=True)
            (repo / legacy_rel).write_text(
                f'let old = try String(contentsOf: root.appendingPathComponent("Old.{ext_swift}"), encoding: .utf8)\n',
                encoding="utf-8",
            )
            subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True)
            subprocess.run(["git", "-C", str(repo), "commit", "-q", "-m", "base"], check=True)
            base_sha = subprocess.run(
                ["git", "-C", str(repo), "rev-parse", "HEAD"], capture_output=True, text=True, check=True
            ).stdout.strip()
            (repo / legacy_rel).write_text(
                f'let old = try String(contentsOf: root.appendingPathComponent("Old.{ext_swift}"), encoding: .utf8)\n'
                'XCTAssertEqual(1 + 1, 2)\n',
                encoding="utf-8",
            )
            ok_legacy_clean, msg_legacy_clean = flow.verify_real_tests_and_counterproof(
                str(repo), str(repo), base_sha, [legacy_rel], "feature"
            )
            self.assertTrue(ok_legacy_clean, msg_legacy_clean)
            (repo / legacy_rel).write_text(
                f'let old = try String(contentsOf: root.appendingPathComponent("Old.{ext_swift}"), encoding: .utf8)\n'
                f'let added = try String(contentsOf: root.appendingPathComponent("New.{ext_swift}"), encoding: .utf8)\n',
                encoding="utf-8",
            )
            ok_legacy_bad, msg_legacy_bad = flow.verify_real_tests_and_counterproof(
                str(repo), str(repo), base_sha, [legacy_rel], "feature"
            )
            self.assertFalse(ok_legacy_bad)
            self.assertIn("FAKE_TEST_BLOCKED", msg_legacy_bad)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

        # 5) Zero false positives across entire current repo's existing test files
        tracked = subprocess.check_output(["git", "-C", str(ROOT), "ls-files"], text=True).splitlines()
        all_tests = [f for f in tracked if flow.TEST_RE.search(f)]
        self.assertGreater(len(all_tests), 500)
        for tf in all_tests:
            if tf.startswith("tools/"):
                self.assertEqual(
                    flow.find_fake_source_reads(Path(ROOT, tf).read_text(encoding="utf-8", errors="ignore"), tf),
                    [],
                    f"tool test {tf} must not self-trigger",
                )
        ok_repo, msg_repo = flow.verify_real_tests_and_counterproof(str(ROOT), str(ROOT), "HEAD", all_tests, "feature")
        self.assertTrue(ok_repo, f"repo baseline test audit failed: {msg_repo}")

    def test_8_review_stop_loss_reminder_and_docs_rules(self) -> None:
        c_sugg = flow.format_review_comment("a" * 40, "PASS", "", 0, 1, 0, "- [建议] a:1 —— x", "d1", "PASS")
        self.assertIn(flow.STOP_LOSS_REMINDER, c_sugg)
        c_sty = flow.format_review_comment("a" * 40, "PASS", "", 0, 0, 1, "- [风格] a:1 —— x", "d1", "PASS")
        self.assertIn(flow.STOP_LOSS_REMINDER, c_sty)
        c_clean = flow.format_review_comment("a" * 40, "PASS", "", 0, 0, 0, "未发现问题。", "d1", "PASS")
        self.assertNotIn(flow.STOP_LOSS_REMINDER, c_clean)
        c_fail = flow.format_review_comment("a" * 40, "FAIL", "", 1, 2, 0, "- [阻断] a:1 —— x", "d1", "FAIL")
        self.assertNotIn(flow.STOP_LOSS_REMINDER, c_fail)

        agents = (ROOT / "AGENTS.md").read_text(encoding="utf-8")
        self.assertIn("等齐一次推", agents)
        self.assertIn("0 阻断止损", agents)
        self.assertIn("bounds.height > 0", agents)
        prompt = (ROOT / "tools/flow/review-prompt.md").read_text(encoding="utf-8")
        self.assertIn("bounds.height > 0", prompt)
        self.assertIn("[阻断]", prompt)


if __name__ == "__main__":
    unittest.main(verbosity=2)
