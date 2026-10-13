#!/usr/bin/env bash
# iOS 本地开发环境自检（#310）：只检查、不安装、不改任何东西。
#
#   tools/ios/env-check.sh
#
# 逐项打印 OK / 缺（附怎么装）。必需项缺任何一个退出 1；可选项（真机、e2e、TestFlight）只提示。
# 依赖清单来自仓库脚本的实际调用：tools/ios/test.sh、test-packages.sh、test-transport-ffi.sh、e2e-sim.sh、
# e2e-device.sh、build-ios-transport-xcframework.sh；完整说明见 docs/ios-dev-setup.md。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
missing=0
opt_missing=0

ok() { printf '  OK    %s\n' "$1"; }
miss() { printf '  缺    %s  → %s\n' "$1" "$2"; missing=$((missing + 1)); }
optmiss() { printf '  可选缺 %s  → %s\n' "$1" "$2"; opt_missing=$((opt_missing + 1)); }
need() { # <命令> <安装提示>
  if command -v "$1" >/dev/null 2>&1; then ok "$1（$(command -v "$1")）"; else miss "$1" "$2"; fi
}
want() { # <命令> <用途与安装提示>
  if command -v "$1" >/dev/null 2>&1; then ok "$1"; else optmiss "$1" "$2"; fi
}

echo "== 系统与 Xcode"
if [ "$(uname -s)" = Darwin ]; then ok "macOS $(sw_vers -productVersion)（$(uname -m)）"; else miss "macOS" "iOS 构建只能在 macOS 上做"; fi
if command -v xcodebuild >/dev/null 2>&1 && XB=$(xcodebuild -version 2>/dev/null); then
  ok "$(echo "$XB" | tr '\n' ' ')"
  major=$(echo "$XB" | sed -n 's/^Xcode \([0-9]*\).*/\1/p')
  [ "${major:-0}" -ge 26 ] 2>/dev/null || printf '  提示  CI 用 Xcode 26（macos-26 镜像）；当前 %s，较旧版本未验证\n' "${major:-?}"
else
  miss "Xcode（xcodebuild 不可用）" "App Store 装 Xcode，并 sudo xcode-select -s /Applications/Xcode.app（或在 Xcode Settings → Locations 选）"
fi
if xcrun simctl list runtimes available 2>/dev/null | grep -q '^iOS'; then
  ok "iOS 模拟器 runtime：$(xcrun simctl list runtimes available | grep '^iOS' | awk '{print $2}' | tr '\n' ' ')"
else
  miss "iOS 模拟器 runtime" "Xcode Settings → Components 下载 iOS 模拟器"
fi

echo "== 构建工具"
need xcodegen "brew install xcodegen（CI 钉 2.45.3，见 .github/actions/ios-testflight）"
need jq "brew install jq"
need just "brew install just（也可直接跑 tools/ios/*.sh，不装 just 不影响）"
need python3 "macOS 自带或 brew install python"

echo "== Rust（传输 XCFramework 要编两个 iOS 切片）"
if command -v rustup >/dev/null 2>&1; then
  ok "rustup"
  inst=$(rustup target list --installed 2>/dev/null)
  for t in aarch64-apple-ios aarch64-apple-ios-sim; do
    if echo "$inst" | grep -qx "$t"; then ok "target $t"; else miss "target $t" "rustup target add aarch64-apple-ios aarch64-apple-ios-sim"; fi
  done
  want_ch=$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$ROOT/rust-toolchain.toml" | head -1)
  printf '  提示  仓库钉的工具链 %s（rust-toolchain.toml，进仓库目录 rustup 自动装）\n' "${want_ch:-?}"
else
  miss "rustup" "https://rustup.rs 安装（不要用 brew 的 rust，装不了 iOS target）"
fi
need cargo "随 rustup 安装"

echo "== 本机 daemon 与端到端（tools/ios/test-transport-ffi.sh、e2e-sim.sh 要起隔离 daemon）"
if command -v brew >/dev/null 2>&1 && brew --prefix libheif >/dev/null 2>&1 && [ -d "$(brew --prefix libheif 2>/dev/null)" ]; then
  ok "libheif（brew）"
else
  miss "libheif" "brew install libheif（daemon 的 media-codec 依赖的系统库）"
fi
for t in ffmpeg sips sqlite3 lsof; do
  case "$t" in
    ffmpeg) want ffmpeg "e2e-sim.sh 与 PPassMedia 集成测试现造素材用：brew install ffmpeg" ;;
    sips) want sips "macOS 自带（现造 HEIC 素材）" ;;
    sqlite3) want sqlite3 "macOS 自带（e2e 读模拟器 TCC / daemon 库）" ;;
    lsof) want lsof "macOS 自带（e2e 找 daemon 端口）" ;;
  esac
done

echo "== 真机与发布（可选）"
if xcrun devicectl list devices 2>/dev/null | grep -qE 'available|connected'; then
  ok "有可用真机（xcrun devicectl list devices）"
else
  optmiss "已连接并配对的真机" "只在跑真机 e2e / 装机时需要；见 docs/ios-dev-setup.md「真机」"
fi
TEAM=$(sed -n 's/.*DEVELOPMENT_TEAM\[sdk=iphoneos\*\]: *\([A-Z0-9]*\).*/\1/p' "$ROOT/apps/ios/project.yml" | head -1)
printf '  提示  真机签名团队 %s：需被邀请进该团队，并在 Xcode Settings → Accounts 登录对应 Apple ID（脚本读不到登录态，无法检查）\n' "$TEAM"
[ -d "$ROOT/apps/ios/TransportFFITests/Generated/TransportFFI.xcframework" ] \
  && ok "传输 XCFramework 已生成" \
  || printf '  提示  传输 XCFramework 还没生成（tools/ios/test.sh 会自动生成，首次约十分钟；不是缺陷）\n'

echo
if [ "$missing" -eq 0 ]; then
  echo "必需项齐全（可选项缺 ${opt_missing} 个）。下一步：tools/ios/test.sh"
else
  echo "必需项缺 ${missing} 个，先补齐再跑 tools/ios/test.sh。"
  exit 1
fi
