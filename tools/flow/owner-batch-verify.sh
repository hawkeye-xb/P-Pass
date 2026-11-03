#!/usr/bin/env bash
# just batch-verify：在批次分支上跑本地全量验证，结果写批次报告。说明见 docs/runbook/owner.md。
#
# 顺序（任何一步红即停：写 issue，报告标 FAIL，不能开 PR）：
#   1. 有 ppf-decoder 这个 bin 就先构建（daemon 测试要拉起它，裸 cargo test 不会顺带构建）
#   2. just ci
#   3. 全部 tools/test-*.sh
#   4. CI 对照表（tools/flow/ci-local-map.tsv）里本机能跑的全部步骤：tools/flow/owner-ci-local.sh，
#      按与 CI 同一套路径判定裁剪（含 iOS 模拟器上的 App 测试与 TransportFFITests、Android 构建与 lint、
#      桌面壳、各 Rust job；Rust 测试前先构建 ppf-decoder）
#      （2、3、4 都把 GIT_TEMPLATE_DIR 设空：本机全局 git 模板里的身份 hook 会拦测试临时仓库里
#      夹具的假身份，造成与改动无关的红）
#   5. 对照表里 Windows 的步骤：tools/flow/owner-win-test.sh（交互会话计划任务；没配置算未覆盖）
#   6. 受影响端（按 tools/ci-paths.sh 判定）的真机验证：
#        mac / android 任一受影响 → just verify --all（全量场景库 V2，含各卡声明的场景；
#                        场景库存在时；最后一行必须是 VERIFY PASS）
#        ios           → 真机场景库未收编，算未覆盖
#      未覆盖的端不算绿也不算红：写进报告与 PR 正文的「未覆盖项」，留给 test 回归。
#   报告另列「只能 CI」（对照表里本地跑不了的检查）与「CI 判定不用跑」的 job。
# 报告：<git 公共目录>/ppass-batch/<批次>/verify-<提交>/report.md，绑定验证时的 HEAD。
# 之后 HEAD 再变（加了提交），batch-pr 会拒绝，必须重跑本命令。

set -uo pipefail
# shellcheck source=tools/flow/owner-lib.sh
source "$(cd "$(dirname "$0")" && pwd)/owner-lib.sh"

# 开工前自检：位置、shell、提交拦截、gh、提交身份、磁盘、私仓模式。不过就停，不带病继续。
bash "${FLOW_DIR}/doctor.sh" || exit 1

case "${1:-}" in "") ;; *) sed -n 2,22p "$0" | sed 's/^# \{0,1\}//'; exit 2 ;; esac

require_batch
fetch_origin
git merge-base --is-ancestor origin/main HEAD ||
  refuse "origin/main 在开批次之后前进了，本批次已过时" \
    "按同样的卡重开一批（新主题名）：just batch-open <新主题> $(state_get "$BATCH" ISSUES)"

SHA="$(git rev-parse HEAD)"
OUT="$(batch_dir "$BATCH")/verify-${SHA:0:12}"
rm -rf "$OUT"
mkdir -p "$OUT"
REPORT="${OUT}/report.md"
EMPTY_TPL="${OUT}/empty-git-template"
mkdir -p "$EMPTY_TPL"
state_set "$BATCH" VERIFIED_SHA ""
UNCOVERED=()
ROWS=""

{
  printf '# 批次验证报告：%s\n\n' "$BATCH"
  printf -- '- 提交：`%s`\n- 基准 origin/main：`%s`\n- 卡：%s\n- 开始：%s\n\n' \
    "$SHA" "$(git rev-parse origin/main)" "$(state_get "$BATCH" ISSUES | sed 's/[0-9][0-9]*/#&/g')" "$(date '+%Y-%m-%d %H:%M %z')"
} >"$REPORT"

finish() { # finish PASS|FAIL
  {
    printf '| 步骤 | 结果 | 用时 | 日志 |\n|---|---|---|---|\n%s\n' "$ROWS"
    for sec in "只能 CI:ci-only.md" "CI 判定不用跑:skipped.md"; do
      f="${OUT}/ci-local/${sec#*:}"
      if [ -s "$f" ]; then printf '\n## %s\n\n' "${sec%%:*}"; cat "$f"; fi
    done
    printf '\n## 未覆盖项\n\n'
    if [ "${#UNCOVERED[@]}" -eq 0 ]; then
      printf '无\n'
    else
      printf -- '- %s\n' "${UNCOVERED[@]}"
    fi
    printf '\nBATCH-VERIFY %s %s\n' "$1" "$SHA"
  } >>"$REPORT"
}

run_step() { # run_step <名字> <命令...>
  local name="$1" slug log t0 rc
  shift
  slug="$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')"
  log="${OUT}/${slug}.log"
  step "$name"
  t0=$(date +%s)
  "$@" >"$log" 2>&1
  rc=$?
  local dt=$(($(date +%s) - t0))
  if [ "$rc" -eq 0 ]; then
    ROWS="${ROWS}| ${name} | PASS | ${dt}s | ${log} |
"
    okmsg "${name}（${dt}s）"
    return 0
  fi
  ROWS="${ROWS}| ${name} | FAIL（退出码 ${rc}） | ${dt}s | ${log} |
"
  tail -n 30 "$log" >&2
  finish FAIL
  die_stuck "批次 ${BATCH} 本地验证红：${name}（退出码 ${rc}），没有开 PR" --log "$log"
}

# 1. ppf-decoder
pkg="$(cargo metadata --no-deps --format-version 1 2>/dev/null | python3 -c '
import json, sys
for p in json.load(sys.stdin)["packages"]:
    for t in p["targets"]:
        if t["name"] == "ppf-decoder" and "bin" in t["kind"]:
            print(p["name"]); sys.exit()
' 2>/dev/null)"
if [ -n "$pkg" ]; then
  run_step "构建 ppf-decoder" heavy env CARGO_INCREMENTAL=0 cargo build -p "$pkg" --bin ppf-decoder
else
  say "（工作区没有 ppf-decoder 这个 bin，跳过预构建）"
fi

# 2. just ci
run_step "just ci" heavy env CARGO_INCREMENTAL=0 GIT_TEMPLATE_DIR="$EMPTY_TPL" "$JUST" ci

# 3. tools/test-*.sh
for t in "$REPO_ROOT"/tools/test-*.sh; do
  [ -f "$t" ] || continue
  run_step "$(basename "$t")" env GIT_TEMPLATE_DIR="$EMPTY_TPL" bash "$t"
done

BASE="$(git merge-base HEAD origin/main)"

# 4. CI 对照表里本机的步骤（各步自己取重编译锁，外面不套 heavy）
step "CI 对照表：本机步骤"
GIT_TEMPLATE_DIR="$EMPTY_TPL" bash "${FLOW_DIR}/owner-ci-local.sh" --out "${OUT}/ci-local" --base "$BASE" \
  >"${OUT}/ci-local.log" 2>&1
rc=$?
[ ! -s "${OUT}/ci-local/rows.md" ] || ROWS="${ROWS}$(cat "${OUT}/ci-local/rows.md")
"
if [ "$rc" -ne 0 ]; then
  tail -n 30 "${OUT}/ci-local.log" >&2
  failed="$(sed -n 's/^CI-LOCAL FAIL //p' "${OUT}/ci-local.log" | tail -1)"
  ROWS="${ROWS}| CI 对照表：本机步骤 | FAIL（${failed:-退出码 ${rc}}） | - | ${OUT}/ci-local.log |
"
  finish FAIL
  die_stuck "批次 ${BATCH} 本地验证红：CI 对照表 ${failed:-（退出码 ${rc}）}，没有开 PR" --log "${OUT}/ci-local.log"
fi
okmsg "$(tail -1 "${OUT}/ci-local.log")"

# 5. Windows（对照表里 where=win 的步骤，判定与 CI 同一口径）
log="${OUT}/windows.log"
step "Windows 步骤（交互会话）"
bash "${FLOW_DIR}/owner-win-test.sh" "$log" --base "$BASE"
rc=$?
case "$rc" in
  0) ROWS="${ROWS}| Windows 步骤（交互会话） | PASS | - | ${log} |
" ;;
  3) UNCOVERED+=("windows：$(tail -1 "$log")") ;;
  5) say "Windows：对照表判定这次不用跑" ;;
  *)
    ROWS="${ROWS}| Windows 步骤（交互会话） | FAIL（${rc}） | - | ${log} |
"
    finish FAIL
    die_stuck "批次 ${BATCH} Windows 验证没过（退出码 ${rc}：1=测试红，4=判定不了）" --log "$log"
    ;;
esac

# 6. 受影响端的真机
END_android="apps/android/** assets/i18n/** crates/transport/** crates/proto/** crates/pair-pake/**"
END_mac="crates/** apps/desktop/** assets/** tools/testclient/** tools/mac-dev.sh tools/bundle-*.sh tools/daemon-helper-macos.sh"
END_ios="apps/ios/** assets/i18n/** crates/transport/** crates/proto/** crates/pair-pake/** tools/ios/** tools/build-ios-*"
hit_end() {
  local globs
  eval "globs=\"\$END_$1\""
  set -f
  # shellcheck disable=SC2086
  [ "$(bash "${REPO_ROOT}/tools/ci-paths.sh" hit "$BASE" $globs 2>/dev/null)" != false ]
  local r=$?
  set +f
  return $r
}
has_verify() { "$JUST" --summary 2>/dev/null | tr ' ' '\n' | grep -qx verify; }

ENDS=""
for e in android mac ios; do hit_end "$e" && ENDS="${ENDS} ${e}"; done
say "受影响端：${ENDS:- 无}"

# 不套 heavy：tools/e3/verify 自己给重编译取 heavy-build 锁，外面再套一层会自己等自己。
# mac / android 任一受影响就跑一次全量场景库（V2）：合批后的代码上，每张卡声明的场景都要再跑一遍，
# 防「各自绿、合起来红」。
case " $ENDS " in
  *" mac "* | *" android "*)
    if ! has_verify; then
      for e in $ENDS; do
        case "$e" in mac | android) UNCOVERED+=("${e}：场景库（just verify）不在本分支，真机没跑") ;; esac
      done
    else
      run_step "just verify --all" "$JUST" verify --all
      log="${OUT}/just_verify_--all.log"
      last="$(grep -E '^VERIFY ' "$log" | tail -1)"
      case "$last" in
        "VERIFY PASS（不完整）"*) UNCOVERED+=("mac/android 场景库：${last}") ;;
        "VERIFY PASS"*) ;;
        *)
          finish FAIL
          die_stuck "批次 ${BATCH}：just verify --all 退出 0 但没有 VERIFY PASS 汇总行，判定不了" --log "$log"
          ;;
      esac
    fi
    ;;
esac
case " $ENDS " in *" ios "*) UNCOVERED+=("ios：真机场景库未收编 iOS，真机没跑（模拟器测试已在对照表步骤里）") ;; esac

finish PASS
state_set "$BATCH" VERIFIED_SHA "$SHA"
state_set "$BATCH" REPORT "$REPORT"
printf '\nBATCH-VERIFY PASS %s\n' "$SHA"
say "报告：${REPORT}"
[ "${#UNCOVERED[@]}" -eq 0 ] || say "未覆盖 ${#UNCOVERED[@]} 项（会写进 PR 正文）"
say "下一步：just batch-pr"
