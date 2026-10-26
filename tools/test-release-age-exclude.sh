#!/usr/bin/env bash
# SEC-09 (#371)：check-release-age-exclude.py 的变异反证。
# 门禁在该红的时候必须真的红、该绿的时候必须绿——反证挂了就别信门禁的绿。
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
checker="$here/tools/check-release-age-exclude.py"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fails=0

# 造一个最小仓库：合规的 pnpm-workspace.yaml + 空白名单。
fresh() {
  rm -rf "$work/r"
  mkdir -p "$work/r/app" "$work/r/tools"
  git -C "$work/r" init -q
  cat > "$work/r/app/pnpm-workspace.yaml" <<'YAML'
# minimumReleaseAgeExclude 只出现在注释里，不算
allowBuilds:
  esbuild: true
minimumReleaseAgeStrict: true
YAML
  printf '# 空名单\n' > "$work/r/tools/release-age-exclude-allowlist.txt"
}

# expect <期望 pass|fail> <名字>：先 fresh + 调用方变异，再跑门禁核对退出码。
expect() {
  local want="$1" name="$2" rc=0 out
  git -C "$work/r" add -A
  out="$(python3 "$checker" --root "$work/r" 2>&1)" || rc=$?
  # 红必须是门禁主动报的（含 FAIL 标记），不能是脚本崩溃顺带退出 1。
  if { [ "$want" = pass ] && [ "$rc" -eq 0 ]; } \
    || { [ "$want" = fail ] && [ "$rc" -eq 1 ] && [[ "$out" == *"release-age-exclude-check: FAIL"* ]]; }; then
    echo "ok   ${name}（期望 ${want}，退出码 ${rc}）"
  else
    echo "FAIL ${name}（期望 ${want}，实际退出码 ${rc}）"
    fails=$((fails + 1))
  fi
}

fresh; expect pass "合规基线"

fresh; printf "minimumReleaseAgeExclude:\n  - 'foo@1.0.0'\n" >> "$work/r/app/pnpm-workspace.yaml"
expect fail "块列表新增一条 exclude"

fresh; printf "minimumReleaseAgeExclude: [foo@1.0.0, bar@2.0.0]\n" >> "$work/r/app/pnpm-workspace.yaml"
expect fail "行内列表新增 exclude"

fresh; printf "minimumReleaseAgeExclude: foo\n" >> "$work/r/app/pnpm-workspace.yaml"
expect fail "无法解析的写法一律红（不猜）"

fresh; printf "minimum-release-age-exclude[]=foo\n" > "$work/r/app/.npmrc"
expect fail ".npmrc 里写 exclude"

fresh; printf '{"pnpm":{"minimumReleaseAgeExclude":["foo"]}}\n' > "$work/r/app/package.json"
expect fail "package.json 里写 exclude"

fresh; sed -i.bak 's/Strict: true/Strict: false/' "$work/r/app/pnpm-workspace.yaml"; rm "$work/r/app/pnpm-workspace.yaml.bak"
expect fail "minimumReleaseAgeStrict 改成 false"

fresh; sed -i.bak '/Strict/d' "$work/r/app/pnpm-workspace.yaml"; rm "$work/r/app/pnpm-workspace.yaml.bak"
expect fail "minimumReleaseAgeStrict 缺失"

fresh; printf "minimumReleaseAgeExclude:\n  - foo@1.0.0\n" >> "$work/r/app/pnpm-workspace.yaml"
printf 'foo@1.0.0 | #371 反证用\n' >> "$work/r/tools/release-age-exclude-allowlist.txt"
expect pass "exclude + 白名单登记（显式放行）"

fresh; printf 'foo@1.0.0 | 过期豁免\n' >> "$work/r/tools/release-age-exclude-allowlist.txt"
expect fail "白名单有、配置里已无（过期条目）"

fresh; rm "$work/r/tools/release-age-exclude-allowlist.txt"
expect fail "白名单文件缺失"

if [ "$fails" -ne 0 ]; then
  echo "test-release-age-exclude: ${fails} 个变异未按期望" >&2
  exit 1
fi
echo "test-release-age-exclude: 全部符合期望"
