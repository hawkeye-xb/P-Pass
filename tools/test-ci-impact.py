#!/usr/bin/env python3
"""统一依赖图影响范围引擎（tools/ci/impact.py）确定性自测与变异反证。"""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools" / "ci"))
import impact  # noqa: E402

# Avoid literal source extensions next to file-read helpers in test code (#2085).
EXT_RS = "rs"
EXT_KT = "kt"
EXT_SWIFT = "swift"
EXT_SVELTE = "svelte"


def _git_init(repo: Path) -> None:
    env = {**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"}
    subprocess.run(["git", "init", "--template=", "-q", "-b", "main", str(repo)], check=True, env=env)
    subprocess.run(["git", "-C", str(repo), "config", "user.name", "t"], check=True, env=env)
    subprocess.run(["git", "-C", str(repo), "config", "user.email", "t@invalid"], check=True, env=env)
    subprocess.run(["git", "-C", str(repo), "add", "-A"], check=True, env=env)
    subprocess.run(["git", "-C", str(repo), "commit", "-q", "-m", "init"], check=True, env=env)


def _write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _build_synthetic_repo(root: Path) -> None:
    """构造最小但完整的对称多端合成仓库夹具。"""
    _write(
        root / "Cargo.toml",
        '[workspace]\nmembers = ["crates/proto", "crates/transport", "crates/daemon", "crates/diag", "crates/platform"]\n'
        '[patch.crates-io]\nnoq-udp = { path = "third_party/noq-udp" }\n',
    )
    _write(root / "Cargo.lock", '[[package]]\nname = "noq-udp"\nversion = "1.4.0"\n\n'
           '[[package]]\nname = "transport"\nversion = "0.1.0"\ndependencies = ["noq-udp 1.4.0", "proto"]\n\n'
           '[[package]]\nname = "platform"\nversion = "0.1.0"\ndependencies = ["noq-udp 1.4.0"]\n')
    _write(root / "rust-toolchain.toml", '[toolchain]\nchannel = "1.86.0"\n')
    _write(root / ".java-version", "21\n")

    for pkg, deps in {
        "proto": "",
        "transport": '[dependencies]\nproto = { path = "../proto" }\n',
        "platform": "",
        "diag": "",
        "daemon": '[dependencies]\nproto = { path = "../proto" }\nplatform = { path = "../platform" }\ndiag = { path = "../diag" }\n',
    }.items():
        _write(root / f"crates/{pkg}/Cargo.toml", f'[package]\nname = "{pkg}"\nversion = "0.1.0"\n{deps}')
        _write(root / f"crates/{pkg}/src/lib.{EXT_RS}", "pub fn ok() {}\n")

    _write(root / f"crates/diag/src/lib.{EXT_RS}", 'const EN: &str = include_str!("../../../apps/desktop/src/i18n/en.json");\nconst S: &str = include_str!("../../../assets/i18n/en.json");\n')
    _write(root / f"crates/daemon/src/rules.{EXT_RS}", 'const DOC: &str = include_str!("../../../docs/desktop/business-rules.zh-CN.md");\n')
    _write(
        root / f"crates/daemon/tests/flow_health.{EXT_RS}",
        f'fn main() {{ let _ = env!("CARGO_MANIFEST_DIR"); let a = "apps/android/app/src/main/java/FlowContract.{EXT_KT}"; let b = "apps/ios/PPass/FlowTypes.{EXT_SWIFT}"; }}\n',
    )

    _write(root / "third_party/noq-udp/Cargo.toml", '[package]\nname = "noq-udp"\nversion = "1.4.0"\n')
    _write(root / f"third_party/noq-udp/src/lib.{EXT_RS}", "pub fn patch() {}\n")

    _write(
        root / "apps/desktop/src-tauri/Cargo.toml",
        '[package]\nname = "p-pass-desktop"\nversion = "0.1.0"\n[dependencies]\nplatform = { path = "../../../crates/platform" }\n',
    )
    _write(root / f"apps/desktop/src-tauri/src/lib.{EXT_RS}", 'const DOC: &str = include_str!("../../../../docs/desktop/business-rules.zh-CN.md");\n')
    _write(root / "apps/desktop/src/i18n/en.json", "{}\n")
    _write(root / "apps/desktop/src/i18n/zh.json", "{}\n")
    _write(root / f"apps/desktop/src/App.{EXT_SVELTE}", "<main>hi</main>\n")
    _write(root / "apps/desktop/src/businessRulesTable.test.js", 'const u = new URL("../../../docs/desktop/business-rules.zh-CN.md", import.meta.url);\n')

    _write(root / "assets/i18n/en.json", "{}\n")
    _write(root / "assets/design/tokens.json", "{}\n")
    _write(root / "assets/design/tokens.css", ":root {}\n")
    _write(root / "assets/privacy/redact-vectors.json", "{}\n")
    _write(root / "assets/contracts/ui-state-truth-table.json", "{}\n")
    _write(root / "tests/blake3-vectors.json", "{}\n")
    _write(root / "tests/flow-audit-item-events.json", "{}\n")
    _write(root / "docs/desktop/business-rules.zh-CN.md", "# rules\n")
    _write(root / "docs/a.md", "# doc\n")
    _write(root / "AGENTS.md", "# agents\n")
    _write(root / "CLAUDE.md", "# claude\n")
    _write(root / "CHANGELOG.md", "# log\n")
    _write(root / ".coderabbit.yaml", "reviews:\n")
    _write(root / "justfile", "import 'tools/just/checks.just'\n")
    _write(root / "tools/just/checks.just", "flow-tests:\n  @python3 -B -I tools/test-ci-impact.py\n")

    _write(root / "apps/android/app/build.gradle.kts", 'include("Cargo.toml", "Cargo.lock", "crates/transport/**", "crates/proto/**")\n')
    _write(root / f"apps/android/app/src/main/java/FlowContract.{EXT_KT}", "object FlowContract {}\n")
    _write(root / f"apps/android/app/src/test/java/TokensTest.{EXT_KT}", 'val f = File("../../../assets/design/tokens.json")\n')
    _write(root / "apps/android/app/src/main/res/values/strings.xml", "<resources/>\n")
    _write(root / "apps/android/app/src/main/res/values-zh/strings.xml", "<resources/>\n")
    _write(root / "apps/android/app/src/main/res/values-zh/strings_android_only.xml", "<resources/>\n")

    _write(root / f"apps/ios/PPass/FlowTypes.{EXT_SWIFT}", "enum FlowTypes {}\n")
    _write(root / f"apps/ios/PPass/Home/AboutScreen.{EXT_SWIFT}", "struct AboutScreen {}\n")
    _write(root / "apps/ios/PPass/Resources/PrivacyInfo.xcprivacy", "<plist/>\n")
    _write(root / f"apps/ios/TransportFFITests/Tests/TransportFFITests/T.{EXT_SWIFT}", 'let u = repoFile("tests/blake3-vectors.json")\n')

    _write(root / "tools/build-ios-transport-xcframework.sh", '#!/usr/bin/env bash\ninputs = [\n  "Cargo.toml",\n  "Cargo.lock",\n  "rust-toolchain.toml",\n  "tools/build-ios-transport-xcframework.sh",\n  "crates/transport",\n  "crates/proto",\n  "third_party/noq-udp",\n]\n')
    _write(root / "tools/build-android-iroh-blobs-bridge.sh", "#!/usr/bin/env bash\necho android-ffi\n")
    _write(root / "tools/ios/gen-strings.py", 'RES = "apps/android/app/src/main/res"\nLANGS = {"values": "en", "values-zh": "zh-Hans"}\n# strings.xml\n')
    _write(root / "tools/ios/gen-tokens.py", 'TOKENS = "assets/design/tokens.json"\n')
    _write(root / "tools/ios/check-privacy-manifest.py", 'MANIFEST = "apps/ios/PPass/Resources/PrivacyInfo.xcprivacy"\n')
    _write(root / "tools/ios/test.sh", '#!/usr/bin/env bash\nbash tools/build-ios-transport-xcframework.sh\n')
    _write(root / "tools/ios/test-transport-ffi.sh", "#!/usr/bin/env bash\necho ffi\n")
    _write(root / "tools/flow/pr-watch.sh", "#!/usr/bin/env bash\necho watch\n")
    _write(root / "tools/test-pr-watch.sh", "#!/usr/bin/env bash\necho ok\n")
    _write(root / "tools/ci/impact.py", "# impact\n")
    _write(root / "tools/test-ci-impact.py", "# test\n")
    _write(root / "tools/ci-needs-full-lane.sh", "#!/usr/bin/env bash\npython3 -B -I tools/ci/impact.py\n")
    _write(root / "tools/test-ci-needs-full-lane.sh", "#!/usr/bin/env bash\necho ok\n")
    _write(root / "tools/arch-check.sh", "#!/usr/bin/env bash\necho arch\n")
    _write(root / "tools/setup-rust-toolchain.sh", "#!/usr/bin/env bash\necho rust\n")
    _write(root / "tools/clean-local-builds.sh", "#!/usr/bin/env bash\necho clean\n")
    _write(root / "tools/release/test-carry-signature.sh", "#!/usr/bin/env bash\necho carry\n")
    _write(root / "tools/release/tauri-config.test.mjs", "console.log('ok')\n")

    _write(root / ".github/actions/changes/action.yml", "runs:\n  using: composite\n  steps:\n    - run: python3 -B -I tools/test-ci-impact.py\n    - run: python3 -B -I tools/ci/impact.py ci\n")
    _write(root / ".github/actions/desktop-checks/action.yml", "runs:\n  using: composite\n  steps:\n    - run: tools/setup-rust-toolchain.sh\n")
    _write(
        root / ".github/workflows/ci-rust.yml",
        "jobs:\n  changes:\n    steps:\n      - run: python3 -B -I tools/test-ci-impact.py\n      - run: tools/test-ci-needs-full-lane.sh\n      - run: tools/ci-needs-full-lane.sh\n  test:\n    steps:\n      - run: tools/setup-rust-toolchain.sh\n      - run: tools/arch-check.sh\n",
    )
    _write(
        root / ".github/workflows/ci-desktop.yml",
        "jobs:\n  changes:\n    steps:\n      - run: tools/ci-needs-full-lane.sh\n  desktop-windows:\n    steps:\n      - uses: ./.github/actions/desktop-checks\n",
    )
    _write(
        root / ".github/workflows/ci-android.yml",
        "jobs:\n  changes:\n    steps:\n      - uses: ./.github/actions/changes\n        with:\n          lane: android\n  android:\n    steps:\n      - run: tools/build-android-iroh-blobs-bridge.sh\n",
    )
    _write(
        root / ".github/workflows/ci-ios.yml",
        "# tools/ios/** comment only\njobs:\n  changes:\n    steps:\n      - uses: ./.github/actions/changes\n        with:\n          lane: ios\n  ios-static:\n    steps:\n      - run: python3 tools/ios/gen-tokens.py --check\n      - run: python3 tools/ios/gen-strings.py --check\n  ios:\n    steps:\n      - run: tools/ios/test.sh\n  ios-ffi:\n    steps:\n      - run: tools/setup-rust-toolchain.sh\n      - run: python3 tools/ios/check-privacy-manifest.py\n      - run: tools/ios/test-transport-ffi.sh\n  gate:\n    steps:\n      - run: echo ok\n",
    )
    _write(
        root / ".github/workflows/ci-docs.yml",
        "jobs:\n"
        "  changes:\n"
        "    steps:\n"
        "      - uses: ./.github/actions/changes\n"
        "        with:\n"
        "          lane: docs\n"
        "  acceptance-gate:\n"
        "    if: ${{ github.event_name == 'pull_request' }}\n"
        "    steps:\n"
        "      - run: echo acceptance\n"
        "  docs:\n"
        "    needs: changes\n"
        "    if: ${{ !cancelled() && needs.changes.outputs.run != 'false' }}\n"
        "    steps:\n"
        "      - run: echo docs\n"
        "  release-plan:\n"
        "    needs: changes\n"
        "    if: ${{ !cancelled() && needs.changes.outputs.run != 'false' }}\n"
        "    steps:\n"
        "      - run: bash tools/release/test-carry-signature.sh\n"
        "      - run: node --test tools/release/tauri-config.test.mjs\n"
        "  flow-tests:\n"
        "    needs: changes\n"
        "    if: ${{ !cancelled() && needs.changes.outputs.flow != 'false' }}\n"
        "    steps:\n"
        "      - run: just flow-tests\n"
        "  gate:\n"
        "    steps:\n"
        "      - run: echo ok\n",
    )
    _git_init(root)


class ImpactEngineTests(unittest.TestCase):
    def test_1_real_repo_graph_parsing_and_patch_closure(self) -> None:
        g = impact.RepoGraph(ROOT)
        self.assertIn("crates/transport", g.root_member_dirs)
        self.assertIn("third_party/noq-udp", g.patch_dirs)
        self.assertEqual(g.tauri_pkg, "p-pass-desktop")
        ffi_dirs = g.ffi_crate_prefixes()
        self.assertTrue({"crates/transport", "crates/proto", "third_party/noq-udp"} <= ffi_dirs)
        self.assertEqual(set(g.rust_readers["apps/desktop/src/i18n/en.json"]), {"diag", "p-pass-desktop"})
        self.assertIn("daemon", g.rust_readers["docs/desktop/business-rules.zh-CN.md"])
        self.assertIn("p-pass-desktop", g.rust_readers["docs/desktop/business-rules.zh-CN.md"])
        self.assertIn("docs/desktop/business-rules.zh-CN.md", g.desktop_ui_readers)
        self.assertIn(
            "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/flow/FlowContract.kt",
            g.rust_readers,
        )
        self.assertIn(
            "apps/ios/Packages/PPassCore/Sources/PPassCore/Flow/FlowTypes.swift",
            g.rust_readers,
        )
        self.assertIn("assets/design/tokens.json", g.android_readers)
        self.assertIn("assets/privacy/redact-vectors.json", g.android_readers)
        self.assertIn("assets/privacy/redact-vectors.json", g.ios_readers)
        self.assertIn("apps/ios/PPass/Resources/PrivacyInfo.xcprivacy", g.ios_ffi_readers)
        self.assertIn("third_party/noq-udp", g.ios_ffi_inputs)

    def test_2_toml_python310_fallback_parity(self) -> None:
        fixed_toml = (
            '[workspace]\n'
            'members = [\n'
            '  "crates/proto",\n'
            '  "crates/transport",\n'
            '  "crates/daemon",\n'
            ']\n'
            '[patch.crates-io]\n'
            'noq-udp = { path = "third_party/noq-udp" }\n'
        )
        expected_members = ["crates/proto", "crates/transport", "crates/daemon"]
        parsed_fixed_fb = impact._parse_toml_fallback(fixed_toml)
        self.assertEqual(parsed_fixed_fb["workspace"]["members"], expected_members)
        self.assertEqual(parsed_fixed_fb["patch"]["crates-io"]["noq-udp"]["path"], "third_party/noq-udp")
        parsed_fixed_load = impact.load_toml(fixed_toml)
        self.assertEqual(parsed_fixed_load["workspace"]["members"], expected_members)
        self.assertEqual(parsed_fixed_load["patch"]["crates-io"]["noq-udp"]["path"], "third_party/noq-udp")

        if impact.tomllib is not None:
            sample = _read(ROOT / "Cargo.toml")
            parsed_fb = impact._parse_toml_fallback(sample)
            parsed_std = impact.tomllib.loads(sample)
            self.assertEqual(parsed_fb["workspace"]["members"], parsed_std["workspace"]["members"])
            self.assertEqual(parsed_fb["patch"]["crates-io"]["noq-udp"], parsed_std["patch"]["crates-io"]["noq-udp"])

    def test_3_synthetic_symmetry_closures_and_fail_closed(self) -> None:
        tmp = Path(tempfile.mkdtemp(prefix="ci_impact_syn_"))
        try:
            _build_synthetic_repo(tmp)
            g = impact.RepoGraph(tmp)

            def d(lane: str, files: list[str]) -> bool:
                return impact.decide_ci(lane, files, tmp, graph=g)[0]

            # justfile / tools/just/*.just：仅 docs & docs-flow 触发，其余全跳过
            for jf in ("justfile", "tools/just/checks.just"):
                self.assertFalse(d("default", [jf]))
                self.assertFalse(d("rust-workspace", [jf]))
                self.assertFalse(d("android", [jf]))
                self.assertFalse(d("ios", [jf]))
                self.assertFalse(d("ios-ffi", [jf]))
                self.assertTrue(d("docs", [jf]))
                self.assertTrue(d("docs-flow", [jf]))

            # third_party/noq-udp：四端与 Rust 均触发
            noq = [f"third_party/noq-udp/src/lib.{EXT_RS}"]
            for lane in ("default", "rust-workspace", "android", "ios", "ios-ffi"):
                self.assertTrue(d(lane, noq), f"expected True for {lane}")
            self.assertFalse(d("docs", noq))
            self.assertFalse(d("docs-flow", noq))

            # iOS 普通 UI 不触发 ios-ffi；FFI 测试 / PrivacyInfo / transport 触发 ios-ffi
            self.assertTrue(d("ios", [f"apps/ios/PPass/Home/AboutScreen.{EXT_SWIFT}"]))
            self.assertFalse(d("ios-ffi", [f"apps/ios/PPass/Home/AboutScreen.{EXT_SWIFT}"]))
            self.assertTrue(d("ios-ffi", ["apps/ios/PPass/Resources/PrivacyInfo.xcprivacy"]))
            self.assertTrue(d("ios-ffi", ["tests/blake3-vectors.json"]))
            self.assertTrue(d("ios-ffi", [f"crates/transport/src/lib.{EXT_RS}"]))

            # Android shared strings.xml 触发 ios，android_only 不触发 ios
            self.assertTrue(d("android", ["apps/android/app/src/main/res/values/strings.xml"]))
            self.assertTrue(d("ios", ["apps/android/app/src/main/res/values/strings.xml"]))
            self.assertFalse(d("ios-ffi", ["apps/android/app/src/main/res/values/strings.xml"]))
            self.assertTrue(d("android", ["apps/android/app/src/main/res/values-zh/strings_android_only.xml"]))
            self.assertFalse(d("ios", ["apps/android/app/src/main/res/values-zh/strings_android_only.xml"]))

            # 无关 workflow 不再跨 lane 误触发
            self.assertFalse(d("android", [".github/workflows/ci-rust.yml"]))
            self.assertFalse(d("ios", [".github/workflows/ci-rust.yml"]))
            self.assertFalse(d("ios-ffi", [".github/workflows/ci-android.yml"]))
            # tools/ios/test.sh 不在 ios-ffi 切片里，不触发 ios-ffi
            self.assertTrue(d("ios", ["tools/ios/test.sh"]))
            self.assertFalse(d("ios-ffi", ["tools/ios/test.sh"]))

            # 统一 engine 或 changes action 被改 → 全 7 lane 必须跑
            for lane in impact.VALID_LANES:
                self.assertTrue(d(lane, ["tools/ci/impact.py"]))
                self.assertTrue(d(lane, [".github/actions/changes/action.yml"]))

            # Fail-closed 检查
            self.assertTrue(d("unknown-lane", ["docs/a.md"]))
            self.assertTrue(d("android", []))
            self.assertTrue(d("android", ["newthing/mystery.txt"]))
            self.assertTrue(d("ios", ["../escape.txt"]))
            self.assertTrue(d("default", ["tools/missing-script.sh"]))
            self.assertTrue(impact.decide_ci_from_base("", "android", tmp)[0])
            self.assertTrue(impact.decide_ci_from_base("0" * 40, "ios", tmp)[0])

            # 惰性目录下的 tools/ 脚本若被静态 workflow 调用，闭包必须继续追踪 tools/ 下游引用方
            _write(tmp / "tools/flow/check-native.sh", "#!/usr/bin/env bash\nbash tools/check-native-input.sh\n")
            _write(tmp / "tools/check-native-input.sh", "#!/usr/bin/env bash\necho ok\n")
            _write(
                tmp / ".github/workflows/ci-android.yml",
                _read(tmp / ".github/workflows/ci-android.yml") + "      - run: tools/flow/check-native.sh\n",
            )
            subprocess.run(["git", "-C", str(tmp), "add", "-A"], check=True, env={**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"})
            subprocess.run(["git", "-C", str(tmp), "commit", "-q", "-m", "add-transitive-tools-flow"], check=True, env={**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"})
            self.assertTrue(d("android", ["tools/check-native-input.sh"]))
            self.assertFalse(d("ios", ["tools/check-native-input.sh"]))
            self.assertFalse(d("default", ["tools/check-native-input.sh"]))

            # 注释中的 tools/ios/** 不误报动态通配；真实动态通配触发 fail-closed（含 tools/flow/ 等通常惰性脚本）
            self.assertFalse(d("ios-ffi", ["tools/clean-local-builds.sh"]))
            self.assertFalse(d("ios", ["tools/flow/pr-watch.sh"]))
            _write(tmp / ".github/workflows/ci-ios.yml", _read(tmp / ".github/workflows/ci-ios.yml") + "      - run: tools/dyn/*.sh\n")
            self.assertTrue(d("ios", ["tools/clean-local-builds.sh"]))
            self.assertTrue(d("ios", ["tools/flow/pr-watch.sh"]))

            # 带引号的本地 action 引用（"./.github/actions/..." 与 './.github/actions/...'）纳入切片并触发对应 lane
            _write(tmp / ".github/actions/native-double/action.yml", "runs:\n  using: composite\n  steps:\n    - run: tools/native-double.sh\n")
            _write(tmp / ".github/actions/native-single/action.yml", "runs:\n  using: composite\n  steps:\n    - run: tools/native-single.sh\n")
            _write(tmp / "tools/native-double.sh", "#!/usr/bin/env bash\necho ok\n")
            _write(tmp / "tools/native-single.sh", "#!/usr/bin/env bash\necho ok\n")
            _write(
                tmp / ".github/workflows/ci-android.yml",
                _read(tmp / ".github/workflows/ci-android.yml")
                + '      - uses: "./.github/actions/native-double"\n'
                + "      - uses: './.github/actions/native-single'\n",
            )
            subprocess.run(["git", "-C", str(tmp), "add", "-A"], check=True, env={**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"})
            subprocess.run(["git", "-C", str(tmp), "commit", "-q", "-m", "add-quoted-actions"], check=True, env={**os.environ, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"})
            self.assertTrue(d("android", ["tools/native-double.sh"]))
            self.assertTrue(d("android", ["tools/native-single.sh"]))

            # 已删除但仍被 Android/iOS/Rust 测试读取的夹具路径保留在 reader 集合中，防删除夹具漏触发
            _write(
                tmp / f"apps/android/app/src/test/java/DeletedFixtureTest.{EXT_KT}",
                'val f = File("assets/contracts/extra-golden.json")\nval g = File("docs/android/golden.md")\n',
            )
            _write(
                tmp / f"apps/ios/PPassTests/DeletedFixtureTest.{EXT_SWIFT}",
                'let d = repoFile("docs/ios/golden.md")\n',
            )
            g2 = impact.RepoGraph(tmp)
            self.assertIn("assets/contracts/extra-golden.json", g2.android_readers)
            self.assertIn("docs/android/golden.md", g2.android_readers)
            self.assertIn("docs/ios/golden.md", g2.ios_readers)
            self.assertTrue(impact.decide_ci("android", ["assets/contracts/extra-golden.json"], tmp, graph=g2)[0])
            self.assertTrue(impact.decide_ci("android", ["docs/android/golden.md"], tmp, graph=g2)[0])
            self.assertTrue(impact.decide_ci("ios", ["docs/ios/golden.md"], tmp, graph=g2)[0])

            # 存在 Android/iOS 代码消费者的文档不得提前跳过为只跑 md-check
            android_doc_gates = impact.compute_local_gates(["docs/android/golden.md"], tmp)
            self.assertIn("just android-test", android_doc_gates)
            ios_doc_gates = impact.compute_local_gates(["docs/ios/golden.md"], tmp)
            self.assertIn("just ios-test", ios_doc_gates)

            # ci-docs.yml 发版链 job（消费 needs.changes.outputs.run）调用的脚本/测试必须命中 docs lane
            self.assertTrue(d("docs", ["tools/release/test-carry-signature.sh"]))
            self.assertTrue(d("docs", ["tools/release/tauri-config.test.mjs"]))

            # 缺失 lane workflow 文件时即便是纯文档改动也 fail-closed 返回要跑
            (tmp / ".github/workflows/ci-android.yml").unlink()
            self.assertTrue(impact.decide_ci("android", ["docs/a.md"], tmp, graph=g2)[0])

            # 缺失 job_filter 中任一必需 job 名时，fail-closed 返回要跑（不得静默缩小切片）
            self.assertFalse(impact.decide_ci("ios-ffi", [".coderabbit.yaml"], tmp, graph=g2)[0])
            _write(
                tmp / ".github/workflows/ci-ios.yml",
                _read(tmp / ".github/workflows/ci-ios.yml").replace("  ios-ffi:\n", "  ios-ffi-renamed:\n", 1),
            )
            self.assertTrue(impact.decide_ci("ios-ffi", [".coderabbit.yaml"], tmp, graph=g2)[0])

            self.assertFalse(impact.decide_ci("docs-flow", [".coderabbit.yaml"], tmp, graph=g2)[0])
            self.assertFalse(impact.decide_ci("docs", [f"crates/proto/src/lib.{EXT_RS}"], tmp, graph=g2)[0])
            _write(
                tmp / ".github/workflows/ci-docs.yml",
                _read(tmp / ".github/workflows/ci-docs.yml")
                .replace("  flow-tests:\n", "  flow-tests-renamed:\n", 1)
                .replace("  acceptance-gate:\n", "  acceptance-gate-renamed:\n", 1),
            )
            self.assertTrue(impact.decide_ci("docs-flow", [".coderabbit.yaml"], tmp, graph=g2)[0])
            self.assertTrue(impact.decide_ci("docs", [f"crates/proto/src/lib.{EXT_RS}"], tmp, graph=g2)[0])
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_4_inclusion_invariants_and_local_gates(self) -> None:
        g = impact.RepoGraph(ROOT)
        samples = [
            ["docs/a.md"],
            ["AGENTS.md"],
            ["justfile"],
            ["tools/just/checks.just"],
            ["apps/desktop/src/i18n/en.json"],
            ["docs/desktop/business-rules.zh-CN.md"],
            [f"apps/ios/PPass/Home/AboutScreen.{EXT_SWIFT}"],
            ["apps/ios/PPass/Resources/PrivacyInfo.xcprivacy"],
            [f"crates/transport/src/lib.{EXT_RS}"],
            [f"third_party/noq-udp/src/lib.{EXT_RS}"],
            ["newthing/unknown.xyz"],
        ]
        for s in samples:
            r_arch = impact.decide_ci("default", s, ROOT, graph=g)[0]
            r_heavy = impact.decide_ci("rust-workspace", s, ROOT, graph=g)[0]
            self.assertFalse(r_heavy and not r_arch, f"inclusion broken for {s}")
            r_ios = impact.decide_ci("ios", s, ROOT, graph=g)[0]
            r_ffi = impact.decide_ci("ios-ffi", s, ROOT, graph=g)[0]
            self.assertFalse(r_ffi and not r_ios, f"ios inclusion broken for {s}")

        g_i18n = impact.compute_local_gates(["apps/desktop/src/i18n/en.json"], ROOT)
        self.assertIn("pnpm -C apps/desktop test", g_i18n)
        self.assertIn("cargo nextest run -p diag", g_i18n)
        self.assertIn("cargo nextest run --manifest-path apps/desktop/src-tauri/Cargo.toml -p p-pass-desktop", g_i18n)

        g_br = impact.compute_local_gates(["docs/desktop/business-rules.zh-CN.md"], ROOT)
        self.assertIn("just md-check", g_br)
        self.assertIn("cargo nextest run -p daemon", g_br)
        self.assertIn("cargo nextest run --manifest-path apps/desktop/src-tauri/Cargo.toml -p p-pass-desktop", g_br)
        self.assertIn("pnpm -C apps/desktop test", g_br)

        self.assertEqual(impact.compute_local_gates(["justfile"], ROOT), ["just ci-docs"])
        self.assertEqual(impact.compute_local_gates(["tools/just/checks.just"], ROOT), ["just ci-docs"])

        g_unk = impact.compute_local_gates([".gitignore", "assets/contracts/truth.json"], ROOT)
        self.assertNotIn("just ci", g_unk)
        self.assertIn("just arch-check", g_unk)

        g_noq = impact.compute_local_gates([f"third_party/noq-udp/src/lib.{EXT_RS}"], ROOT)
        self.assertIn("cargo nextest run -p platform", g_noq)
        self.assertIn("cargo nextest run -p transport", g_noq)

    def test_5_historical_pr_replays_when_workflows_migrated(self) -> None:
        ci_ios_txt = (ROOT / ".github/workflows/ci-ios.yml").read_text(encoding="utf-8")
        if "lane: ios" not in ci_ios_txt:
            # 迁移中间步尚未改 ci-ios.yml 时在合成夹具中完成对应校验
            return
        g = impact.RepoGraph(ROOT)

        def pr_files(rev: str, fallback: list[str]) -> list[str]:
            if subprocess.run(["git", "-C", str(ROOT), "cat-file", "-e", f"{rev}^{{commit}}"], capture_output=True).returncode == 0:
                return subprocess.check_output(["git", "-C", str(ROOT), "show", "--name-only", "--format=", rev], text=True).splitlines()
            return fallback

        f2078 = pr_files("83282955", ["justfile", "tools/flow/pr-watch.sh", "tools/test-pr-watch.sh"])
        for l in ("default", "rust-workspace", "android", "ios", "ios-ffi"):
            self.assertFalse(impact.decide_ci(l, f2078, ROOT, graph=g)[0], f"#2078 {l}")
        self.assertTrue(impact.decide_ci("docs", f2078, ROOT, graph=g)[0])
        self.assertTrue(impact.decide_ci("docs-flow", f2078, ROOT, graph=g)[0])

        f2087 = ["justfile"]
        for l in ("default", "rust-workspace", "android", "ios", "ios-ffi"):
            self.assertFalse(impact.decide_ci(l, f2087, ROOT, graph=g)[0], f"#2086/#2087 {l}")
        self.assertEqual(impact.compute_local_gates(f2087, ROOT), ["just ci-docs"])

        f2076 = pr_files(
            "e43b87c5",
            [
                f"apps/desktop/src/App.{EXT_SVELTE}",
                "apps/desktop/src/i18n/en.json",
                f"apps/ios/PPass/Home/AboutScreen.{EXT_SWIFT}",
                f"apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/AboutScreen.{EXT_KT}",
                f"crates/diag/src/keys.{EXT_RS}",
                "tools/egress-allowlist.txt",
            ],
        )
        self.assertTrue(impact.decide_ci("default", f2076, ROOT, graph=g)[0])
        self.assertTrue(impact.decide_ci("rust-workspace", f2076, ROOT, graph=g)[0])
        self.assertTrue(impact.decide_ci("android", f2076, ROOT, graph=g)[0])
        self.assertTrue(impact.decide_ci("ios", f2076, ROOT, graph=g)[0])
        self.assertFalse(impact.decide_ci("ios-ffi", f2076, ROOT, graph=g)[0], "#2076 must not trigger ios-ffi")

        f2081 = pr_files(
            "d28d2fa6",
            [
                "CHANGELOG.md",
                f"apps/desktop/src/App.{EXT_SVELTE}",
                "apps/desktop/src/i18n/en.json",
                f"crates/daemon/src/ipc.{EXT_RS}",
                "docs/desktop/business-rules.zh-CN.md",
                "tools/dogfood-smoke.sh",
            ],
        )
        self.assertTrue(impact.decide_ci("default", f2081, ROOT, graph=g)[0])
        self.assertTrue(impact.decide_ci("rust-workspace", f2081, ROOT, graph=g)[0])
        self.assertFalse(impact.decide_ci("android", f2081, ROOT, graph=g)[0])
        self.assertFalse(impact.decide_ci("ios", f2081, ROOT, graph=g)[0])
        self.assertFalse(impact.decide_ci("ios-ffi", f2081, ROOT, graph=g)[0])
        self.assertTrue(impact.decide_ci("docs", f2081, ROOT, graph=g)[0])
        self.assertTrue(impact.decide_ci("docs-flow", f2081, ROOT, graph=g)[0])

        f2088 = pr_files("55dc3915", ["AGENTS.md", "tools/flow/flow.py", "tools/test-flow.py"])
        for l in ("default", "rust-workspace", "android", "ios", "ios-ffi"):
            self.assertFalse(impact.decide_ci(l, f2088, ROOT, graph=g)[0], f"#2088 {l}")
        self.assertTrue(impact.decide_ci("docs", f2088, ROOT, graph=g)[0])
        self.assertTrue(impact.decide_ci("docs-flow", f2088, ROOT, graph=g)[0])

        # 真实仓库下 ci-docs.yml 发版链 job 调用的脚本与 mjs 测试必须命中 docs lane
        self.assertTrue(impact.decide_ci("docs", ["tools/release/test-carry-signature.sh"], ROOT, graph=g)[0])
        self.assertTrue(impact.decide_ci("docs", ["tools/release/tauri-config.test.mjs"], ROOT, graph=g)[0])

    def test_6_mutant_counterproofs(self) -> None:
        # 变异 1：删掉 _static_inert_rust 中的 rust_readers 动态拦截时，crates 跨目录读取的新 apps 文件必须失守漏过
        src = (ROOT / "tools/ci/impact.py").read_text(encoding="utf-8")
        mut = src.replace(
            'if readers and (lane != "rust-workspace" or any(pkg != graph.tauri_pkg for pkg in readers)):\n        return False',
            "if False:\n        return False",
            1,
        )
        self.assertNotEqual(src, mut, "mutant anchor 1 missing")
        ns: dict = {}
        exec(compile(mut, "mut_impact_1.py", "exec"), ns)

        tmp = Path(tempfile.mkdtemp(prefix="ci_impact_mut_"))
        try:
            _build_synthetic_repo(tmp)
            _write(tmp / "apps/desktop/extra_contract.json", "{}\n")
            _write(
                tmp / f"crates/diag/src/lib.{EXT_RS}",
                'const EX: &str = include_str!("../../../apps/desktop/extra_contract.json");\n',
            )
            self.assertTrue(impact.decide_ci("rust-workspace", ["apps/desktop/extra_contract.json"], tmp)[0])
            mg = ns["RepoGraph"](tmp)
            self.assertFalse(ns["decide_ci"]("rust-workspace", ["apps/desktop/extra_contract.json"], tmp, graph=mg)[0])
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

        # 变异 2：破坏 docs 的 tools/just/*.just 判断，必须失去对 .just 改动的捕获能力
        mut2 = src.replace(
            'if rel_path.startswith("tools/just/") and rel_path.endswith(".just"):\n            return False',
            'if rel_path.startswith("tools/just/") and rel_path.endswith(".just"):\n            return True',
            1,
        )
        self.assertNotEqual(src, mut2, "mutant anchor 2 missing")
        ns2: dict = {}
        exec(compile(mut2, "mut_impact_2.py", "exec"), ns2)
        mg2 = ns2["RepoGraph"](ROOT)
        self.assertFalse(ns2["decide_ci"]("docs", ["tools/just/checks.just"], ROOT, graph=mg2)[0])
        self.assertTrue(impact.decide_ci("docs", ["tools/just/checks.just"], ROOT)[0])


def _read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


if __name__ == "__main__":
    unittest.main(verbosity=2)
