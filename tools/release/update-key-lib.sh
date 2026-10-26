#!/usr/bin/env bash
# #1121：更新签名的密钥划分——test 通道与正式通道各用一把（被 source，不单独执行）。
#
#   tag 含 `-test.` ⇒ 私钥 UPDATE_SIGNING_KEY_TEST，公钥 release/update-keys/test.pub
#   其余           ⇒ 私钥 UPDATE_SIGNING_KEY，     公钥 apps/desktop/src-tauri/tauri.conf.json 的 updater pubkey
#
# 公钥只有这两个来源：桌面构建（tools/release/tauri-config.mjs）、Android 构建
# （apps/android/app/build.gradle.kts）、发布校验都从这里读，不手抄。
# 缺哪把都直接失败——不存在「没有密钥就不签」或「没有 test 密钥就用正式密钥」。
#
# 轮换（docs/runbook/update-signing-keys.md §3）：过渡版本里仓库的公钥已换成新的，签名
# 仍用旧私钥。这期间把旧公钥放在 release/update-keys/<stable|test>.retiring.pub，
# 签完自验与发布后验签接受「当前公钥或退役中公钥」任一把；切完 secret 就删掉这个文件。

# 打印 <tag> 所在通道的公钥（tauri 格式：base64 文本盒）。
update_pubkey() {
  local tag="$1" root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  case "$tag" in
    *-test.*)
      local f="$root/release/update-keys/test.pub"
      [ -s "$f" ] || { echo "::error::test 通道公钥 release/update-keys/test.pub 不存在（见 docs/runbook/update-signing-keys.md 生成并入库）" >&2; return 1; }
      tr -d '\n' <"$f"
      ;;
    *)
      jq -er '.plugins.updater.pubkey' "$root/apps/desktop/src-tauri/tauri.conf.json"
      ;;
  esac
}

# 打印 <tag> 所在通道的私钥所在的环境变量名。
update_key_var() {
  case "$1" in
    *-test.*) echo UPDATE_SIGNING_KEY_TEST ;;
    *) echo UPDATE_SIGNING_KEY ;;
  esac
}

# 把 <tag> 所在通道的私钥写到 <file>（0600）；对应的环境变量为空即失败。
write_signing_key() {
  local tag="$1" file="$2" var
  var="$(update_key_var "$tag")"
  [ -n "${!var:-}" ] || { echo "::error::$var 未设置——$tag 的更新包无法签名，拒绝发布未签名的清单" >&2; return 1; }
  # printf '%s' 逐字节还原（echo 的尾换行会让 tauri signer 报 Invalid symbol，v0.2.1-test.1 实测）。
  printf '%s' "${!var}" >"$file"
  chmod 600 "$file"
}

# 把 <tag> 所在通道可接受的公钥（当前 + 轮换期间的退役中公钥）各写成一个文件，放进 <dir>，
# 打印这些文件的路径（每行一个）。
update_pubkey_files() {
  local tag="$1" dir="$2" root retiring
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  update_pubkey "$tag" >"$dir/current.pub" || return 1
  echo "$dir/current.pub"
  case "$tag" in *-test.*) retiring="$root/release/update-keys/test.retiring.pub" ;; *) retiring="$root/release/update-keys/stable.retiring.pub" ;; esac
  if [ -s "$retiring" ]; then
    tr -d '\n' <"$retiring" >"$dir/retiring.pub"
    echo "$dir/retiring.pub"
  fi
}

# <asset> 的签名（<sig>：base64 文本或 @文件）能被 <tag> 所在通道任一把可接受公钥验过吗。
verify_with_channel_keys() {
  local tag="$1" asset="$2" sig="$3" root dir pub ok=1
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  dir="$(mktemp -d)"
  while IFS= read -r pub; do
    if node "$root/tools/release/verify-update-sig.mjs" "$pub" "$asset" "$sig" >/dev/null 2>&1; then ok=0; break; fi
  done < <(update_pubkey_files "$tag" "$dir")
  rm -rf "$dir"
  return "$ok"
}

# 用 <tag> 所在通道的公钥逐个验 <file>.sig——签完立刻验，私钥与通道对不上当场失败。
verify_signed_files() {
  local tag="$1" f
  shift
  update_pubkey "$tag" >/dev/null || return 1
  for f in "$@"; do
    verify_with_channel_keys "$tag" "$f" "@$f.sig" \
      || { echo "::error::$(basename "$f") 的签名用 $tag 所在通道的公钥验不过（私钥配错了？）" >&2; return 1; }
  done
}
