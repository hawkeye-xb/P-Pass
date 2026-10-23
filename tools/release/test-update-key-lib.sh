#!/usr/bin/env bash
# #1121：tools/release/update-key-lib.sh 的反证测试（ci-docs lane 跑）。
# 用 lockfile 安装的 signer 现生成两对临时密钥，在临时仓库布局里验：
#   ① test tag 用 test 私钥、正式 tag 用正式私钥，签完自验通过；
#   ② 本通道私钥缺失 ⇒ 失败（不退回另一把，也不跳过签名）；
#   ③ 私钥配错通道（test tag 拿到正式私钥）⇒ 签完自验失败；
#   ④ test 公钥文件不在 ⇒ test tag 失败；
#   ⑤ 轮换过渡期：仓库已是新公钥、secret 仍是旧私钥 ⇒ 有退役中公钥文件时通过，删掉即失败。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; fails=$((fails + 1)); }

# 临时仓库布局：lib 按自己的位置找 ../../release 与 ../../apps
mkdir -p "$T/repo/tools/release" "$T/repo/release/update-keys" "$T/repo/apps/desktop/src-tauri"
cp "$ROOT/tools/release/update-key-lib.sh" "$ROOT/tools/release/verify-update-sig.mjs" "$T/repo/tools/release/"
for ch in stable test next; do
  CI=true "$ROOT/tools/release/signer.sh" generate -w "$T/$ch.key" -p "" --ci >/dev/null
done
jq -n --arg p "$(cat "$T/stable.key.pub")" '{plugins:{updater:{pubkey:$p}}}' >"$T/repo/apps/desktop/src-tauri/tauri.conf.json"
cp "$T/test.key.pub" "$T/repo/release/update-keys/test.pub"
printf 'payload' >"$T/asset.bin"

# 在临时仓库里签一个文件并自验；$1=tag，私钥从环境变量来
# 注意：在 if 条件里调用时 set -e 不生效，所以每一步显式 `|| return 1`；
# 先删掉上一轮留下的 .sig / 私钥，免得拿旧签名过关。
sign_and_verify() (
  rm -f "$T/k" "$T/asset.bin.sig"
  # shellcheck source=tools/release/update-key-lib.sh
  . "$T/repo/tools/release/update-key-lib.sh" || return 1
  write_signing_key "$1" "$T/k" || return 1
  "$ROOT/tools/release/signer.sh" sign -f "$T/k" -p "" "$T/asset.bin" >/dev/null 2>&1 || return 1
  verify_signed_files "$1" "$T/asset.bin" >/dev/null || return 1
)

echo "== ① 各通道用各自的密钥"
UPDATE_SIGNING_KEY_TEST="$(cat "$T/test.key")" sign_and_verify v1.0.0-test.1 2>/dev/null && pass "test tag + test 私钥" || fail "test tag + test 私钥"
UPDATE_SIGNING_KEY="$(cat "$T/stable.key")" sign_and_verify v2099.1.1 2>/dev/null && pass "正式 tag + 正式私钥" || fail "正式 tag + 正式私钥"

echo "== ② 本通道私钥缺失 ⇒ 失败"
if UPDATE_SIGNING_KEY="$(cat "$T/stable.key")" UPDATE_SIGNING_KEY_TEST="" sign_and_verify v1.0.0-test.1 2>/dev/null; then
  fail "test 私钥缺失时居然签成了（退回了正式私钥？）"
else pass "test 私钥缺失 ⇒ 失败"; fi
if UPDATE_SIGNING_KEY="" sign_and_verify v2099.1.1 2>/dev/null; then
  fail "正式私钥缺失时居然没失败"
else pass "正式私钥缺失 ⇒ 失败"; fi

echo "== ③ 私钥配错通道 ⇒ 签完自验失败"
if UPDATE_SIGNING_KEY_TEST="$(cat "$T/stable.key")" sign_and_verify v1.0.0-test.1 2>/dev/null; then
  fail "test tag 用正式私钥签名居然通过了自验"
else pass "test tag 拿到正式私钥 ⇒ 自验失败"; fi

echo "== ④ test 公钥文件不在 ⇒ test tag 失败"
rm "$T/repo/release/update-keys/test.pub"
if UPDATE_SIGNING_KEY_TEST="$(cat "$T/test.key")" sign_and_verify v1.0.0-test.1 2>/dev/null; then
  fail "没有 test 公钥时居然通过了"
else pass "没有 test 公钥 ⇒ 失败"; fi

echo "== ⑤ 轮换过渡期（仓库公钥已换新、secret 仍是旧私钥）"
jq -n --arg p "$(cat "$T/next.key.pub")" '{plugins:{updater:{pubkey:$p}}}' >"$T/repo/apps/desktop/src-tauri/tauri.conf.json"
cp "$T/stable.key.pub" "$T/repo/release/update-keys/stable.retiring.pub"
UPDATE_SIGNING_KEY="$(cat "$T/stable.key")" sign_and_verify v2099.1.1 2>/dev/null \
  && pass "有 stable.retiring.pub：旧私钥签的过渡版本通过" || fail "有退役中公钥时过渡版本居然没通过"
rm "$T/repo/release/update-keys/stable.retiring.pub"
if UPDATE_SIGNING_KEY="$(cat "$T/stable.key")" sign_and_verify v2099.1.1 2>/dev/null; then
  fail "没有退役中公钥时旧私钥居然还能过"
else pass "删掉退役中公钥 ⇒ 旧私钥不再被接受"; fi

[ "$fails" -eq 0 ] || { echo "FAILED: $fails 项" >&2; exit 1; }
echo "ok: update-key-lib 反证测试全部通过"
