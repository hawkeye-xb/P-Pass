#!/usr/bin/env bash
# tools/heavy-lock 的判据测试（#1308）：可重入、串行、超时。每条带反证。
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HL="$HERE/heavy-lock"
pass=0; fail=0
ok() { echo "  ✅ $1"; pass=$((pass + 1)); }
bad() { echo "  ❌ $1"; fail=$((fail + 1)); }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export PPASS_HEAVY_LOCK="$tmp/lock"
unset PPASS_HEAVY_LOCK_HELD

if ! command -v lockf >/dev/null 2>&1; then echo "SKIP：本机没有 lockf"; exit 0; fi

# 1. 嵌套：外层持锁，内层同锁调用必须立即执行（10s 内完成）
start=$(date +%s)
PPASS_HEAVY_LOCK_WAIT=10 "$HL" "$HL" true; rc=$?
[ "$rc" -eq 0 ] && [ $(( $(date +%s) - start )) -lt 9 ] && ok "嵌套调用不死锁" || bad "嵌套调用死锁或失败（rc=${rc}）"

# 1 反证：内层绕过可重入（直接 lockf 同一把锁）必须超时
PPASS_HEAVY_LOCK_WAIT=10 "$HL" lockf -k -t 2 "$PPASS_HEAVY_LOCK" true >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "反证：绕过入口的嵌套会卡住（rc=${rc}）" || bad "反证失效：直接 lockf 嵌套居然成功"

# 2. 串行：两个并发调用不重叠
"$HL" bash -c "echo a1 >>'$tmp/seq'; sleep 1; echo a2 >>'$tmp/seq'" &
sleep 0.2
"$HL" bash -c "echo b1 >>'$tmp/seq'; echo b2 >>'$tmp/seq'"
wait
[ "$(tr '\n' ' ' <"$tmp/seq")" = "a1 a2 b1 b2 " ] && ok "并发调用串行" || bad "并发调用重叠：$(tr '\n' ' ' <"$tmp/seq")"

# 3. 超时：锁被别人占着，等待上限到了退出 75 并给提示
lockf -k "$PPASS_HEAVY_LOCK" sleep 5 &
holder=$!
sleep 0.3
out="$(PPASS_HEAVY_LOCK_WAIT=1 "$HL" true 2>&1)"; rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
[ "$rc" -eq 75 ] && printf '%s' "$out" | grep -q '等重编译锁超过' && ok "等锁超时退出 75 并提示" || bad "超时行为不对（rc=${rc}）：$out"

# 4. #1639：PATH 里没有 lockf，但 macOS 自带的 /usr/bin/lockf 可用 ⇒ 仍必须取锁，不能退化成无锁执行。
if [ -x /usr/bin/lockf ]; then
  nol="$tmp/nolock"
  mkdir -p "$nol"
  for c in env bash sh; do p="$(command -v "$c")"; [ -z "$p" ] || ln -sf "$p" "$nol/$c"; done
  /usr/bin/lockf -k "$PPASS_HEAVY_LOCK" sleep 5 &
  holder=$!
  sleep 0.3
  PATH="$nol" PPASS_HEAVY_LOCK_WAIT=1 "$HL" /usr/bin/true >/dev/null 2>&1; rc=$?
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  [ "$rc" -eq 75 ] && ok "PATH 无 lockf、/usr/bin/lockf 可用 → 仍取锁（超时退出 75）" || bad "PATH 无 lockf 时没取锁（rc=${rc}）"

  # 同一条件下已持锁仍直接执行（不重复找 lockf）
  start=$(date +%s)
  PATH="$nol" PPASS_HEAVY_LOCK_HELD=1 PPASS_HEAVY_LOCK_WAIT=1 "$HL" /usr/bin/true; rc=$?
  [ "$rc" -eq 0 ] && [ $(( $(date +%s) - start )) -lt 5 ] && ok "已持锁时直接执行（PATH 里没有 lockf 也不受影响）" || bad "已持锁仍失败或卡住（rc=${rc}）"

  # 反证：把副本里的 /usr/bin/lockf 回退指向不存在的位置（等价于没有这行回退）⇒
  # 上面「仍取锁」的场景必须退化为无锁直接执行；同一跑也说明哪里都没有 lockf 时仍是直接执行。
  sed 's|/usr/bin/lockf|/nonexistent/lockf|' "$HL" >"$tmp/hl-nolock-anywhere"
  chmod +x "$tmp/hl-nolock-anywhere"
  /usr/bin/lockf -k "$PPASS_HEAVY_LOCK" sleep 5 &
  holder=$!
  sleep 0.3
  PATH="$nol" PPASS_HEAVY_LOCK_WAIT=1 "$tmp/hl-nolock-anywhere" /usr/bin/true >/dev/null 2>&1; rc=$?
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  [ "$rc" -eq 0 ] && ok "反证：去掉 /usr/bin/lockf 回退 → 退化为无锁直接执行（新用例会红；无 lockf 的回退不变）" || bad "反证失效：去掉回退后仍取了锁（rc=${rc}）"
else
  echo "SKIP：本机没有 /usr/bin/lockf（非 macOS），#1639 的绝对路径回退不适用"
fi

echo
echo "heavy-lock: ${pass} passed, ${fail} failed"
[ "$fail" -eq 0 ]
