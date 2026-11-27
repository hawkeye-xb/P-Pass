#!/usr/bin/env bash
# tools/build-ios-transport-xcframework.sh 的离线行为自测（#2003）：
# 验证按输入树摘要自动跳过/重编、旧产物无摘要自动重编、crates/{transport,proto,pair-pake} 变更触发重编。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/tools/build-ios-transport-xcframework.sh"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-build-ios-ffi.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FAKE="$TMP/repo"
BIN="$TMP/bin"
OUT="$FAKE/apps/ios/TransportFFITests/Generated"
COUNT_FILE="$TMP/cargo_calls"
: >"$COUNT_FILE"

mkdir -p "$FAKE/tools" "$FAKE/crates/transport/src" "$FAKE/crates/proto/src" "$FAKE/crates/pair-pake/src" "$FAKE/third_party/noq-udp/src" "$BIN"
cp "$SCRIPT" "$FAKE/tools/build-ios-transport-xcframework.sh"
chmod +x "$FAKE/tools/build-ios-transport-xcframework.sh"

printf '[workspace]\nmembers = ["crates/transport", "crates/proto", "crates/pair-pake"]\n' >"$FAKE/Cargo.toml"
printf '# lock v1\n' >"$FAKE/Cargo.lock"
printf '[toolchain]\nchannel = "1.86.0"\n' >"$FAKE/rust-toolchain.toml"
printf 'pub fn v() -> u32 { 1 }\n' >"$FAKE/crates/transport/src/lib.rs"
printf 'pub const PROTO: u32 = 1;\n' >"$FAKE/crates/proto/src/lib.rs"
printf 'pub const PAKE: u32 = 1;\n' >"$FAKE/crates/pair-pake/src/lib.rs"
printf 'pub const NOQ: u32 = 1;\n' >"$FAKE/third_party/noq-udp/src/lib.rs"

cat >"$BIN/rustup" <<'SH'
#!/usr/bin/env bash
printf 'aarch64-apple-ios\naarch64-apple-ios-sim\n'
SH

cat >"$BIN/cargo" <<SH
#!/usr/bin/env bash
set -euo pipefail
if [ "\${1:-}" = "rustc" ]; then
  echo rustc >>"$COUNT_FILE"
  target=""
  while [ "\$#" -gt 0 ]; do
    if [ "\$1" = "--target" ]; then target="\$2"; shift 2; else shift; fi
  done
  mkdir -p "\${CARGO_TARGET_DIR}/\$target/release"
  printf 'fake-lib-%s\n' "\$target" >"\${CARGO_TARGET_DIR}/\$target/release/libtransport.a"
elif [ "\${1:-}" = "run" ]; then
  out=""
  while [ "\$#" -gt 0 ]; do
    if [ "\$1" = "--out-dir" ]; then out="\$2"; shift 2; else shift; fi
  done
  mkdir -p "\$out"
  printf '// header\n' >"\$out/transportFFI.h"
  printf 'module transportFFI {}\n' >"\$out/transportFFI.modulemap"
  printf '// swift bindings\n' >"\$out/transport.swift"
fi
SH

cat >"$BIN/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
out=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "-output" ]; then out="$2"; shift 2; else shift; fi
done
mkdir -p "$out/ios-arm64" "$out/ios-arm64-simulator"
printf 'a' >"$out/ios-arm64/libtransport.a"
printf 'a' >"$out/ios-arm64-simulator/libtransport.a"
SH

cat >"$BIN/lipo" <<'SH'
#!/usr/bin/env bash
echo "Non-fat file: $2 is architecture: arm64"
SH

chmod +x "$BIN/rustup" "$BIN/cargo" "$BIN/xcodebuild" "$BIN/lipo"

calls() {
  wc -l <"$COUNT_FILE" | tr -d '[:space:]'
}

run_build() {
  PATH="$BIN:$PATH" CARGO_TARGET_DIR="$TMP/target" \
    "$FAKE/tools/build-ios-transport-xcframework.sh" "$OUT"
}

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. 首次构建应执行 cargo rustc（device + sim = 2 次）并写摘要
run_build >/dev/null
[ "$(calls)" = "2" ] || fail "首次构建应调 2 次 cargo rustc，实际 $(calls)"
[ -f "$OUT/.transport-ffi.sha256" ] || fail "首次构建后缺少 .transport-ffi.sha256"

# 2. 输入未变时再次运行应秒级跳过，不再调用 cargo
run_build | grep -q "跳过重编" || fail "输入未变时应跳过重编"
[ "$(calls)" = "2" ] || fail "输入未变时不应重编，实际 cargo 次数 $(calls)"

# 3. 修改 crates/transport 源码后不删目录直接运行，应自动重编
printf 'pub fn v() -> u32 { 2 }\n' >"$FAKE/crates/transport/src/lib.rs"
run_build >/dev/null
[ "$(calls)" = "4" ] || fail "修改 crates/transport 后应重编，实际 $(calls)"

# 4. 修改 crates/proto、crates/pair-pake 与 third_party/noq-udp 也应自动重编
printf 'pub const PROTO: u32 = 2;\n' >"$FAKE/crates/proto/src/lib.rs"
run_build >/dev/null
[ "$(calls)" = "6" ] || fail "修改 crates/proto 后应重编，实际 $(calls)"

printf 'pub const PAKE: u32 = 2;\n' >"$FAKE/crates/pair-pake/src/lib.rs"
run_build >/dev/null
[ "$(calls)" = "8" ] || fail "修改 crates/pair-pake 后应重编，实际 $(calls)"

fp_before="$("$FAKE/tools/build-ios-transport-xcframework.sh" --print-fingerprint)"
printf 'pub const NOQ: u32 = 2;\n' >"$FAKE/third_party/noq-udp/src/lib.rs"
fp_after="$("$FAKE/tools/build-ios-transport-xcframework.sh" --print-fingerprint)"
[ "$fp_before" != "$fp_after" ] || fail "修改 third_party/noq-udp 后 --print-fingerprint 未变化"
run_build >/dev/null
[ "$(calls)" = "10" ] || fail "修改 third_party/noq-udp 后应重编，实际 $(calls)"

# 5. 复用历史产物（目录在但无 .transport-ffi.sha256）应自动重编
rm -f "$OUT/.transport-ffi.sha256"
run_build >/dev/null
[ "$(calls)" = "12" ] || fail "历史产物缺摘要时应自动重编，实际 $(calls)"

# 6. PPASS_FORCE_REBUILD_FFI=1 强制重编
PPASS_FORCE_REBUILD_FFI=1 run_build >/dev/null
[ "$(calls)" = "14" ] || fail "PPASS_FORCE_REBUILD_FFI=1 应强制重编，实际 $(calls)"

echo "PASS: tools/test-build-ios-transport-xcframework.sh（7/7 断言通过）"
