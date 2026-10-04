#!/usr/bin/env bash
# UPD-13（#660）：**本次发布该用哪个版本号**。
#
#   两条线并行（2026-10-04 拍板）：
#     - 正式 tag（v2026.10.1 这种日期批次号，或 vX.Y.Z）→ 用 release/versions.json
#       里**该端自己的**版本号：只有本端真改了才涨，另一端保持不动。
#     - test tag（v<X.Y.Z>-test.N）→ 一律用 tag 名本身：`-test.` 是 test 通道的
#       判据（channelFromVersion），且连续的 test tag 必须能互相升级。
#
# 用法：tools/release-version.sh android|desktop
#   打印纯版本串（不带 v 前缀），供 release.yml 注入 PPF_BUILD_VERSION /
#   分端 manifest 的顶层 version。
set -euo pipefail

PLATFORM="${1:-}"
case "$PLATFORM" in
  android|desktop) ;;
  *) echo "usage: $0 <android|desktop>" >&2; exit 1 ;;
esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REF_NAME="${GITHUB_REF_NAME:-$(git describe --tags --exact-match 2>/dev/null || echo '')}"

if [[ "$REF_NAME" == *-test.* ]]; then
  echo "${REF_NAME#v}"
  exit 0
fi

jq -r ".$PLATFORM" "$ROOT/release/versions.json"
