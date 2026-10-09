#!/usr/bin/env bash
# REL-12（#711）：release.yml · upload-android ·「Upload android assets」里的签名校验门。
# 原样抽自 workflow 内嵌 bash；上传本身（gh release upload）仍留在 workflow 里。
#
# UPD-15 门禁：UPDATE_SIGNING_KEY 在位时，清单的签名必须非空——否则
# 就是在发一份「没签名的更新清单」（客户端会判定不可信）。签名步被
# 误跳过过（2026-10-05 v2026.10.2 实测），所以在上传前把口径钉死。
#
# 用法：tools/release/check-manifests-signed.sh <清单...>
#   相对路径以仓库根（= runner 工作区）为准；不存在的文件跳过（与原步骤相同）。
# 输入：HAS_UPDATE_KEY（job env，'true' / 'false'）。
set -euo pipefail
: "${HAS_UPDATE_KEY:?HAS_UPDATE_KEY 未设置（job env）}"
cd "$(dirname "$0")/../.."

if [ "${HAS_UPDATE_KEY}" = "true" ]; then
  for f in "$@"; do
    [ -f "$f" ] || continue
    minsig=$(jq -r '[.platforms[].signature | length] | min' "$f")
    [ "$minsig" -gt 0 ] || { echo "::error::$(basename "$f") 的签名为空（HAS_UPDATE_KEY 在位时必须签上）"; exit 1; }
  done
fi
