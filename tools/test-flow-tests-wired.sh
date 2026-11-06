#!/usr/bin/env bash
# #1493：流程门禁脚本的自测必须真在 CI 上跑——防「新加一个 *-test recipe 却只挂在本地 just ci」再发生。
#
# 判据（justfile 用 just 自己的解析器读：just --dump --dump-format json）：
#   1. justfile 里每个名字以 -test 结尾的 recipe，要么是 flow-tests 的依赖，要么登记在下面的例外表里；
#   2. 例外表的每一行：recipe 在 justfile 里存在、不在 flow-tests 里；登记了 lane 的，该 workflow 里必须出现登记的字符串
#      （不信自报）；lane 写 `-` 的只许用于「不是自测」的 recipe，原因必填；
#   3. ci 与 ci-docs 都依赖 flow-tests（本地与 CI 共用一份清单）；
#   4. ci-docs.yml 有 key 与 name 都写死为 flow-tests 的 job，运行 just flow-tests，且在 CI Docs gate 的 needs 里。
# 反证：在临时目录里造四种变异（从 flow-tests 删一个依赖 / 新增没接线的 *-test / 例外指向的 workflow 里没有登记的字符串 /
# gate 的 needs 里没有 flow-tests），每种都必须判红；原样必须判绿。
#
# 用法: tools/test-flow-tests-wired.sh
# 退出码: 0 全过 / 1 有失败
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# 例外表：recipe|workflow 文件（.github/workflows 下；- 表示不是自测）|该 workflow 里必须出现的字符串|原因
EXCEPTIONS='android-test|ci-android.yml|./gradlew :app:testDebugUnitTest|要 JDK + Android SDK，ci-android 的 unit test job 直接跑 gradle
ios-test|ci-ios.yml|tools/ios/test.sh|要 macOS + Xcode 模拟器，ci-ios 直接跑 tools/ios/test.sh
ios-test-packages|ci-ios.yml|tools/ios/test-packages.sh|要 macOS + Xcode 模拟器，ci-ios 直接跑 tools/ios/test-packages.sh
release-test|-|-|不是自测：owner 在 origin/main 上打 test tag 出 test 包的命令（见 docs/runbook/owner.md），绝不能在 CI 上跑'

fail=0
ok() { echo "  ✅ $1"; }
ko() { echo "  ❌ $1"; fail=1; }

for bin in just jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "  ❌ 找不到 ${bin}，无法判定"; exit 1; }
done

# check <justfile> <workflows 目录>：有问题逐条打印到 stdout，退出码 1；全过退出 0、不打印。
check() {
  local jf="$1" wf="$2" dump bad=0 r lane marker reason
  if ! dump="$(just --justfile "$jf" --working-directory "$(dirname "$jf")" --dump --dump-format json 2>&1)"; then
    echo "just 解析 ${jf} 失败：${dump}"
    return 1
  fi
  local recipes flow
  recipes="$(printf '%s' "$dump" | jq -r '.recipes | keys[]')"
  flow="$(printf '%s' "$dump" | jq -r '.recipes["flow-tests"].dependencies[]?.recipe')"
  if [ -z "$flow" ]; then
    echo "justfile 里没有 flow-tests recipe（或它没有依赖）"
    return 1
  fi
  local exc_names
  exc_names="$(printf '%s\n' "$EXCEPTIONS" | cut -d'|' -f1)"

  # 判据 3：ci 与 ci-docs 都依赖 flow-tests
  for r in ci ci-docs; do
    printf '%s' "$dump" | jq -e --arg r "$r" '.recipes[$r].dependencies[]?.recipe | select(. == "flow-tests")' >/dev/null ||
      { echo "${r} 没有依赖 flow-tests（本地清单会和 CI 漂移）"; bad=1; }
  done

  # 判据 1：每个 *-test 都接上了
  while IFS= read -r r; do
    case "$r" in *-test) ;; *) continue ;; esac
    printf '%s\n' "$flow" | grep -qxF "$r" && continue
    printf '%s\n' "$exc_names" | grep -qxF "$r" && continue
    echo "recipe ${r} 既不在 flow-tests 里，也没登记例外：它在 CI 上没人跑"
    bad=1
  done <<<"$recipes"

  # 判据 2：例外表逐行核对
  while IFS='|' read -r r lane marker reason; do
    [ -n "$r" ] || continue
    [ -n "$reason" ] || { echo "例外 ${r} 没写原因"; bad=1; }
    printf '%s\n' "$recipes" | grep -qxF "$r" || { echo "例外 ${r} 在 justfile 里已不存在：删掉这行"; bad=1; }
    printf '%s\n' "$flow" | grep -qxF "$r" && { echo "例外 ${r} 同时出现在 flow-tests 里"; bad=1; }
    if [ "$lane" = "-" ]; then
      case "$reason" in 不是自测*) ;; *) echo "例外 ${r} 没登记 lane，原因却不是「不是自测」"; bad=1 ;; esac
      continue
    fi
    if [ ! -f "$wf/$lane" ]; then
      echo "例外 ${r} 登记的 ${lane} 不存在"
      bad=1
    elif ! grep -qF -- "$marker" "$wf/$lane"; then
      echo "例外 ${r} 登记在 ${lane} 跑，但那里找不到「${marker}」"
      bad=1
    fi
  done <<<"$EXCEPTIONS"

  # 判据 4：ci-docs.yml 的 flow-tests job 与 gate
  local yml="$wf/ci-docs.yml"
  if [ ! -f "$yml" ]; then
    echo "找不到 ci-docs.yml"
    bad=1
  else
    # flow-tests job 的块：从 `  flow-tests:` 到下一个两格缩进的 key
    local job
    job="$(awk '/^  [A-Za-z0-9_-]+:/{inb=($0 ~ /^  flow-tests:[[:space:]]*$/)} inb' "$yml")"
    if [ -z "$job" ]; then
      echo "ci-docs.yml 没有 key 为 flow-tests 的 job"
      bad=1
    else
      printf '%s\n' "$job" | grep -qE '^    name:[[:space:]]*flow-tests[[:space:]]*$' ||
        { echo "ci-docs.yml 的 flow-tests job 的 name 不是写死的 flow-tests"; bad=1; }
      printf '%s\n' "$job" | grep -qE 'just flow-tests([[:space:]]|$)' ||
        { echo "ci-docs.yml 的 flow-tests job 没有运行 just flow-tests"; bad=1; }
    fi
    local gate
    gate="$(awk '/^  [A-Za-z0-9_-]+:/{inb=($0 ~ /^  gate:[[:space:]]*$/)} inb' "$yml" | grep -E '^    needs:')"
    printf '%s\n' "$gate" | grep -qE '[[, ]flow-tests[], ]' ||
      { echo "CI Docs gate 的 needs 里没有 flow-tests：它红了也挡不住合入"; bad=1; }
  fi
  return "$bad"
}

echo "==> flow-tests 接线元测试（#1493）"

# ── 反证：四种变异都必须判红，原样必须判绿 ──
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fresh() {
  rm -rf "$tmp/r"
  mkdir -p "$tmp/r/.github"
  cp "$ROOT/justfile" "$tmp/r/justfile"
  cp -R "$ROOT/.github/workflows" "$tmp/r/.github/workflows"
}
expect() { # expect <期望 pass|fail> <说明>
  local out rc
  out="$(check "$tmp/r/justfile" "$tmp/r/.github/workflows")"
  rc=$?
  if [ "$1" = pass ] && [ "$rc" -eq 0 ]; then
    ok "反证：$2 → 判绿"
  elif [ "$1" = fail ] && [ "$rc" -ne 0 ]; then
    ok "反证：$2 → 判红（$(printf '%s' "$out" | head -1)）"
  else
    ko "反证失败：$2 期望 $1，实际 rc=${rc}；${out}"
  fi
}

fresh
expect pass "原样副本"

fresh
victim="$(just --justfile "$ROOT/justfile" --working-directory "$ROOT" --dump --dump-format json |
  jq -r '.recipes["flow-tests"].dependencies[0].recipe')"
python3 - "$tmp/r/justfile" "$victim" <<'PY'
import re, sys
p, v = sys.argv[1], sys.argv[2]
s = open(p).read()
s2 = re.sub(r'(?m)^(flow-tests:.*?) ' + re.escape(v) + r'(?= |$)', r'\1', s, count=1)
assert s2 != s, "变异没生效"
open(p, 'w').write(s2)
PY
expect fail "从 flow-tests 删掉 ${victim}"

fresh
printf '\nbogus-wired-test:\n  @true\n' >>"$tmp/r/justfile"
expect fail "新增没接线的 bogus-wired-test"

fresh
python3 - "$tmp/r/.github/workflows/ci-android.yml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
s2 = s.replace("./gradlew :app:testDebugUnitTest", "./gradlew :app:assembleDebug")
assert s2 != s, "变异没生效"
open(p, 'w').write(s2)
PY
expect fail "ci-android.yml 不再跑 testDebugUnitTest（例外 android-test 失实）"

fresh
python3 - "$tmp/r/.github/workflows/ci-docs.yml" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
s2 = re.sub(r'(?m)^(    needs: \[.*?), flow-tests(?=[,\]])', r'\1', s, count=1)
assert s2 != s, "变异没生效"
open(p, 'w').write(s2)
PY
expect fail "CI Docs gate 的 needs 去掉 flow-tests"

# ── 真实检查 ──
if out="$(check "$ROOT/justfile" "$ROOT/.github/workflows")"; then
  ok "justfile 的每个 *-test 都接进了 flow-tests 或登记的 lane；ci-docs.yml 的 flow-tests job 在 gate 里"
else
  ko "接线不全："
  printf '%s\n' "$out" | sed 's/^/      /'
fi

if [ "$fail" -ne 0 ]; then
  echo "❌ flow-tests 接线元测试未通过"
  exit 1
fi
echo "✅ flow-tests 接线元测试通过"
