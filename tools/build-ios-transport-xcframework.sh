#!/usr/bin/env bash
# IOS-06（#313）：把 crates/transport 的 UniFFI 绑定（provider + BLAKE3 + proto 编解码 +
# 最小控制面客户端）打成 iOS 可直接链接的 XCFramework。iOS 侧不自己实现这些。
#
#   tools/build-ios-transport-xcframework.sh [输出目录]     # 默认 apps/ios/build/transport
#
# 产物（都不入库，由本脚本生成）：
#   <输出目录>/TransportFFI.xcframework   ios-arm64 + ios-arm64-simulator 两个切片的静态库，
#                                         Headers 里是 transportFFI.h + module.modulemap
#   <输出目录>/swift/transport.swift       UniFFI 生成的 Swift 绑定（import transportFFI）
#
# 链接方（App target / SwiftPM target）必须额外链接的系统框架：
#   Network.framework（必需：iroh 依赖的 netdev 用 nw_path_* / nw_interface_* 取网关与网卡，
#   不链会报 Undefined symbols _nw_*）、SystemConfiguration、Security。
#   参照 apps/ios/TransportFFITests/Package.swift 的 linkerSettings。
#
# - 最低系统 iOS 16（与 apps/ios/Config/Base.xcconfig 一致），用 IPHONEOS_DEPLOYMENT_TARGET
#   传给 rustc 与 cc，两个切片同一个值。
# - 平台选择只靠 `--features ios-ffi`，crates/ 里不写 target_os（arch-check B.2）。
# - 静态库用 `cargo rustc --crate-type staticlib` 现产，不改 crate-type：桌面与 Android 构建
#   不会因此多编一份静态库。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT="${1:-$ROOT/apps/ios/build/transport}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-16.0}"
export IPHONEOS_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
DEVICE=aarch64-apple-ios
SIM=aarch64-apple-ios-sim

command -v xcodebuild >/dev/null || { echo "error: 缺 xcodebuild（装 Xcode）" >&2; exit 1; }
for t in "$DEVICE" "$SIM"; do
  rustup target list --installed | grep -qx "$t" || {
    echo "error: 缺 Rust target ${t}：rustup target add ${DEVICE} ${SIM}" >&2
    exit 1
  }
done

for t in "$DEVICE" "$SIM"; do
  echo "==> staticlib ${t}（IPHONEOS_DEPLOYMENT_TARGET=${IPHONEOS_DEPLOYMENT_TARGET}）"
  cargo rustc -p transport --lib --features ios-ffi --release --target "$t" --crate-type staticlib
done

DEVICE_LIB="target/$DEVICE/release/libtransport.a"
SIM_LIB="target/$SIM/release/libtransport.a"

echo "==> Swift 绑定（uniffi-bindgen，library 模式读 ${SIM_LIB} 里的元数据）"
GEN="$OUT/gen"
rm -rf "$GEN"
cargo run -q -p transport --features ios-bindgen --bin uniffi-bindgen -- \
  generate --library "$SIM_LIB" --language swift --out-dir "$GEN"

HEADERS="$OUT/headers"
rm -rf "$HEADERS" "$OUT/swift"
mkdir -p "$HEADERS" "$OUT/swift"
cp "$GEN/transportFFI.h" "$HEADERS/"
cp "$GEN/transportFFI.modulemap" "$HEADERS/module.modulemap"
cp "$GEN/transport.swift" "$OUT/swift/"
rm -rf "$GEN"

echo "==> xcodebuild -create-xcframework"
rm -rf "$OUT/TransportFFI.xcframework"
xcodebuild -create-xcframework \
  -library "$DEVICE_LIB" -headers "$HEADERS" \
  -library "$SIM_LIB" -headers "$HEADERS" \
  -output "$OUT/TransportFFI.xcframework"
rm -rf "$HEADERS"

echo "==> 切片核对"
for lib in "$OUT"/TransportFFI.xcframework/*/libtransport.a; do
  printf '%s: ' "${lib#"$OUT"/}"
  lipo -info "$lib"
done
echo "OK: $OUT/TransportFFI.xcframework"
