#!/usr/bin/env bash
# Architecture enforcement script for P-Pass
# Rules:
#   B.1 — `iroh` only in crates/transport/
#   B.2 — platform cfg only in crates/platform/, subject to the exemptions
#         documented in the B.2 block below. Covers #[cfg(...)],
#         #[cfg_attr(...)], and cfg!(...) forms, on every platform axis:
#         unix, windows, linux, macos, target_os, target_family, target_env.
#         Err on the side of false positives; the platform crate is exempt.
set -euo pipefail

FAIL=0
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ── B.1: iroh isolation ─────────────────────────────

echo "==> B.1: iroh import isolation (transport only)"

# Find Rust files outside crates/transport/ that reference 'iroh' as a crate import
# (exclude comments and string literals — just look for `use iroh` or `iroh::` or `extern crate iroh`)
VIOLATIONS_B1=$(grep -rn --include='*.rs' \
  -E '(^use iroh|iroh::|extern crate iroh)' \
  "$ROOT/crates" \
  | grep -v 'crates/transport/' \
  || true)

if [ -n "$VIOLATIONS_B1" ]; then
  echo "❌ B.1 VIOLATION: iroh imports found outside crates/transport/:"
  echo "$VIOLATIONS_B1"
  FAIL=1
else
  echo "   ✅ B.1: clean"
fi

# Also check Cargo.toml dependencies for iroh outside transport
VIOLATIONS_B1_TOML=$(grep -rn --include='Cargo.toml' \
  -E '^iroh' \
  "$ROOT/crates" \
  | grep -v 'crates/transport/' \
  || true)

if [ -n "$VIOLATIONS_B1_TOML" ]; then
  echo "❌ B.1 VIOLATION: iroh dependency in Cargo.toml outside crates/transport/:"
  echo "$VIOLATIONS_B1_TOML"
  FAIL=1
else
  echo "   ✅ B.1 (Cargo.toml): clean"
fi

# ── B.2: platform cfg isolation ─────────────────────

echo "==> B.2: platform #[cfg] / cfg_attr / cfg!() isolation (platform crate only)"

# What counts as a platform cfg (QA-09 #186 ruling): any cfg WE wrote that
# forks behavior per operating system — #[cfg(unix)], #[cfg(not(unix))],
# #[cfg(windows)], #[cfg(target_os = "...")], cfg!(...), and the same
# predicates inside #[cfg_attr(...)]. Framework-provided cross-platform APIs
# never surface here, so they are out of scope by construction.
#
# Scan scope (QA-09 #186 acceptance 4):
#   crates/** — always scanned.
#   apps/**   — scanned. apps/android has no Rust today; the desktop shell's
#               EXISTING forks are grandfathered per-file below (#211).
#   tools/**  — NOT scanned: dev tooling, not the product architecture
#               surface (verified: zero platform-cfg hits in tools/ at
#               main 63fb79e).
#
# Exemptions, in application order:
#   1. crates/platform/ — the rule's home.
#   2. windows_subsystem BY ATTRIBUTE NAME — the linker directive
#      #![cfg_attr(..., windows_subsystem = "windows")] is required by the
#      language at the bin crate root and forks no code path. Only the
#      attribute name is exempt: a cfg_attr carrying any OTHER attribute on
#      a platform predicate still flags. Not file-based, not crate-based.
#   3. Grandfathered existing forks, migration issue #211 (QA-09 #186 Q2/Q3):
#        crates/daemon/src/ipc.rs          (unix socket vs named pipe, disk_stats)
#        crates/daemon/src/log_guard.rs    (truncate_stderr unix/not-unix)
#        crates/daemon/src/main.rs         (identity key 0o600, unix only)
#        apps/desktop/src-tauri/src/lib.rs (19 self-written forks)
#      New platform forks anywhere MUST go through crates/platform/;
#      adding to this list requires an issue decision.
VIOLATIONS_B2=$(grep -rn --include='*.rs' \
  -E '\bcfg(_attr)?\b.*\b(unix|windows|linux|macos|target_os|target_family|target_env)\b' \
  "$ROOT/crates" "$ROOT/apps" \
  | grep -v 'crates/platform/' \
  | grep -v 'windows_subsystem' \
  | grep -vE 'crates/daemon/src/(ipc|log_guard|main)\.rs:' \
  | grep -v 'apps/desktop/src-tauri/src/lib\.rs:' \
  || true)

if [ -n "$VIOLATIONS_B2" ]; then
  echo "❌ B.2 VIOLATION: platform cfg found outside crates/platform/:"
  echo "$VIOLATIONS_B2"
  FAIL=1
else
  echo "   ✅ B.2: clean"
fi

# ── Result ──────────────────────────────────────────

if [ $FAIL -eq 0 ]; then
  echo ""
  echo "✅ arch-check: all architecture rules passed"
  exit 0
else
  echo ""
  echo "❌ arch-check: $FAIL rule(s) violated"
  exit 1
fi
