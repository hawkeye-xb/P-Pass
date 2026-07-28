#!/usr/bin/env bash
# Architecture enforcement script for P-Pass
# Rules:
#   B.1 — `iroh` only in crates/transport/
#   B.2 — `cfg` with `windows` or `target_os` only in crates/platform/
#         Covers #[cfg(...)], #[cfg_attr(...)], and cfg!(...) forms.
#         Err on the side of false positives; platform crate is exempt.
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

# Catch three forms of cfg targeting windows or target_os outside platform crate:
#   #[cfg(windows)] / #[cfg(target_os = "...")]
#   #[cfg_attr(..., cfg(windows))] / #[cfg_attr(..., cfg(target_os = "..."))]
#   cfg!(windows) / cfg!(target_os = "...")
VIOLATIONS_B2=$(grep -rn --include='*.rs' \
  -E '\bcfg\b.*\b(windows|target_os)\b' \
  "$ROOT/crates" \
  | grep -v 'crates/platform/' \
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
