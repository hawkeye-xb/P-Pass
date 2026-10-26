#!/usr/bin/env bash
# #1151：复用 / 修复已发布产物时，**沿用**它原来的更新签名，不再用私钥重新签。
#
# 为什么：更新签名是发布者对「这份字节」的背书。产物字节一旦发布就不该再有第二次签名的机会——
# 复用与修复流程如果拿私钥对「从 release 取回来的字节」重新签，就等于信任了那个可被改写的 release。
# 沿用旧签名则相反：字节若被动过，旧签名当场验不过，流程直接红。
#
# 用法：tools/release/carry-signature.sh <tag> <产物文件> <输出 .sig> <清单.json>…
#   <tag>   决定用哪个通道的公钥验（update-key-lib.sh）；复用 / 修复只服务正式 tag
#   清单    已发布的分端清单（manifest-android.json / manifest-macos.json …）；
#           逐个条目取 signature，**用本通道公钥验过这份产物字节**的第一个写进 <输出 .sig>
# 找不到验得过的签名 ⇒ 退出 1：绝不退回去用私钥重签。
set -euo pipefail
TAG="${1:?用法：carry-signature.sh <tag> <产物> <输出.sig> <清单…>}"
ASSET="${2:?产物文件}"
OUT="${3:?输出 .sig}"
shift 3
[ "$#" -gt 0 ] || { echo "::error::没有给任何清单" >&2; exit 2; }
[ -f "$ASSET" ] || { echo "::error::产物 $ASSET 不存在" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tools/release/update-key-lib.sh
. "$ROOT/tools/release/update-key-lib.sh"

for m in "$@"; do
  [ -s "$m" ] || continue
  while IFS= read -r sig; do
    [ -n "$sig" ] || continue
    if verify_with_channel_keys "$TAG" "$ASSET" "$sig"; then
      printf '%s' "$sig" > "$OUT"
      echo "沿用 $(basename "$m") 里 $(basename "$ASSET") 的原签名（已用 $TAG 通道公钥验过）"
      exit 0
    fi
  done < <(jq -r '.platforms[]?.signature // empty' "$m")
done
echo "::error::找不到能验过 $(basename "$ASSET") 的现成签名（清单里没有，或字节已被改动）——不重新签名，请改走新 tag 发版" >&2
exit 1
