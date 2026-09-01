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
    ".github/workflows/ci-rust.yml": {"fmt", "clippy", "test", "deny"},
    ".github/workflows/ci-desktop.yml": {"desktop"},
    ".github/workflows/e2e.yml": {"e2e", "scenarios"},
    ".github/workflows/release.yml": {"macos-arm64", "windows-x64"},
    ".github/workflows/artifacts.yml": {
        "macos-arm64-bin",
        "linux-bin",
        "windows-x64-bin",
    },
}
setup_name = "- name: Set Rust toolchain from rust-toolchain.toml"
setup_run = "run: tools/setup-rust-toolchain.sh"
errors: list[str] = []

for relative_path, cargo_jobs in expected_jobs.items():
    path = root / relative_path
    lines = path.read_text().splitlines()
    text = "\n".join(lines)

    if "dtolnay/rust-toolchain" in text:
        errors.append(
            f"{relative_path}: dtolnay/rust-toolchain may override rust-toolchain.toml"
        )
    if pinned in text:
        errors.append(
            f"{relative_path}: duplicates pinned Rust version {pinned!r}"
        )

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

    missing_jobs = sorted(cargo_jobs - jobs.keys())
    if missing_jobs:
        errors.append(f"{relative_path}: missing expected Cargo jobs: {', '.join(missing_jobs)}")
        continue

    for job_name in sorted(cargo_jobs):
        job = jobs[job_name]
        cargo_positions = [
            match.start()
            for match in re.finditer(r"(?m)^\s*run:\s*cargo\b", job)
        ]
        if not cargo_positions:
            errors.append(f"{relative_path}:{job_name}: expected a Cargo run command")
            continue
        setup_position = job.find(setup_name)
        setup_run_position = job.find(setup_run)
        if setup_position == -1 or setup_run_position == -1:
            errors.append(
                f"{relative_path}:{job_name}: Cargo job must run {setup_run} in a named toolchain setup step"
            )
        elif not (setup_position < setup_run_position < min(cargo_positions)):
            errors.append(
                f"{relative_path}:{job_name}: toolchain setup must precede every Cargo command"
            )

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
print(f"Rust CI toolchain check passed: {len(expected_jobs)} workflows, TOML counterproof {pinned} -> {older}")
PY
