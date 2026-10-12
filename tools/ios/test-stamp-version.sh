#!/usr/bin/env bash
# #346：tools/ios/stamp-version.sh 的换算测试（不需要模拟器；ci-ios 里跑）。
#   - 已知串的三元结果逐个钉死
#   - 构建号随发布先后严格递增（test < beta < 正式 < 下一个修订号）
#   - 不认识的写法与越界一律非零退出（不猜）
#   - 真改一个 plist：四个键都写进去，再盖一次会覆盖
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/stamp-version.sh"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }

echo "换算"
while read -r input want; do
  got=$(PPF_BUILD_VERSION= PPASS_FALLBACK_VERSION= "$SUT" --print "$input" 2>&1)
  [[ "$got" == "$want" ]] && ok "${input} → ${got}" || bad "${input}：期望「${want}」，实际「${got}」"
done <<'EOF'
0.5.7-test.1 0.5.7 5007001 0.5.7-test.1
v0.5.7-test.1 0.5.7 5007001 0.5.7-test.1
0.5.7-beta.1 0.5.7 5007501 0.5.7-beta.1
0.5.7 0.5.7 5007999 0.5.7
0.5.8-test.2 0.5.8 5008002 0.5.8-test.2
2026.10.1 2026.10.1 2026010001999 2026.10.1
EOF

echo "单调"
prev=0
for v in 0.5.7-test.1 0.5.7-test.2 0.5.7-test.499 0.5.7-beta.1 0.5.7-beta.498 0.5.7 0.5.8-test.1 0.6.0 1.0.0-test.1 2026.10.1; do
  b=$("$SUT" --print "$v" | cut -d" " -f2)
  [[ "$b" -gt "$prev" ]] && ok "${v} → ${b} > ${prev}" || bad "${v} → ${b} 不大于前一个 ${prev}"
  prev=$b
done

echo "拒绝"
for v in 0.5.7-rc.1 0.5.7-test.0 0.5.7-test.500 0.5.7-beta.499 0.5 0.5.7.1 0.1000.0 abc; do
  if "$SUT" --print "$v" >/dev/null 2>&1; then bad "${v} 应被拒绝"; else ok "${v} 被拒绝"; fi
done
if PPF_BUILD_VERSION= PPASS_FALLBACK_VERSION= "$SUT" --print >/dev/null 2>&1; then bad "无输入应报错"; else ok "PPF_BUILD_VERSION 与回退值都为空 ⇒ 报错"; fi

echo "写 plist"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P="$TMP/Info.plist"
plutil -create xml1 "$P" && plutil -insert CFBundleShortVersionString -string 0.0.0 "$P" && plutil -insert CFBundleVersion -string 0 "$P"
PPF_BUILD_VERSION=v0.5.7-test.1 "$SUT" "$P" >/dev/null
PPF_BUILD_VERSION=v0.5.8-test.2 "$SUT" "$P" >/dev/null
r() { /usr/libexec/PlistBuddy -c "Print :$1" "$P" 2>/dev/null; }
[[ "$(r CFBundleShortVersionString) $(r CFBundleVersion) $(r PPassFullVersion) $(r PPassVersionSource)" == "0.5.8 5008002 0.5.8-test.2 PPF_BUILD_VERSION" ]] && ok "两次盖章后四个键都是第二次的值" || bad "plist 内容不对：$(plutil -p "$P")"
PPF_BUILD_VERSION= PPASS_FALLBACK_VERSION=0.1.0 "$SUT" "$P" >/dev/null
[[ "$(r PPassFullVersion) $(r PPassVersionSource)" == "0.1.0 fallback" ]] && ok "PPF_BUILD_VERSION 为空 ⇒ 回退值，来源记 fallback" || bad "回退不对：$(plutil -p "$P")"

echo
echo "通过 ${PASS} / 失败 ${FAIL}"
[ "$FAIL" = 0 ]
