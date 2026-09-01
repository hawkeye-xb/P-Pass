#!/usr/bin/env bash
# Install the Rust version selected by rust-toolchain.toml for a CI job.
set -euo pipefail

rust_toolchain_file=${RUST_TOOLCHAIN_FILE:-rust-toolchain.toml}
pinned=$(awk -F '"' '/^[[:space:]]*channel[[:space:]]*=/ { print $2; exit }' "$rust_toolchain_file")

if [[ -z "$pinned" ]]; then
  echo "missing [toolchain].channel in $rust_toolchain_file" >&2
  exit 1
fi

rustup toolchain install "$pinned" --profile minimal --component rustfmt --component clippy
export RUSTUP_TOOLCHAIN="$pinned"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'RUSTUP_TOOLCHAIN=%s\n' "$pinned" >> "$GITHUB_ENV"
fi

actual=$(rustc --version | awk '{ print $2 }')
if [[ "$actual" != "$pinned" ]]; then
  echo "rustc version $actual does not match $rust_toolchain_file channel $pinned" >&2
  exit 1
fi

rustc --version
