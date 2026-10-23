#!/usr/bin/env bash
# #1121：发布后真实验签——从 release 上把刚传上去的分端清单和它们指向的安装包取回来，
# 用客户端内置的那把公钥（按 tag 的通道选，见 update-key-lib.sh）逐个验 minisign 签名
# 与 sha256。验的是**线上那份字节**，不是签名步骤手里的本地副本：上传传错文件、清单
# 被后续步骤覆盖成别的版本、私钥配错通道，都在这里红。
#
# 正式 tag 的 release 停在 draft，`releases/latest/download` 取不到 draft 资产，所以经
# `gh release download <tag>`（带 token）取。
#
# 用法：tools/release/verify-published.sh <tag> <分端清单名…>（如 manifest-android.json）
#   清单不在该 release 上 ⇒ 失败（调用方只传本步刚上传过的清单）。
set -euo pipefail
TAG="$1"; shift
[ "$#" -gt 0 ] || { echo "用法：$0 <tag> <manifest…>" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tools/release/update-key-lib.sh
. "$ROOT/tools/release/update-key-lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
update_pubkey "$TAG" >/dev/null

for m in "$@"; do
  gh release download "$TAG" -p "$m" -O "$WORK/$m" --clobber
  [ -s "$WORK/$m" ] || { echo "::error::$TAG 上没有 $m" >&2; exit 1; }
  n=0
  while IFS=$'\t' read -r target url sig sha; do
    asset="${url##*/}"
    gh release download "$TAG" -p "$asset" -O "$WORK/$asset" --clobber
    [ -s "$WORK/$asset" ] || { echo "::error::$m 的 $target 指向的 $asset 不在 $TAG 上" >&2; exit 1; }
    actual="$( (sha256sum "$WORK/$asset" 2>/dev/null || shasum -a 256 "$WORK/$asset") | awk '{print $1}')"
    [ "$actual" = "$sha" ] || { echo "::error::$m 的 ${target}：sha256 不符（清单 ${sha}，线上 ${actual}）" >&2; exit 1; }
    verify_with_channel_keys "$TAG" "$WORK/$asset" "$sig" \
      || { echo "::error::$m 的 ${target}：签名用 $TAG 所在通道的公钥验不过" >&2; exit 1; }
    n=$((n + 1))
  done < <(jq -r '.platforms | to_entries[] | [.key, .value.url, .value.signature, .value.sha256] | @tsv' "$WORK/$m")
  [ "$n" -gt 0 ] || { echo "::error::$m 没有任何条目" >&2; exit 1; }
  echo "✓ ${m}：$n 个条目的签名与 sha256 都对得上线上字节"
done
