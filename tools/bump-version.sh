#!/usr/bin/env bash
# REL-01: bump workspace + Android version in one shot.
# Usage: tools/bump-version.sh <new-version>    e.g. tools/bump-version.sh 0.3.0
#
# 防版本覆盖（2026-08-04 用户裁决：绝不挪/覆盖旧版本）：
#   - 已打过精确 tag（v<ver>）的版本号拒绝使用
#   - 新版本必须高于当前 Cargo.toml version
#   - 只改版本号行——验收：跑完 git diff 恰好只碰 Cargo.toml version 行
#     与 build.gradle.kts 的 versionCode/versionName 行
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NEW="${1:-}"
if [ -z "$NEW" ]; then
  echo "usage: tools/bump-version.sh <new-version>" >&2
  exit 1
fi

# SemVer 校验（3 段数字 + 可选预发布/构建后缀）
if ! [[ "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
  echo "error: 非法版本号 '$NEW'（期望 SemVer，如 0.3.0 或 0.3.0-beta.1）" >&2
  exit 1
fi

CUR=$(awk '/^version = /{gsub(/"/,"",$3); print $3; exit}' Cargo.toml)
if [ -z "$CUR" ]; then
  echo "error: 读不到 Cargo.toml workspace version" >&2
  exit 1
fi

# 防覆盖 1：已打过精确 tag 的版本号绝不复用
if git tag -l "v${NEW}" | grep -q .; then
  echo "error: v${NEW} 已打过 tag（git tag -l 'v${NEW}'）——拒绝覆盖旧版本号。" >&2
  echo "       每个版本的问题都是独一无二的：打新 tag，不挪旧 tag。" >&2
  exit 1
fi

# 防覆盖 2：新版本必须严格高于当前代码版本（显式相等检查 + sort -V
# 语义比较——相等时 sort -V 两行相同，head/tail 双端判断仍会放过，
# 必须先判 [ "$NEW" = "$CUR" ]）
if [ "$NEW" = "$CUR" ] \
  || [ "$(printf '%s\n%s\n' "$CUR" "$NEW" | sort -V | head -1)" != "$CUR" ]; then
  echo "error: 新版本 $NEW 必须严格高于当前版本 $CUR" >&2
  exit 1
fi

# 改 Cargo.toml（workspace 级第一处 version）
# ⚠️ 便携 sed：`-i ''` 是 macOS（BSD）专属，Linux（GNU）必炸——统一用
# `-i.bak … && rm …bak`（GNU/BSD 均接受带后缀的 -i）。
sed -i.bak "s/^version = \"$CUR\"/version = \"$NEW\"/" Cargo.toml && rm Cargo.toml.bak
# 改 Android versionName + versionCode（versionCode 单调 +1，Android 强制）
# ⚠️ BSD awk 把行首缩进当第一个分隔符，-F'[= ]+' 下 $2 是 "versionCode"——
# 用 gsub 去掉 "= " 前缀拿纯数字
VCODE=$(awk '/versionCode/{gsub(/.*= */,""); print; exit}' apps/android/app/build.gradle.kts)
if [ -z "$VCODE" ]; then
  echo "error: 读不到 build.gradle.kts versionCode" >&2
  exit 1
fi
NCODE=$((VCODE + 1))
sed -i.bak "s/versionCode = $VCODE/versionCode = $NCODE/" apps/android/app/build.gradle.kts && rm apps/android/app/build.gradle.kts.bak
sed -i.bak "s/versionName = \"$CUR\"/versionName = \"$NEW\"/" apps/android/app/build.gradle.kts && rm apps/android/app/build.gradle.kts.bak

echo "bumped: $CUR -> $NEW (android versionCode $VCODE -> $NCODE)"
echo "--- git diff（应只含版本号行）---"
git diff --stat Cargo.toml apps/android/app/build.gradle.kts
git diff Cargo.toml apps/android/app/build.gradle.kts | grep -E "^[+-]" | grep -vE "^(\+\+\+|---)" || true
