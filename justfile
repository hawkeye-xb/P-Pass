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

# ── Code Generation ─────────────────────────────────

# Generate code: proto → Kotlin types + schema snapshot
gen:
  @echo "==> gen: placeholder (T-002 will implement proto → Kotlin generation)"
  @echo "    For now: no generated code needed."

# ── Architecture Enforcement ────────────────────────

# Architecture check: enforce isolation rules
arch-check:
  @./tools/arch-check.sh

# ── Development ─────────────────────────────────────

# Start daemon in development mode
dev-daemon:
  cargo run -p daemon

# ── CI ──────────────────────────────────────────────

# Full CI pipeline (same as GitHub Actions pr.yml)
ci: fmt lint test arch-check
  @echo "==> CI pipeline: all green ✅"

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
