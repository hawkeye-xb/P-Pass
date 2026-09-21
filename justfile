# P-Pass justfile — single-person project task runner
# Run `just` for a list of available commands.

# QA-08：Windows 上 just 默认去找 POSIX `sh`，而 Git for Windows 只把 Git 的
# cmd 目录放进 PATH —— sh.exe / bash.exe 在它的 bin 目录里，默认不在 PATH 上。
# 于是在 PowerShell 里任何一条配方都以 "could not find the shell sh" 失败，
# 而那句话指向「shell 找不到」，第一反应会是仓库坏了。
#
# 改用 bash：本仓的配方本来就是 POSIX 写的，而且已有配方直接调 bash
# （cleanup-local），所以「要求 bash 可用」是既成事实、不是新约束。只要
# bash 在 PATH 上，PowerShell 里也能直接跑 just。bash 不在 PATH 时仍会失败，
# 但 tools/windows/env-check.ps1 会明确报出来并给出修法（见 #179）。
#
# 只影响 Windows：其余平台仍用 just 默认的 `sh -cu`。
set windows-shell := ["bash", "-cu"]

default:
  @just --list

# ── Setup ───────────────────────────────────────────

# Install toolchain checks + git hooks.
#
# 工具链部分：rustup 钉的 toolchain（见 rust-toolchain.toml）+ cargo-nextest
# / cargo-deny。git hooks 部分：用 pre-commit 把仓内 .pre-commit-config.yaml
# 的门禁（当前是 gitleaks）装进 .git/hooks/pre-commit。
#
# QA-10：pre-commit 可执行文件不一定在 PATH 上（比如装在用户级 Python 的
# Scripts 目录），PATH 上那个还可能是坏的（装了包但环境坏了）。所以按
# pre-commit（要求存在且 --version 能跑通）→ python3 -m pre_commit →
# python -m pre_commit 的顺序探测，三者皆不可用就报错退出——装不上不许
# 静默跳过。
# gitleaks 是 language: system 的本机可执行文件，必须在 PATH 上 hook 才跑
# 得动；它缺了不挡 hook 安装，但会让每次提交都硬失败，所以装完 hook 后单独
# loud-check 一次，缺了打 WARNING 并给出安装指引。
setup:
  @echo "==> Checking Rust toolchain..."
  rustup show
  @echo "==> Installing cargo-nextest..."
  cargo install cargo-nextest --locked 2>/dev/null || echo "  (already installed or skipped)"
  @echo "==> Installing cargo-deny..."
  cargo install cargo-deny --locked 2>/dev/null || echo "  (already installed or skipped)"
  @echo "==> Installing just..."
  @echo "  (just is already running this file — you have it! 🎉)"
  @echo "==> Installing git hooks (pre-commit)..."
  @if command -v pre-commit >/dev/null 2>&1 && pre-commit --version >/dev/null 2>&1; then \
    pre-commit install; \
  elif python3 -m pre_commit --version >/dev/null 2>&1; then \
    python3 -m pre_commit install; \
  elif python -m pre_commit --version >/dev/null 2>&1; then \
    python -m pre_commit install; \
  else \
    echo "ERROR: pre-commit not found — git hooks were NOT installed." >&2; \
    echo "  Tried: pre-commit on PATH (exists AND --version works), python3 -m pre_commit, python -m pre_commit." >&2; \
    echo "  Fix: pip install pre-commit   then re-run: just setup" >&2; \
    exit 1; \
  fi
  @if command -v gitleaks >/dev/null 2>&1; then \
    echo "  gitleaks found in PATH ($(command -v gitleaks))"; \
  else \
    echo "WARNING: gitleaks not found in PATH." >&2; \
    echo "  The installed hook (gitleaks protect --staged) will FAIL on every commit." >&2; \
    echo "  Install it: https://github.com/gitleaks/gitleaks#installing" >&2; \
  fi

# ── Format & Lint ───────────────────────────────────

# Format all Rust code
fmt:
  cargo fmt --all -- --check

# Lint all Rust code (clippy with deny warnings)
#
# BUILD-06: 刻意**不用** `--all-features`。本仓只有两个 feature，两个都是特殊
# 构建模式，不该被默认打开：
#   - `transport/android-jni` —— 只给 Android 桥用（全仓唯一启用处是
#     tools/build-android-iroh-blobs-bridge.sh）。它的代码用 `std::os::fd`，
#     在 Windows 上直接编不过（E0432/E0599）⇒ `--all-features` 等于把这个
#     刻意做出来的平台闸门又强行打开。Android 那条路径见下方 lint-android。
#   - `media-codec/vendored` —— 从源码编 libheif。该 crate 自己的注释就写着
#     「Default stays on the system library for fast dev/CI builds」。
# 远端 ci-rust.yml 仍用 `--all-features`（Linux 上两者都编得过），所以覆盖没丢；
# 本地这条的目标是三个平台都能真的跑起来。
lint:
  cargo clippy --all-targets -- -D warnings

# BUILD-06: android-jni 的专项 lint。**只能在 unix 上跑**——该 feature 的代码
# 用 `std::os::fd`，Windows 上必然 E0432。所以刻意没挂进 `ci`：挂进去等于让
# Windows 的 `just ci` 永远红。
lint-android:
  cargo clippy -p transport --all-targets --features android-jni -- -D warnings

# ── Test ────────────────────────────────────────────

# Run all tests (nextest if available, fallback to cargo test)
# BUILD-06: 同 lint，不用 `--all-features`（否则 Windows 上连编译都过不去）。
#
# QA-11：nextest 在的时候输出一眼不吞——它的进度、失败清单、超时报告全走
# stderr，`2>/dev/null` 会一并扔掉——退出码如实透传，失败绝不退化成
# `cargo test` 全量重跑（cargo test 没有单测超时，挂着不动的测试能让配方
# 永不返回）。「nextest 没装」和「测试失败」分两路：没装才退回 cargo test
# 并明说；在但坏了（--version 跑不通，QA-10 实测过这种活死 shim）按没装处理。
test:
  @if command -v cargo-nextest >/dev/null 2>&1 && cargo-nextest --version >/dev/null 2>&1; then \
    cargo nextest run; \
  else \
    echo "cargo-nextest not found or not runnable — falling back to 'cargo test' (no per-test timeout)." >&2; \
    echo "Install nextest for the real gate: just setup   (or: cargo install cargo-nextest --locked)" >&2; \
    cargo test; \
  fi

# T-070 故障剧本（进程级三件套：4GB 大文件 / 崩溃恢复 / 磁盘满）
# 需要 release 二进制: cargo build --release -p daemon -p testclient
scenarios:
  bash tools/scenarios/huge_file.sh
  bash tools/scenarios/crash_recovery.sh
  bash tools/scenarios/disk_full.sh

# ── Code Generation ─────────────────────────────────

# Generate code: proto → Kotlin types + schema snapshot
gen:
  @echo "==> gen: placeholder (T-002 will implement proto → Kotlin generation)"
  @echo "    For now: no generated code needed."

# ── Architecture Enforcement ────────────────────────

# Architecture check: enforce isolation rules
arch-check:
  @./tools/arch-check.sh

# Markdown tables in docs/ and cards/ must not be split by a stray blank line
#
# QA-07: 解释器不能硬写 `python3`。Windows 上 `python3` 常解析到 Microsoft Store
# 的应用执行别名占位程序——它**存在于 PATH**、但零输出、非零退出（本机实测
# exit 49），所以 `command -v python3` 这类探测会被它骗过，必须真跑一次才判得出
# 活死。反过来也不能一律改写成 `python`：Debian 系只保证有 `python3`。
# 故：依次试 python3 / python / py，第一个能自报 major == 3 的胜出。
#
# 用 shebang 配方是刻意的——它绕开 just 的 shell 设置，将来若为 Windows 配上
# `set windows-shell`（QA-08）这两条不会跟着坏。
md-check:
  #!/usr/bin/env bash
  set -euo pipefail
  for py in python3 python py; do
    if "$py" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
      exec "$py" ./tools/check-markdown-tables.py
    fi
  done
  echo "md-check: 找不到可用的 Python 3（试过 python3 / python / py）" >&2
  exit 1

# DESK-15: assets/design/tokens.css must not drift from tokens.json
# 解释器探测同 md-check（理由见上方 QA-07 注释）。
token-check:
  #!/usr/bin/env bash
  set -euo pipefail
  for py in python3 python py; do
    if "$py" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then
      exec "$py" ./tools/check-token-drift.py
    fi
  done
  echo "token-check: 找不到可用的 Python 3（试过 python3 / python / py）" >&2
  exit 1

# SITE-04: site 有自己一套生成物（tokens.css / icons），由 site/scripts/*.mjs
# 从 assets/design/ 生成，**不在 token-check 的覆盖范围内**——后者只比数值，
# 而 site 的生成器连文案一起嵌进产物。漏掉的后果实测过：一次只改文案的提交
# 让 site lane 红了 6 天没人发现。
#
# 需要 site/node_modules 就位，所以刻意**没有**挂进 ci / ci-docs（见 SITE-04
# 卡的留白）。动了 assets/design/ 或 site/ 就手动跑一次。
site-check:
  @cd site && npm run tokens:check && npm run icons:check

# SEC-02: 提交身份必须在 .github/allowed-identities.txt 白名单内。
# 第二行是反证（证明门禁在该红时真的红），跟门禁同生共死。
# 本地跑的是 origin/main..HEAD；远端 ci-identity.yml 按 PR/push 各自算区间。
identity-check:
  @./tools/test-commit-identity-gate.sh
  @./tools/check-commit-identity.sh

# ── Development ─────────────────────────────────────

# Start daemon in development mode
dev-daemon:
  cargo run -p daemon

# ── CI ──────────────────────────────────────────────

# Full CI pipeline (same as GitHub Actions pr.yml)
ci: fmt lint test arch-check md-check token-check identity-check
  @echo "==> CI pipeline: all green ✅"

# QA-03 文档快车道：只跑文档域的门禁，不编 Rust。
#
# 为什么要这条：`ci` 里的 fmt/lint/test 是全量 Rust 构建 + clippy + nextest，
# 而改一个字的卡也要跑一遍——远端 CI 反倒早就按 paths 分好了 lane
# （纯文档提交只点起 ci-docs）。本地缺的就是同一件事。
#
# ⚠️ 只在这次改动**一行 Rust/Kotlin/前端都没动**时用它。碰了代码就跑 `just ci`，
# 别拿这条快车道当省事的借口——`ci` 的依赖列表一个都没减。
ci-docs: md-check token-check identity-check
  @echo "==> docs lane: green ✅（注意：本条不含 fmt/lint/test，动了代码必须跑 just ci）"

# T-040 人工验收：自启/防睡眠/密钥仓 真机冒烟（H-09 双平台各跑一次）
platform-smoke:
    cargo run -p platform --example smoke

# T-041 桌面壳开发模式（Tauri dev = 前端热更 + 托盘）
dev-desktop:
    cd apps/desktop && npx tauri dev

# M1 总验收（手册 E 表）：全仓测试 + 接口全剧本 + 桌面产物
#
# BUILD-09：这里以前直接 `npx tauri build --bundles app`，出来的 .app 缺
# Contents/MacOS/lib —— daemon 的 rpath 是 @executable_path/lib，Tauri 的
# externalBin 只搬那一个二进制，不搬它旁边那包 dylib。构建全绿、装上才炸。
# 正确链路只有一条（release.yml 一直走的那条），现在本地也走它，而且
# bundle-desktop-macos.sh 第 5b 步会真的跑一遍 sidecar 才放行。
# 本地 ad-hoc 身份默认不出 dmg（BUILD-05 定调），要 dmg 设 PPF_BUNDLE_DMG=1。
verify-m1:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ justfile_directory() }}"
    cargo nextest run
    tools/dogfood-smoke.sh /tmp/ppf-verify-m1
    cargo build --release -p daemon -p testclient
    rm -rf /tmp/ppf-rel && mkdir -p /tmp/ppf-rel
    tools/bundle-macos.sh /tmp/ppf-rel target/release/daemon target/release/testclient
    tools/bundle-desktop-macos.sh /tmp/ppf-rel /tmp/ppf-rel

# Android unit tests (proto golden drift check included)
android-test:
    #!/usr/bin/env bash
    set -euo pipefail
    source "{{ justfile_directory() }}/scripts/java-home.sh"
    cd "{{ justfile_directory() }}/apps/android"
    ./gradlew -q :app:testDebugUnitTest

# T-051 live check: Kotlin iroh-ffi client speaks hello to a real daemon
android-hello:
  tools/android-hello.sh

# T-052 live check: full pairing flow (Kotlin phone + IPC owner confirm)
android-pair:
  tools/android-pair.sh

# T-054 live check: full phone backup pipeline vs a real daemon
android-backup:
  tools/android-backup.sh

# M2 total acceptance: Rust suite + Android suite + APK build +
# live wire scripts (hello/pair/backup) against a throwaway daemon
verify-m2:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ justfile_directory() }}"
    cargo nextest run
    source scripts/java-home.sh
    cd apps/android
    ./gradlew -q :app:testDebugUnitTest :app:assembleDebug
    cd ..
    tools/android-hello.sh
    tools/android-pair.sh
    tools/android-backup.sh

# Local disk recovery. No arguments only previews; deletion needs --apply plus a scope.
cleanup-local *args:
    bash tools/clean-local-builds.sh {{args}}

# QA-13: fetch + automatic reclamation, the moment the info is freshest.
# GitHub deletes a PR's head branch on merge, so right after --prune the
# merged-and-done worktrees are exactly the ones whose upstream vanished;
# removal still passes every existing guard (current worktree / uncommitted
# changes / not-merged / active build / fail-closed probe). Local-only by
# construction: fetch is read-only, deletion touches local dirs only.
# Scope note: `--worktrees`, not `--all` — auto-deleting the CURRENT
# worktree's target/ would force a full rebuild on every pull; cache
# reclamation for kept worktrees stays manual (`just cleanup-local
# --apply --targets`), which is a deliberate cost choice, not an oversight.
sync:
    git fetch --prune origin
    bash tools/clean-local-builds.sh --apply --worktrees

# Safety integration test; it creates and destroys only a temporary Git repository.
test-cleanup-local:
    bash tools/test-clean-local-builds.sh
