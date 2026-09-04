#!/usr/bin/env bash
# Build the Android-only JNI iroh-blobs provider into Gradle's generated jniLibs.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  printf 'usage: %s <generated-jniLibs-dir>\n' "$0" >&2
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
cargo build -p transport --features android-jni --release --target "$TARGET"

OUT="$1/arm64-v8a"
mkdir -p "$OUT"
cp "target/$TARGET/release/libtransport.so" "$OUT/libtransport.so"
