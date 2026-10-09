#!/usr/bin/env bash
# REL-12（#711）：release.yml · upload-android ·「Compose update manifest (UPD-01)」。
# 原样抽自 workflow 内嵌 bash；release.yml 只调用本脚本。dry-run（tools/release/dry-run.sh）
# 跑的就是这一份。
#
# 输入（显式，缺了直接红）：
#   TAG          本次发布的 tag（job env）
#   RELEASE_TAG  tools/release-version.sh 判 test / 正式线用（workflow 顶层 env）
#   artifacts/android/P-Pass_*_android*.apk  （download-artifact 落盘）
# 输出：
#   artifacts/manifest.json          只在 test tag 产出（test-channel 指针用的动态清单）
#   artifacts/manifest-android.json  分端清单（只含 android-arm64，签名留空待下一步）
#   没有 APK ⇒ 什么都不产出、退出 0（与原步骤相同）。
set -euo pipefail
: "${TAG:?TAG 未设置（job env）}"
: "${RELEASE_TAG:?RELEASE_TAG 未设置（workflow 顶层 env）}"
# 工作目录不依赖调用方：一律以仓库根（= runner 工作区）为准。
cd "$(dirname "$0")/../.."

APK_ARGS=()
# UPD-15：产物名带该端版本号，用 glob 定位（不猜名字）
APK_PATH=$(find artifacts/android -maxdepth 1 -name 'P-Pass_*_android*.apk' | head -1)
[ -n "$APK_PATH" ] && APK_ARGS=(--asset android-arm64="$APK_PATH")
if [ "${#APK_ARGS[@]}" -gt 0 ]; then
  # 2026-08-25 用户拍板撤掉 R2 镜像：manifest 恒指 GitHub 直链。
  # 撤的原因不是「镜像没用」，是**耦合方向错**——原实现在镜像
  # 发生**之前**就把 URL 写成镜像地址，镜像 403 挂掉时 manifest
  # 已经签名上传进 release，指向不存在的文件 → 自动更新拿到一个
  # 坏 manifest 且无法手改（签名会破）。要重开镜像必须先修这个
  # 耦合（REL-04）：先镜像 → 据结果定 base → 签名 → 单独镜像
  # manifest；镜像失败必须回落 GitHub 直链，不许带坏 manifest 出门。
  ASSET_BASE="https://github.com/hawkeye-xb/P-Pass/releases/download/${TAG}"
  # UPD-13（#660）：动态 manifest.json 只给 test 通道用（它是
  # test-channel 指针）。正式版的老格式清单是收口阶段搬进来的**冻结件**
  # ——绝不能是 tag 版本的动态清单（分端号分化后会高于某端包内版本，
  # 把未升级的老客户端打进「提示更新→装上还是旧号」的死循环）。
  if [[ "$TAG" == *-test.* ]]; then
    node tools/make-update-manifest.mjs \
      --tag "$TAG" --notes-dir release/notes --notes-platform android \
      --asset-base "$ASSET_BASE" \
      "${APK_ARGS[@]}"
    mv manifest.json artifacts/manifest.json
  fi
  # UPD-13：同时产出一份**只含 android** 的分端清单。
  node tools/make-update-manifest.mjs \
    --tag "$TAG" --notes-dir release/notes \
    --asset-base "$ASSET_BASE" \
    "${APK_ARGS[@]}" \
    --version "$(tools/release-version.sh android)" \
    --only android-arm64 --out artifacts/manifest-android.json
else
  echo "无 APK 产物——跳过 manifest 组装"
fi
