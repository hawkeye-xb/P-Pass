#!/usr/bin/env bash
# REL-12（#711）：上传更新清单之前的门禁（release.yml 各上传步骤共用）。
#
# UPD-15 门禁：清单的签名必须非空——否则就是在发一份「没签名的更新清单」
# （客户端会判定不可信）。签名步被误跳过过（2026-10-05 v2026.10.2 实测），所以在
# 上传前把口径钉死。
#
# #1121：不再有「密钥不在就放行」的分支——签名密钥缺失时签名步直接失败，这里
# 也无条件要求每个条目都有签名，并且 sha256 必须是 64 位十六进制（Android 客户端
# 先比 sha256 再验签，sha256 改为必填）。
#
# 用法：tools/release/check-manifests-signed.sh <清单...>
#   相对路径以仓库根（= runner 工作区）为准；不存在的文件跳过。
set -euo pipefail
cd "$(dirname "$0")/../.."

for f in "$@"; do
  [ -f "$f" ] || continue
  bad=$(jq -r '.platforms | to_entries[]
      | select((.value.signature // "") == "" or ((.value.sha256 // "") | test("^[0-9a-f]{64}$") | not))
      | .key' "$f")
  if [ -n "$bad" ]; then
    echo "::error::$(basename "$f") 的条目缺签名或 sha256：$(echo "$bad" | tr '\n' ' ')"
    exit 1
  fi
done
