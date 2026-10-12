#!/usr/bin/env bash
# REL-12（#711）：release.yml · finalize-manifest ·「Compose desktop manifest (android + darwin)」。
# 原样抽自 workflow 内嵌 bash；release.yml 只调用本脚本。
#
# 输入（显式）：
#   TAG          本次发布的 tag（job env）
#   RELEASE_TAG  tools/release-version.sh 判 test / 正式线用（workflow 顶层 env）
#   PLATFORMS    dispatch 选的平台集合（workflow 顶层 env；tag push 恒 all）
#   MACOS_PLAN   plan-builds 对桌面端的判定（build|reuse|skip；#852：test tag 上没改动的桌面端
#                判 skip，这次本就不该有 mac 产物）
#   artifacts/android/P-Pass_*_android*.apk、artifacts/macos-arm64/P-Pass_*_macos-arm64.app.tar.gz
# 输出：
#   artifacts/manifest.json          正式 tag = 冻结件原样拷贝；test tag = 动态清单
#   artifacts/manifest-android.json  有 APK 时重组（与 upload-android 同口径）
#   artifacts/manifest-macos.json    有 mac 产物时
#   本该有 macOS 产物却没有 ⇒ ::error:: 并退出 1。
set -euo pipefail
: "${TAG:?TAG 未设置（job env）}"
: "${RELEASE_TAG:?RELEASE_TAG 未设置（workflow 顶层 env）}"
: "${PLATFORMS?PLATFORMS 未设置（workflow 顶层 env）}"
: "${MACOS_PLAN?MACOS_PLAN 未设置（finalize-manifest 步骤 env = needs.plan-builds.outputs.macos）}"
cd "$(dirname "$0")/../.."

ARGS=()
# UPD-15：产物名带该端版本号，用 glob 定位
# #852：目录可能不在——test tag 上没改动的一端不构建，它的 artifact 下载步骤被跳过。find 失败在
# pipefail 下会杀掉整步，这里按「没有这一端」处理（同 sign-desktop.sh）；该不该有，由下面的
# mac 门禁按 plan-builds 的判定判。
APK_PATH=$(find artifacts/android -maxdepth 1 -name 'P-Pass_*_android*.apk' 2>/dev/null | head -1 || true)
MAC_UPD=$(find artifacts/macos-arm64 -maxdepth 1 -name 'P-Pass_*_macos-arm64.app.tar.gz' 2>/dev/null | head -1 || true)
[ -n "$APK_PATH" ] && ARGS+=(--asset android-arm64="$APK_PATH")
[ -n "$MAC_UPD" ] && ARGS+=(--asset darwin-aarch64="$MAC_UPD")
# manifest 恒指 GitHub 直链（2026-08-25 撤 R2 镜像的拍板）：下面几条
# 分支（冻结件搬运 / test 动态清单 / 两个分端清单）都要用它。
# ⚠️ 2026-10-04 事故：它曾被写在 test 分支里，正式 tag 走到 android
# 分端清单时 `set -u` 直接 `ASSET_BASE: unbound variable` —— 变量定义
# 必须在所有分支之外。
ASSET_BASE="https://github.com/hawkeye-xb/P-Pass/releases/download/${TAG}"
if [[ "$TAG" != *-test.* ]]; then
  # UPD-13（#660）：**正式版的老格式兼容清单 = 冻结件**
  # （release/legacy-manifest.json：version 固定 0.9.0、URL 指向 R2 上
  # 不可变的版本化副本）。分端号一旦分化，tag 版本的动态清单会高于某端
  # 包内版本 ⇒ 未升级的老客户端死循环。冻结件是那次「两端同号」发布的
  # 快照，永远自洽。
  cp release/legacy-manifest.json artifacts/manifest.json
else
  if [ "${#ARGS[@]}" -eq 0 ]; then
    echo "无任何平台产物——跳过 manifest 组装"
    exit 0
  fi
  node tools/make-update-manifest.mjs \
    --tag "$TAG" --notes-dir release/notes --notes-platform android \
    --asset-base "$ASSET_BASE" \
    "${ARGS[@]}"
  mv manifest.json artifacts/manifest.json
fi
# UPD-13 补丁：android 分端清单在 upload-android 里已先组装过一次（为了让
# 手机尽早拿到更新）。这里用同一批资产重新组装、与桌面清单同批签名上传。
# notes 两处同源（release/notes 下该端该版本的手写说明，#741），不随 release 正文变化。
APK="$APK_PATH"
if [ -f "$APK" ]; then
  node tools/make-update-manifest.mjs \
    --tag "$TAG" --notes-dir release/notes \
    --asset-base "$ASSET_BASE" \
    --asset android-arm64="$APK" \
    --version "$(tools/release-version.sh android)" \
    --only android-arm64 --out artifacts/manifest-android.json
fi
# UPD-13（#660）：本次**本该**有 macOS 产物却没有 → 直接红。
# 2026-10-05 事故：macOS lane 被取消 → 这里静默跳过 → 发布出去的版本
# 没有 manifest-macos.json → R2 保留旧版 → 桌面端检测不到更新，而页面
# 上看不出任何异常。绝不静默降级。
# #852：「本该有」只看 plan-builds 的判定，不看 lane 结果——test tag 上桌面判 skip（自上一次
# test 发布没有桌面改动）时这次本就没有 mac 产物；mac lane 失败/被取消照旧在这里红。
if [ "$MACOS_PLAN" = skip ]; then
  echo "桌面端本次判 skip（plan-builds）——不产出 macOS 清单，test-channel 里的 manifest-macos.json 不动"
else
case "${PLATFORMS:-all}" in
  *macos*|*all*|"")
    [ -n "$MAC_UPD" ] || {
      echo "::error::本次应产出 macOS 产物但 P-Pass_*_macos-arm64.app.tar.gz 不在——拒绝发布「没有 mac 更新源」的清单"
      exit 1
    } ;;
esac
fi
# UPD-13：同时产出一份**只含 darwin** 的分端清单（macOS 客户端的源）。
if [ -n "$MAC_UPD" ]; then
  node tools/make-update-manifest.mjs \
    --tag "$TAG" --notes-dir release/notes \
    --asset-base "$ASSET_BASE" \
    --asset darwin-aarch64="$MAC_UPD" \
    --version "$(tools/release-version.sh desktop)" \
    --only darwin-aarch64 --out artifacts/manifest-macos.json
fi
