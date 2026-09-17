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

# docs/QUEUE.md must stay in sync with cards/ (no missing/dangling entries)
# 第二行是 3/3 归档出口门禁的反证（证明它不是恒真式），跟门禁同生共死
queue-check:
  @./tools/check-queue-sync.sh
  @./tools/test-queue-archive-gate.sh

# Markdown tables in docs/ and cards/ must not be split by a stray blank line
md-check:
  @python3 ./tools/check-markdown-tables.py

# DESK-15: assets/design/tokens.css must not drift from tokens.json
token-check:
  @python3 ./tools/check-token-drift.py

# ── Development ─────────────────────────────────────

# Start daemon in development mode
dev-daemon:
  cargo run -p daemon

# ── CI ──────────────────────────────────────────────

# Full CI pipeline (same as GitHub Actions pr.yml)
ci: fmt lint test arch-check queue-check md-check token-check
  @echo "==> CI pipeline: all green ✅"

# QA-03 文档快车道：只跑文档域的门禁，不编 Rust。
#
# 为什么要这条：`ci` 里的 fmt/lint/test 是全量 Rust 构建 + clippy + nextest，
# 而改一个字的卡也要跑一遍——远端 CI 反倒早就按 paths 分好了 lane
# （纯文档提交只点起 ci-docs）。本地缺的就是同一件事。
#
# ⚠️ 只在这次改动**一行 Rust/Kotlin/前端都没动**时用它。碰了代码就跑 `just ci`，
# 别拿这条快车道当省事的借口——`ci` 的依赖列表一个都没减。
ci-docs: queue-check md-check token-check
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
    cd apps/android && JAVA_HOME=$(brew --prefix openjdk 2>/dev/null || echo "$JAVA_HOME") ./gradlew -q :app:testDebugUnitTest

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
    cargo nextest run
    cd apps/android && JAVA_HOME=$(brew --prefix openjdk) ./gradlew -q :app:testDebugUnitTest :app:assembleDebug
    tools/android-hello.sh
    tools/android-pair.sh
    tools/android-backup.sh

# Local disk recovery. No arguments only previews; deletion needs --apply plus a scope.
cleanup-local *args:
    bash tools/clean-local-builds.sh {{args}}

# Safety integration test; it creates and destroys only a temporary Git repository.
test-cleanup-local:
    bash tools/test-clean-local-builds.sh
