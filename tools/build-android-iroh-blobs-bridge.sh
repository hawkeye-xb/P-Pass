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
TARGET=aarch64-linux-android
API=26
TOOLCHAIN_ROOT=
for candidate in "$ANDROID_NDK_HOME"/toolchains/llvm/prebuilt/*; do
  if [ -x "$candidate/bin/${TARGET}${API}-clang" ]; then
    TOOLCHAIN_ROOT="$candidate"
    break
  fi
done
CLANG="$TOOLCHAIN_ROOT/bin/${TARGET}${API}-clang"
if [ ! -x "$CLANG" ]; then
  printf 'Android NDK clang not found: %s\n' "$CLANG" >&2
  exit 1
fi

export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$CLANG"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_AR="$TOOLCHAIN_ROOT/bin/llvm-ar"
export CC_aarch64_linux_android="$CLANG"
export AR_aarch64_linux_android="$TOOLCHAIN_ROOT/bin/llvm-ar"
cargo build -p transport --features mobile-ffi --release --target "$TARGET"

SO="${CARGO_TARGET_DIR:-target}/$TARGET/release/libtransport.so"
OUT="$1/arm64-v8a"
mkdir -p "$OUT"
cp "$SO" "$OUT/libtransport.so"

if [ "$#" -eq 2 ]; then
  # Kotlin 绑定：library 模式读 .so 里的 uniffi 元数据（与 iOS 读静态库同一做法），
  # 包名与库名见 crates/transport/uniffi.toml。生成器是宿主机工具，不带 Android 交叉编译环境。
  KOTLIN_OUT="$2"
  rm -rf "$KOTLIN_OUT"
  mkdir -p "$KOTLIN_OUT"
  env -u CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER -u CC_aarch64_linux_android \
    cargo run -q -p transport --features mobile-bindgen --bin uniffi-bindgen -- \
    generate --library "$SO" --language kotlin --no-format --out-dir "$KOTLIN_OUT"
fi
