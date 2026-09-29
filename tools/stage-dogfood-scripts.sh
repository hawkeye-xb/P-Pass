#!/usr/bin/env bash
# REL-08 (#510)：把随 release 资产发布的 shell 脚本复制进资产目录。
#
# 这是「资产里带哪些 .sh」的**唯一清单**。artifacts.yml / release.yml 只调
# 本脚本，不再各自 `cp tools/xxx.sh`——以前三处各写一行 `cp … || true`，
# 漏带 dogfood-smoke.sh 所 source 的 ipc-lib.sh 也不会有任何报错。
# 门禁 tools/test-dogfood-assets.sh 在只含这些文件的干净目录里校验：
# 每个 .sh 所 source 的文件都在清单里，且 smoke 在那里能加载 helper。
#
# 用法: tools/stage-dogfood-scripts.sh <资产目录>
# stdout 逐行打印复制后的路径（Linux job 直接拿它当 upload 列表）。
set -euo pipefail

DEST="${1:?用法: $0 <资产目录>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

SCRIPTS=(
  dogfood-smoke.sh
  ipc-lib.sh   # dogfood-smoke.sh 从「脚本同目录」source 它
)

mkdir -p "$DEST"
for f in "${SCRIPTS[@]}"; do
  cp "$HERE/$f" "$DEST/$f"
  chmod +x "$DEST/$f"
  echo "$DEST/$f"
done
