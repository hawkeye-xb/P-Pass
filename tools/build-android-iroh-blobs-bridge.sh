#!/usr/bin/env bash
# Build Android's libtransport.so into Gradle's generated jniLibs: the uniffi exports shared
# with iOS (mobile-ffi: control-plane client, original fetch, close codes (#1124), and the
# iroh-blobs upload provider (#1126, the hand-written JNI is gone)). With a second argument,
# also generate the Kotlin bindings for those exports into that directory.
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  printf 'usage: %s <generated-jniLibs-dir> [<generated-kotlin-dir>]\n' "$0" >&2
  exit 64
fi

: "${ANDROID_NDK_HOME:?ANDROID_NDK_HOME must point at an Android NDK}"

# Windows 宿主（Git Bash）：NDK 路径与 Gradle 传来的输出目录是 `C:\...` 形式，bash 的
# 通配与测试要 `/c/...`；交给 cargo / clang 这类原生程序的路径则用 `C:/...`。
# NDK 的 Windows 版编译器是 `<triple><api>-clang.cmd`（Linux / macOS 版没有后缀）。
if command -v cygpath >/dev/null 2>&1; then
  to_shell() { cygpath -u "$1"; }
  to_native() { cygpath -m "$1"; }
  EXE_SUFFIXES=".cmd .exe"
else
  to_shell() { printf '%s' "$1"; }
  to_native() { printf '%s' "$1"; }
  EXE_SUFFIXES=""
fi
NDK="$(to_shell "$ANDROID_NDK_HOME")"
JNI_OUT="$(to_shell "$1")"

TARGET=aarch64-linux-android
API=26
CLANG=
AR=
for candidate in "$NDK"/toolchains/llvm/prebuilt/*; do
  for suffix in "" $EXE_SUFFIXES; do
    if [ -x "$candidate/bin/${TARGET}${API}-clang$suffix" ]; then
      CLANG="$candidate/bin/${TARGET}${API}-clang$suffix"
      break 2
    fi
  done
done
if [ -z "$CLANG" ]; then
  printf 'Android NDK clang not found: %s/toolchains/llvm/prebuilt/*/bin/%s%s-clang\n' "$NDK" "$TARGET" "$API" >&2
  exit 1
fi
for suffix in "" $EXE_SUFFIXES; do
  if [ -x "$(dirname "$CLANG")/llvm-ar$suffix" ]; then
    AR="$(dirname "$CLANG")/llvm-ar$suffix"
    break
  fi
done
if [ -z "$AR" ]; then
  printf 'Android NDK llvm-ar not found next to %s\n' "$CLANG" >&2
  exit 1
fi

CLANG="$(to_native "$CLANG")"
AR="$(to_native "$AR")"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$CLANG"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_AR="$AR"
export CC_aarch64_linux_android="$CLANG"
export AR_aarch64_linux_android="$AR"
cargo build -p transport --features mobile-ffi --release --target "$TARGET"

SO="$(to_shell "${CARGO_TARGET_DIR:-target}")/$TARGET/release/libtransport.so"
OUT="$JNI_OUT/arm64-v8a"
mkdir -p "$OUT"
cp "$SO" "$OUT/libtransport.so"

if [ "$#" -eq 2 ]; then
  # Kotlin 绑定：library 模式读 .so 里的 uniffi 元数据（与 iOS 读静态库同一做法），
  # 包名与库名见 crates/transport/uniffi.toml。生成器是宿主机工具，不带 Android 交叉编译环境，
  # 也不编 mobile-ffi（见 transport 的 mobile-bindgen feature），所以 Windows 宿主同样能跑。
  KOTLIN_OUT="$(to_shell "$2")"
  rm -rf "$KOTLIN_OUT"
  mkdir -p "$KOTLIN_OUT"
  env -u CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER -u CC_aarch64_linux_android \
    cargo run -q -p transport --features mobile-bindgen --bin uniffi-bindgen -- \
    generate --library "$(to_native "$SO")" --language kotlin --no-format --out-dir "$(to_native "$KOTLIN_OUT")"
fi
