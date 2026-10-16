#!/usr/bin/env bash
# SEC-15 (#1003): tools/ci-deny-advisories.sh 的判据测试 + 变异反证。
#
# 那个脚本判错方向有两种后果，都要钉住：
#   - 该跑不跑 ⇒ 有人改了锁文件引入有漏洞的版本，PR 却报绿；
#   - 不该跑却跑 ⇒ 回到 #1003 之前，外部信号把无关 PR 全部弄红。
# 另钉 fail-closed（拿不到 HEAD^1 ⇒ 照跑）和 cargo 退出码透传。
# 变异反证：把判据故意改成「永远跳过」，断言必须立刻变红。
#
# 用法: tools/test-ci-deny-advisories.sh
# 退出码: 0 全过 / 1 有失败

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/ci-deny-advisories.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

# cargo 桩：记下被调用过，退出码由 STUB_EXIT 决定。
STUB="$TMP/cargo-stub"
cat >"$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG"
exit "${STUB_EXIT:-0}"
EOF
chmod +x "$STUB"

# 建一个仓库：根与 sub/ 各有 Cargo.lock + deny.toml，外加一个无关文件。
# 第二个参数非空时再提交一次，改动它列出的文件。
make_repo() {
  local repo="$1"
  shift
  rm -rf "$repo"
  mkdir -p "$repo/sub"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  git -C "$repo" config core.autocrlf false
  for f in Cargo.lock deny.toml README.md sub/Cargo.lock sub/deny.toml; do
    echo v1 >"$repo/$f"
  done
  git -C "$repo" add -A
  git -C "$repo" commit -qm base
  if [ "$#" -gt 0 ]; then
    for f in "$@"; do echo v2 >"$repo/$f"; done
    git -C "$repo" commit -qam change
  fi
}

# expect <script> <want: run|skip> <dir> <label> <changed files...>
expect() {
  local script="$1" want="$2" dir="$3" label="$4"
  shift 4
  local repo="$TMP/repo"
  make_repo "$repo" "$@"
  : >"$TMP/log"
  (cd "$repo" && STUB_LOG="$TMP/log" CARGO="$STUB" bash "$script" "$dir" >/dev/null 2>&1)
  local got=skip
  [ -s "$TMP/log" ] && got=run
  if [ "$got" = "$want" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL [$label]: want $want, got $got"
  fi
}

suite() {
  local s="$1"
  expect "$s" run . "根：改 Cargo.lock" Cargo.lock
  expect "$s" run . "根：改 deny.toml" deny.toml
  expect "$s" skip . "根：只改无关文件" README.md
  expect "$s" skip . "根：只改子树锁文件" sub/Cargo.lock
  expect "$s" run sub "子树：改自己的 Cargo.lock" sub/Cargo.lock
  expect "$s" run sub/ "子树：尾斜杠写法" sub/deny.toml
  expect "$s" skip sub "子树：只改根锁文件" Cargo.lock
  expect "$s" run . "fail-closed：只有一个提交，没有 HEAD^1"
}

suite "$SUT"

# cargo 的退出码必须透传，否则审计红了脚本却报绿。
make_repo "$TMP/repo" Cargo.lock
if (cd "$TMP/repo" && STUB_LOG="$TMP/log" STUB_EXIT=1 CARGO="$STUB" bash "$SUT" . >/dev/null 2>&1); then
  FAIL=$((FAIL + 1))
  echo "FAIL [退出码透传]: cargo 退出 1，脚本却退出 0"
else
  PASS=$((PASS + 1))
fi

# 变异反证：判据恒判「跳过」⇒ 上面的 run 断言必须红。
MUT="$TMP/mutant.sh"
sed 's/^run=1$/run=0/' "$SUT" >"$MUT"
if cmp -s "$SUT" "$MUT"; then
  FAIL=$((FAIL + 1))
  echo "FAIL [变异反证]: sed 没改到判据，变异体与原脚本相同"
else
  pass_before=$PASS
  before=$FAIL
  suite "$MUT" >/dev/null
  mutant_failed=$((FAIL - before))
  PASS=$pass_before
  FAIL=$before
  if [ "$mutant_failed" -gt 0 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "FAIL [变异反证]: 判据恒判跳过，断言却全绿——断言是恒真式"
  fi
fi

echo "ci-deny-advisories: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
