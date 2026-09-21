#!/usr/bin/env bash
# Enforce rust-toolchain.toml as the single Rust-version authority in Cargo CI.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

python3 - "$repo_root" <<'PY'
from __future__ import annotations

import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib

root = pathlib.Path(sys.argv[1])
toolchain_file = root / "rust-toolchain.toml"
with toolchain_file.open("rb") as fh:
    pinned = tomllib.load(fh)["toolchain"]["channel"]

expected_jobs = {
    # CI-13 (#274)：test-windows 是 CI-06 (#249) 加的，当时漏了同步这份名单，
    # 于是全仓唯一在真 Windows 上跑 daemon 测试的那条 lane，工具链锁定**没人守**。
    # 2026-09-21 普查过一遍（「文件里所有 run: cargo」对「本名单覆盖到的 job」
    # 做差集）：全仓只有它一个漏网，补上之后差集为空。
    ".github/workflows/ci-rust.yml": {"fmt", "clippy", "test", "test-windows", "deny"},
    # CI-11 (#255)：空集**不是**「这个文件不用查」。ci-desktop 的两个 job
    # 自己不跑 Cargo——Cargo 命令和工具链 setup 都在共享 composite action
    # 里（拆 job 去掉现算检查名时搬过去的）。文件仍然在这里列着，是为了继续
    # 吃下面那两条全文检查（dtolnay / 重复钉版本号）；job 层的判据由
    # delegated_jobs 接力，**判据本身一个字没放宽**。
    ".github/workflows/ci-desktop.yml": set(),
    # CI-02: release 二进制只在 build job 里编译一次；e2e/scenarios 只
    # download-artifact 后运行已构建二进制，不跑 Cargo，不需要工具链 setup。
    ".github/workflows/e2e.yml": {"build"},
    ".github/workflows/release.yml": {"macos-arm64", "windows-x64"},
    ".github/workflows/artifacts.yml": {
        "macos-arm64-bin",
        "linux-bin",
        "windows-x64-bin",
    },
}

# job 自己不跑 Cargo，把活委托给仓库内的 composite action。
# **两头都必须查，缺一头就是 fail-open**：
#   - 只查 action、不查引用 ⇒ 有人把 job 里的 `uses:` 删了，action 文件还在，
#     判据照样报绿，而那条 lane 已经没有工具链锁定了；
#   - 只查引用、不查 action ⇒ action 里的 setup 步骤被删了没人管。
delegated_jobs = {
    ".github/workflows/ci-desktop.yml": {
        "desktop-linux": ".github/actions/desktop-checks",
        "desktop-windows": ".github/actions/desktop-checks",
    },
}

setup_name = "- name: Set Rust toolchain from rust-toolchain.toml"
setup_run = "run: tools/setup-rust-toolchain.sh"
errors: list[str] = []


def parse_jobs(lines: list[str]) -> dict[str, str]:
    jobs: dict[str, str] = {}
    in_jobs = False
    current_job: str | None = None
    job_lines: list[str] = []
    for line in lines:
        if line == "jobs:":
            in_jobs = True
            continue
        if not in_jobs:
            continue
        match = re.fullmatch(r"  ([A-Za-z0-9_-]+):", line)
        if match:
            if current_job is not None:
                jobs[current_job] = "\n".join(job_lines)
            current_job = match.group(1)
            job_lines = [line]
        elif current_job is not None:
            job_lines.append(line)
    if current_job is not None:
        jobs[current_job] = "\n".join(job_lines)
    return jobs


def check_version_authority(label: str, text: str) -> None:
    """rust-toolchain.toml 必须是唯一版本权威。"""
    if "dtolnay/rust-toolchain" in text:
        errors.append(f"{label}: dtolnay/rust-toolchain may override rust-toolchain.toml")
    if pinned in text:
        errors.append(f"{label}: duplicates pinned Rust version {pinned!r}")


def check_setup_precedes_cargo(label: str, body: str) -> None:
    """跑 Cargo 的单位必须先在一个命名步骤里执行 setup 脚本。

    job 和 composite action 用的是**同一条判据**——单位变了，标准没变。
    """
    cargo_positions = [
        match.start() for match in re.finditer(r"(?m)^\s*run:\s*cargo\b", body)
    ]
    if not cargo_positions:
        errors.append(f"{label}: expected a Cargo run command")
        return
    setup_position = body.find(setup_name)
    setup_run_position = body.find(setup_run)
    if setup_position == -1 or setup_run_position == -1:
        errors.append(
            f"{label}: Cargo job must run {setup_run} in a named toolchain setup step"
        )
    elif not (setup_position < setup_run_position < min(cargo_positions)):
        errors.append(f"{label}: toolchain setup must precede every Cargo command")


for relative_path, cargo_jobs in expected_jobs.items():
    path = root / relative_path
    lines = path.read_text().splitlines()
    check_version_authority(relative_path, "\n".join(lines))

    jobs = parse_jobs(lines)

    missing_jobs = sorted(cargo_jobs - jobs.keys())
    if missing_jobs:
        errors.append(f"{relative_path}: missing expected Cargo jobs: {', '.join(missing_jobs)}")
        continue

    for job_name in sorted(cargo_jobs):
        check_setup_precedes_cargo(f"{relative_path}:{job_name}", jobs[job_name])

# ── 委托给 composite action 的 job：job → action 两段接力 ──
referenced_actions: set[str] = set()
for relative_path, mapping in delegated_jobs.items():
    path = root / relative_path
    jobs = parse_jobs(path.read_text().splitlines())
    for job_name, action_dir in sorted(mapping.items()):
        label = f"{relative_path}:{job_name}"
        if job_name not in jobs:
            errors.append(f"{relative_path}: missing expected delegating job: {job_name}")
            continue
        job = jobs[job_name]
        if re.search(r"(?m)^\s*run:\s*cargo\b", job):
            errors.append(
                f"{label}: runs Cargo directly; list it in expected_jobs, not delegated_jobs"
            )
        if f"uses: ./{action_dir}" not in job:
            errors.append(f"{label}: must delegate Cargo work to ./{action_dir}")
        referenced_actions.add(action_dir)

for action_dir in sorted(referenced_actions):
    action_path = root / action_dir / "action.yml"
    if not action_path.is_file():
        errors.append(f"{action_dir}/action.yml: referenced by a job but missing")
        continue
    action_text = action_path.read_text()
    check_version_authority(f"{action_dir}/action.yml", action_text)
    check_setup_precedes_cargo(f"{action_dir}/action.yml", action_text)

if errors:
    raise SystemExit("Rust CI toolchain check failed:\n- " + "\n- ".join(errors))

setup_script = root / "tools/setup-rust-toolchain.sh"
if not setup_script.is_file():
    raise SystemExit("Rust CI toolchain check failed:\n- missing tools/setup-rust-toolchain.sh")

# Counterproof: execute the setup script against two toolchain TOMLs with mocked
# rustup/rustc. If the script hardcodes a version or stops exporting the parsed
# value, either run fails or the observed version does not follow the TOML.
def run_setup(channel: str) -> None:
    with tempfile.TemporaryDirectory() as temporary:
        workdir = pathlib.Path(temporary)
        shutil.copy(toolchain_file, workdir / "rust-toolchain.toml")
        copied = (workdir / "rust-toolchain.toml").read_text()
        (workdir / "rust-toolchain.toml").write_text(
            copied.replace(f'channel = "{pinned}"', f'channel = "{channel}"')
        )
        bin_dir = workdir / "bin"
        bin_dir.mkdir()
        rustup_log = workdir / "rustup.log"
        github_env = workdir / "github.env"
        (bin_dir / "rustup").write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "printf '%s\\n' \"$*\" >> \"${RUSTUP_LOG:?}\"\n"
        )
        (bin_dir / "rustc").write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "printf 'rustc %s (mocked)\\n' \"${RUSTUP_TOOLCHAIN:?}\"\n"
        )
        for executable in bin_dir.iterdir():
            executable.chmod(0o755)
        environment = os.environ | {
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "RUSTUP_LOG": str(rustup_log),
            "GITHUB_ENV": str(github_env),
        }
        subprocess.run([str(setup_script)], cwd=workdir, env=environment, check=True)
        observed = github_env.read_text().splitlines()
        expected_export = f"RUSTUP_TOOLCHAIN={channel}"
        if observed != [expected_export]:
            raise SystemExit(
                f"counterproof failed: expected {expected_export!r}, observed {observed!r}"
            )
        if f"toolchain install {channel}" not in rustup_log.read_text():
            raise SystemExit(f"counterproof failed: rustup did not install TOML channel {channel!r}")

run_setup(pinned)
older = "1.0.0" if pinned != "1.0.0" else "0.99.0"
run_setup(older)
checked = len(expected_jobs) + len(referenced_actions)
print(f"Rust CI toolchain check passed: {checked} units, TOML counterproof {pinned} -> {older}")
PY
