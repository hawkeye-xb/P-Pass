# P-Pass justfile — single-person project task runner
# Run `just` for a list of available commands.

default:
  @just --list

# ── Setup ───────────────────────────────────────────

# Install toolchain checks + git hooks
setup:
  @echo "==> Checking Rust toolchain..."
  rustup show
  @echo "==> Installing cargo-nextest..."
  cargo install cargo-nextest --locked 2>/dev/null || echo "  (already installed or skipped)"
  @echo "==> Installing cargo-deny..."
  cargo install cargo-deny --locked 2>/dev/null || echo "  (already installed or skipped)"
  @echo "==> Installing just..."
  @echo "  (just is already running this file — you have it! 🎉)"

# ── Format & Lint ───────────────────────────────────

# Format all Rust code
fmt:
  cargo fmt --all -- --check

# Lint all Rust code (clippy with deny warnings)
lint:
  cargo clippy --all-targets --all-features -- -D warnings

# ── Test ────────────────────────────────────────────

# Run all tests (nextest if available, fallback to cargo test)
test:
  cargo nextest run --all-features 2>/dev/null || cargo test --all-features

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
verify-m1:
    cargo nextest run
    tools/dogfood-smoke.sh /tmp/ppf-verify-m1
    cd apps/desktop && npx tauri build --bundles app

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

# Safety integration test; it creates and destroys only a temporary Git repository.
test-cleanup-local:
    bash tools/test-clean-local-builds.sh
