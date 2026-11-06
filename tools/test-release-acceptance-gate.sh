#!/usr/bin/env bash
# #1486 发版闸的测试（方案 docs/decisions/2026-11-06-release-acceptance-gate.md）：按 step 名从 release.yml 抽出
# 「发版闸：验收台账清零（#1486）」，在临时仓库里用假 gh 跑五种情况：
#   台账全勾 → 过；有一项没勾 → 红；没有台账 → 红；同名台账两张 → 红；test tag → 不查。
# 另有：搜索结果到 100 条上限 → 红（可能截掉第二张同名台账）；读不到 GitHub → 红。
# 测试自己注入 TAG / GITHUB_SHA 等，所以另外逐字核对 step 的 if 与 env（TAG、GH_TOKEN、PPASS_HOOK_REPO），关掉或断了入参都红。
# 另查位置与权限：它在 plan-builds 里、在「发版入口守卫（#1349）」之后、「Plan builds (#838)」之前（所有构建 job 都 needs plan-builds），
# plan-builds 有 issues: read、pull-requests: read。
# 反证（脚本自带）：把这一步的判定去掉（run 换成只打印），未勾 / 无台账 / 同名两张三条必须转绿——证明它们的红来自这一步。
# RELEASE_YML 可指向另一份 release.yml 做反证（例如删掉了这一步的版本，测试必须红）。
# 用法: tools/test-release-acceptance-gate.sh    退出码: 0 全过 / 1 有失败
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
REL_YML="${RELEASE_YML:-${SRC}/.github/workflows/release.yml}"
STEP_NAME="发版闸：验收台账清零（#1486）"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok() { printf '  ✅ %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo "==> release.yml 里的发版闸"
# 抽 step：找不到、位置不对、权限不够都判失败（不静默跳过）。MUTATE=1 时把 run 换成只打印（反证用）。
extract() { # extract <输出文件> <MUTATE 0|1>
  python3 - "$REL_YML" "$STEP_NAME" "$1" "$2" <<'PY'
import sys, yaml
wf, name, out, mutate = sys.argv[1:5]
job = yaml.safe_load(open(wf))["jobs"].get("plan-builds") or sys.exit("release.yml 没有 plan-builds job")
names = [s.get("name") for s in job["steps"]]
if name not in names:
    sys.exit(f"plan-builds 里没有 step「{name}」")
i = names.index(name)
guard, plan = "发版入口守卫（#1349）", "Plan builds (#838)"
if guard not in names or plan not in names or not (names.index(guard) < i < names.index(plan)):
    sys.exit(f"「{name}」要在「{guard}」之后、「{plan}」之前（现在顺序：{names}）")
perms = job.get("permissions") or {}
for k in ("issues", "pull-requests"):
    if perms.get(k) not in ("read", "write"):
        sys.exit(f"plan-builds 缺 permissions {k}: read")
step = job["steps"][i]
# 条件与入参逐字核对：改成 !inputs.release、丢了 TAG（空 TAG 会走「test 包不查」直接放行）都要红。
if str(step.get("if", "")).strip() != "${{ inputs.release }}":
    sys.exit(f"发版闸的 if 要恰为 ${{{{ inputs.release }}}}（现在：{step.get('if')!r}）")
want_env = {"TAG": "${{ inputs.tag }}", "GH_TOKEN": "${{ github.token }}", "PPASS_HOOK_REPO": "${{ github.repository }}"}
env = step.get("env") or {}
for k, v in want_env.items():
    if str(env.get(k, "")).strip() != v:
        sys.exit(f"发版闸的 env.{k} 要恰为 {v}（现在：{env.get(k)!r}）")
run = step["run"]
if mutate == "1":
    run = 'echo "（反证：判定已去掉）"\n'
open(out, "w").write(run)
PY
}
if extract "${TMP}/gate.sh" 0 2>"${TMP}/err"; then
  ok "plan-builds 里有「${STEP_NAME}」，位置在入口守卫之后、Plan builds 之前，if 与 env 逐字正确，有 issues / pull-requests 读权限"
else
  bad "抽不到发版闸：$(cat "${TMP}/err")"
  echo
  echo "通过 ${PASS}，失败 ${FAIL}"
  exit 1
fi
extract "${TMP}/gate-mutant.sh" 1 2>/dev/null || { bad "造反证副本失败"; exit 1; }

# ── 夹具：临时仓库（v2026.1.0 正式 → #31 界面 → v2026.2.0-test.1），release-acceptance.sh 及其依赖照搬 ──
R="${TMP}/repo"
FAKE="${TMP}/fake"
mkdir -p "${R}/tools/flow" "${R}/.github" "${TMP}/bin" "${FAKE}" "${TMP}/tpl"
for f in release-scope.sh release-acceptance.sh acceptance-gate.sh owner-triage.sh worker-lib.sh decision-lib.sh; do
  cp "${SRC}/tools/flow/${f}" "${R}/tools/flow/"
done
cp "${SRC}/tools/ci-paths.sh" "${R}/tools/"
printf '+ core/**\n' >"${R}/.github/core-paths.txt"
(
  cd "$R" || exit 1
  export GIT_TEMPLATE_DIR="${TMP}/tpl"
  git init -q -b main
  git config user.email t@t
  git config user.name t
  mkdir -p apps/desktop/src
  echo 0 >apps/desktop/src/A.svelte
  c() { git add -A && git -c core.hooksPath=/dev/null commit -q --no-verify -m "$1"; }
  c "init"
  git tag v2026.1.0
  echo 1 >apps/desktop/src/A.svelte && c "feat: A (#31)"
  git tag v2026.2.0-test.1
  git update-ref refs/remotes/origin/main HEAD
) || { echo "造临时仓库失败"; exit 1; }
HEAD_SHA="$(git -C "$R" rev-parse HEAD)"

# 假 gh：issue list 核对参数（--state all、按 tag 搜标题）后吐 $FAKE/list.json；issue view <号> 吐 $FAKE/ledger.<号>。
cat >"${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list")
    args=" $* "
    [[ "$args" == *" --state all "* ]] || { echo "stub gh: issue list 没带 --state all：$*" >&2; exit 3; }
    [[ "$args" == *"--search ${TAG} in:title"* ]] || { echo "stub gh: issue list 没按 tag 搜标题：$*" >&2; exit 3; }
    # 上限判定按 100 判：--limit 必须恰为 100（删掉会落回 gh 默认 30 条，截断却不判红）。
    [[ "$args" == *" --limit 100 "* ]] || { echo "stub gh: issue list 的 --limit 不是 100：$*" >&2; exit 3; }
    [ -e "${FAKE}/list.fail" ] && { echo "HTTP 502: stub failure" >&2; exit 1; }
    cat "${FAKE}/list.json" ;;
  "issue view")
    cat "${FAKE}/ledger.$3" ;;
  *) echo "stub gh: unsupported $*" >&2; exit 2 ;;
esac
STUB
chmod +x "${TMP}/bin/gh"

list() { printf '%s\n' "$1" >"${FAKE}/list.json"; }
ledger() { # ledger <号> <#31 的勾选：x 或空格>
  printf '[验收] v2026.2.0\n\n<!-- release-ledger:begin since=v2026.1.0 -->\n- [%s] #31 ui | 待验 @v2026.2.0-test.1 | 场景：#131：A\n<!-- release-ledger:end -->\n' "$2" >"${FAKE}/ledger.$1"
}
run() { # run <脚本> <期望退出码> <描述> <TAG>
  local script="$1" want="$2" desc="$3" tag="$4" rc
  : >"${TMP}/summary"
  (cd "$R" && PATH="${TMP}/bin:${PATH}" FAKE="$FAKE" TAG="$tag" GH_TOKEN=x PPASS_HOOK_REPO=o/r \
    GITHUB_SHA="$HEAD_SHA" GITHUB_STEP_SUMMARY="${TMP}/summary" RUNNER_TEMP="$TMP" bash "$script") >"${TMP}/out" 2>&1
  rc=$?
  if [ "$rc" = "$want" ]; then ok "$desc"; else bad "${desc}（期望 ${want}，实际 ${rc}：$(tr '\n' ' ' <"${TMP}/out")）"; fi
}
has() { grep -qF -- "$1" "$2"; }

cases() { # cases <脚本> <模式：gate 或 mutant>
  local s="$1" m="$2" red=1
  [ "$m" = gate ] || red=0
  ledger 501 ' '
  list '[{"number":501,"title":"[验收] v2026.2.0"},{"number":9,"title":"[REL] 出 v2026.2.0-test.1"}]'
  run "$s" "$red" "有一项没勾 → $([ "$red" = 1 ] && echo 红 || echo 不再红)" v2026.2.0
  if [ "$m" = gate ]; then
    has "#31（ui）待验 @v2026.2.0-test.1" "${TMP}/out" && ok "  点名 #31" || bad "  没点名 #31：$(cat "${TMP}/out")"
    has "#31（ui）待验" "${TMP}/summary" && ok "  待验项写进 job 摘要" || bad "  摘要里没有待验项：$(cat "${TMP}/summary")"
  fi
  list '[{"number":9,"title":"[REL] 出 v2026.2.0-test.1"},{"number":10,"title":"[验收] v2026.2.0 草稿"}]'
  run "$s" "$red" "没有标题恰为「[验收] v2026.2.0」的台账（只有相似标题）→ $([ "$red" = 1 ] && echo 红 || echo 不再红)" v2026.2.0
  [ "$m" = gate ] && { has "没有标题为「[验收] v2026.2.0」的验收台账" "${TMP}/out" && ok "  说明没有台账" || bad "  没说明：$(cat "${TMP}/out")"; }
  ledger 502 x
  list '[{"number":501,"title":"[验收] v2026.2.0"},{"number":502,"title":"[验收] v2026.2.0"}]'
  run "$s" "$red" "同名台账两张 → $([ "$red" = 1 ] && echo 红 || echo 不再红)" v2026.2.0
  [ "$m" = gate ] && { has "有 2 张（#501 #502）" "${TMP}/out" && ok "  点名两张" || bad "  没点名两张：$(cat "${TMP}/out")"; }
}

echo "==> 五种情况"
ledger 501 x
list '[{"number":501,"title":"[验收] v2026.2.0"},{"number":9,"title":"[REL] 出 v2026.2.0-test.1"}]'
run "${TMP}/gate.sh" 0 "台账全勾 → 过" v2026.2.0
has "发版前验收通过（台账 #501" "${TMP}/out" && ok "  判定来自 release-acceptance.sh（台账 #501、候选 = GITHUB_SHA）" || bad "  没跑判定：$(cat "${TMP}/out")"
cases "${TMP}/gate.sh" gate
rm -f "${FAKE}/list.json"
ledger 501 x  # 台账本身全勾：去掉上限判定就会放行，这条才能证明红来自上限判定
list "$(python3 -c 'import json; print(json.dumps([{"number": 501, "title": "[验收] v2026.2.0"}] + [{"number": 1000 + i, "title": f"[REL] v2026.2.0 第 {i} 张"} for i in range(99)]))')"
run "${TMP}/gate.sh" 1 "搜索结果到 100 条上限（可能截掉第二张同名台账）→ 红（fail-closed）" v2026.2.0
has "达到 100 条上限" "${TMP}/out" && ok "  说明判不了唯一" || bad "  没说明：$(cat "${TMP}/out")"
touch "${FAKE}/list.fail"
run "${TMP}/gate.sh" 0 "test tag → 不查（gh 坏着也不碰）" v2026.2.0-test.2
has "不查验收台账" "${TMP}/out" && ok "  说明不查" || bad "  没说明：$(cat "${TMP}/out")"
run "${TMP}/gate.sh" 1 "读不到 GitHub → 红（fail-closed）" v2026.2.0
rm -f "${FAKE}/list.fail"

echo "==> 反证：去掉判定（run 换成只打印），三条红必须转绿"
cases "${TMP}/gate-mutant.sh" mutant

echo
echo "通过 ${PASS}，失败 ${FAIL}"
[ "$FAIL" = 0 ]
