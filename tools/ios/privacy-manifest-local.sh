#!/usr/bin/env bash
# #937 隐私清单门禁的本地入口（`just ios-test` 在 tools/ios/test.sh 之后调用），与
# ci-ios.yml「Privacy manifest covers required-reason APIs」同一组检查：
#
#   1. --self-test：判据反证，不依赖任何外部工具，每次都跑。
#   2. 扫 test.sh 生成的 libtransport.a（设备切片）的未定义符号。
#
# 第 2 步要能读新版 rustc 目标文件的 llvm-nm（Xcode 自带的 nm 读不了）。查找顺序：
# $LLVM_NM → 当前工具链的 llvm-tools（与 CI 同一个）→ PATH 上的 llvm-nm →
# Homebrew llvm。都找不到就报错退出，不跳过——跳过等于 Rust 侧没人查。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/apps/ios/TransportFFITests/Generated/TransportFFI.xcframework/ios-arm64/libtransport.a"

python3 "$ROOT/tools/ios/check-privacy-manifest.py" --self-test

find_nm() {
  if [ -n "${LLVM_NM:-}" ]; then
    echo "$LLVM_NM"
    return
  fi
  local host sysroot_nm
  host="$(rustc -vV | sed -n 's/^host: //p')"
  sysroot_nm="$(rustc --print sysroot)/lib/rustlib/$host/bin/llvm-nm"
  for nm in "$sysroot_nm" "$(command -v llvm-nm || true)" /opt/homebrew/opt/llvm/bin/llvm-nm; do
    if [ -n "$nm" ] && [ -x "$nm" ]; then
      echo "$nm"
      return
    fi
  done
}

NM="$(find_nm)"
if [ -z "$NM" ] || [ ! -x "$NM" ]; then
  echo "error: 找不到 llvm-nm，libtransport.a 的符号扫描没有执行（隐私清单门禁未完成）。" >&2
  echo "       装与 CI 相同的那个：rustup component add llvm-tools；或用 LLVM_NM=<路径> 指定。" >&2
  exit 1
fi
if [ ! -f "$LIB" ]; then
  echo "error: 缺 ${LIB}——先跑 tools/ios/test.sh（它生成 XCFramework）。" >&2
  exit 1
fi
python3 "$ROOT/tools/ios/check-privacy-manifest.py" --nm "$NM" --lib "$LIB"
