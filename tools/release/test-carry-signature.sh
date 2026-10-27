#!/usr/bin/env bash
# #1151：tools/release/carry-signature.sh 的反证测试（ci-docs lane 跑）。
#   ① 清单里有这份字节的原签名 ⇒ 沿用，输出的 .sig 与原签名逐字相同；
#   ② 字节被改动一位 ⇒ 失败（不重签、不留下 .sig）；
#   ③ 清单里只有别的产物 / 别的密钥的签名 ⇒ 失败；
#   ④ 清单缺失或没有条目 ⇒ 失败。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; fails=$((fails + 1)); }

mkdir -p "$T/repo/tools/release" "$T/repo/release/update-keys" "$T/repo/apps/desktop/src-tauri"
cp "$ROOT/tools/release/update-key-lib.sh" "$ROOT/tools/release/verify-update-sig.mjs" "$ROOT/tools/release/carry-signature.sh" "$T/repo/tools/release/"
for ch in stable other; do
  CI=true "$ROOT/tools/release/signer.sh" generate -w "$T/$ch.key" -p "" --ci >/dev/null
done
jq -n --arg p "$(cat "$T/stable.key.pub")" '{plugins:{updater:{pubkey:$p}}}' >"$T/repo/apps/desktop/src-tauri/tauri.conf.json"
CARRY="$T/repo/tools/release/carry-signature.sh"

printf 'apk-bytes-A' >"$T/a.bin"; printf 'apk-bytes-B' >"$T/b.bin"
"$ROOT/tools/release/signer.sh" sign -f "$T/stable.key" -p "" "$T/a.bin" >/dev/null 2>&1
"$ROOT/tools/release/signer.sh" sign -f "$T/stable.key" -p "" "$T/b.bin" >/dev/null 2>&1
cp "$T/a.bin" "$T/a.orig"
SIG_A="$(cat "$T/a.bin.sig")"; SIG_B="$(cat "$T/b.bin.sig")"
jq -n --arg a "$SIG_A" --arg b "$SIG_B" '{platforms:{"x":{signature:$b},"y":{signature:$a}}}' >"$T/m.json"

echo "== ① 清单里有原签名 ⇒ 沿用"
rm -f "$T/out.sig"
if "$CARRY" v2099.1.1 "$T/a.bin" "$T/out.sig" "$T/m.json" >/dev/null 2>&1 && [ "$(cat "$T/out.sig")" = "$SIG_A" ]; then
  pass "沿用了 a.bin 的原签名（跳过前面那条 b 的）"
else fail "没能沿用原签名"; fi

echo "== ② 字节被改动 ⇒ 失败且不留 .sig"
printf 'apk-bytes-X' >"$T/a.bin"
rm -f "$T/out.sig"
if "$CARRY" v2099.1.1 "$T/a.bin" "$T/out.sig" "$T/m.json" >/dev/null 2>&1; then fail "字节变了居然通过"
elif [ -e "$T/out.sig" ]; then fail "失败了却留下了 .sig"
else pass "字节变了 ⇒ 失败"; fi
cp "$T/a.orig" "$T/a.bin"

echo "== ③ 清单里只有别的密钥的签名 ⇒ 失败"
"$ROOT/tools/release/signer.sh" sign -f "$T/other.key" -p "" "$T/a.bin" >/dev/null 2>&1
jq -n --arg a "$(cat "$T/a.bin.sig")" '{platforms:{"y":{signature:$a}}}' >"$T/m-other.json"
rm -f "$T/out.sig"
if "$CARRY" v2099.1.1 "$T/a.bin" "$T/out.sig" "$T/m-other.json" >/dev/null 2>&1; then fail "别的密钥的签名居然通过"
else pass "别的密钥的签名 ⇒ 失败"; fi

echo "== ④ 清单缺失 / 没有条目 ⇒ 失败"
echo '{"platforms":{}}' >"$T/m-empty.json"
if "$CARRY" v2099.1.1 "$T/a.bin" "$T/out.sig" "$T/m-empty.json" "$T/不存在.json" >/dev/null 2>&1; then fail "没有条目居然通过"
else pass "没有条目 ⇒ 失败"; fi

[ "$fails" -eq 0 ] || { echo "FAILED: $fails 项" >&2; exit 1; }
echo "ok: carry-signature 反证测试全部通过"
