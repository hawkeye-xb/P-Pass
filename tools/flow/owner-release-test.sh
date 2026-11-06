#!/usr/bin/env bash
# just release-test <端...>：在 origin/main 最新提交上触发 test 发版（release.yml，release=true），等 Release workflow 出结论。
# 说明见 docs/runbook/owner.md；规则见 docs/RELEASING.md §3.6、§4。
#
#   owner-release-test.sh android macos            端 ∈ android macos windows ios，至少一个
#   owner-release-test.sh --base 0.10.4 android    换新的 X.Y.Z（必须高于最新 test tag 的 X.Y.Z）
#   owner-release-test.sh --dry-run android        只做第 1~3 步的判定，不打 tag、不写 GitHub
#
# 只做 test tag。正式版（不带 -test. 的版本号、发布 draft、--formal 之类）一律拒绝：
# 正式发布只能由产品负责人在网页上做。
#
# 判定（任何一条不过即拒绝或停下；tag 永不移动、永不复用，失败了下一次用 -test.N+1）：
#   1. 版本号 = 远端最新 v<X.Y.Z>-test.N 的 N+1；X.Y.Z 必须高于 release/versions.json 里每一端的
#      正式版本号（否则 test 设备收不到），不满足就拒绝并给出建议的 --base。
#   2. test tag 没有手写更新说明文件（docs/release-notes-rules.md）：release/notes/ 下不许有这个版本的文件；
#      有 node 时跑一遍 tools/release-notes.mjs lint。
#   3. 打 tag 前在 origin/main 上本地跑 tools/release/plan-builds.sh：它判「构建」的端必须
#      恰好等于参数给的端（不一致说明对改动的理解有误，先停下核对）。
#   3b. origin/main 这个提交的 CI 跑完且没有红（main 必须是绿的，RELEASING §3）：看这个提交上所有在 main 上
#      push 触发的 workflow 运行（不限名单，与「main 红了开卡」#1469 同取 event=push、branch=main），加上 commit status；
#      同一提交上别的事件触发的运行（临时分支上手动触发的 Release 等）不算，上一次发版失败不挡同号重试（#1396）。
#      还在跑就等（上限 PPASS_OWNER_MAIN_CI_WAIT 秒），红了或读不到就停下。
#      一条 run 都没有时先等 PPASS_OWNER_MAIN_CI_EMPTY_WAIT 秒再认。
#   4. 手动触发 release.yml（release=true，tag 由流程在验证全绿后才建，这里不推 tag）；找到这次 run，gh run watch 到结论（上限
#      PPASS_OWNER_RELEASE_TIMEOUT 秒，默认 14400）；红 ⇒ 失败 job 日志切片写 issue，停下。
#   5. 绿了再核对 test-channel 里每个端的分端清单 version = 本次版本号。

set -uo pipefail
# shellcheck source=tools/flow/owner-lib.sh
source "$(cd "$(dirname "$0")" && pwd)/owner-lib.sh"

# 开工前自检：位置、shell、提交拦截、gh、提交身份、磁盘、私仓模式。不过就停，不带病继续。
bash "${FLOW_DIR}/doctor.sh" || exit 1

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
FORMAL_MSG="正式版只能由产品负责人发布（docs/RELEASING.md §3 第 5 步：在网页上审 draft 后 Publish）；owner 脚本只打 test tag"
TIMEOUT="${PPASS_OWNER_RELEASE_TIMEOUT:-14400}"
RUN_WAIT="${PPASS_OWNER_RUN_WAIT:-600}"  # 触发后等 Release run 出现的上限（秒）
MAIN_CI_WAIT="${PPASS_OWNER_MAIN_CI_WAIT:-3600}"   # 等 origin/main 的检查跑完的上限（秒）
MAIN_CI_EMPTY_WAIT="${PPASS_OWNER_MAIN_CI_EMPTY_WAIT:-180}"  # 一条检查都没有时，等它们注册的时长

BASE_VER=""
DRY=0
ENDS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      BASE_VER="${2:-}"
      shift
      [[ "$BASE_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || refuse "--base 要跟 X.Y.Z（不带 v、不带后缀）"
      ;;
    --dry-run) DRY=1; export PPASS_OWNER_DRY=1 ;;
    android | macos | windows | ios)
      case " ${ENDS[*]-} " in *" $1 "*) ;; *) ENDS+=("$1") ;; esac
      ;;
    v[0-9]* | [0-9]*.[0-9]*)
      case "$1" in
        *-test.*) refuse "不用手写版本号" "版本号由脚本按规则算：just release-test <端...>（换 X.Y.Z 用 --base）" ;;
        *) refuse "「$1」是正式版本号。${FORMAL_MSG}" ;;
      esac
      ;;
    --formal | formal | stable | --stable | release | publish | --publish | --rc | --beta)
      refuse "「$1」：${FORMAL_MSG}"
      ;;
    -h | --help) usage ;;
    *) refuse "不认识的参数「$1」" "端只能是 android macos windows ios。" ;;
  esac
  shift
done
[ "${#ENDS[@]}" -gt 0 ] || usage

need_gh
fetch_origin
MAIN="$(git rev-parse origin/main)"
OUT="${STATE_DIR}/release-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"

semver_gt() { # semver_gt A B：A > B（X.Y.Z）
  local IFS=.
  # shellcheck disable=SC2206
  local a=($1) b=($2) i
  for i in 0 1 2; do
    [ "${a[$i]}" -gt "${b[$i]}" ] && return 0
    [ "${a[$i]}" -lt "${b[$i]}" ] && return 1
  done
  return 1
}

step "算版本号"
tags="$(git ls-remote --tags --refs origin 'v*-test.*' 2>/dev/null | sed 's#.*refs/tags/##')" ||
  die_stuck "读不到远端 tag 列表"
latest="$(printf '%s\n' "$tags" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+-test\.[0-9]+$' |
  sed -E 's/^v([0-9]+)\.([0-9]+)\.([0-9]+)-test\.([0-9]+)$/\1 \2 \3 \4/' |
  sort -n -k1,1 -k2,2 -k3,3 -k4,4 | tail -1)"
[ -n "$latest" ] || die_stuck "远端没有任何 v<X.Y.Z>-test.N tag，判定不了下一个版本号"
set -- $latest
LATEST_BASE="$1.$2.$3"
LATEST_N="$4"
if [ -n "$BASE_VER" ]; then
  semver_gt "$BASE_VER" "$LATEST_BASE" ||
    refuse "--base ${BASE_VER} 不高于最新 test tag 的 ${LATEST_BASE}" "test 版本号必须单调上升，test 设备才能互相升级。"
  N=1
else
  BASE_VER="$LATEST_BASE"
  N=$((LATEST_N + 1))
fi
# Git Bash 会把 origin/main:<path> 的冒号当路径分隔符改写；禁止 MSYS 做路径转换。
vers="$(MSYS_NO_PATHCONV=1 git show origin/main:release/versions.json 2>/dev/null)" || die_stuck "读不到 origin/main 的 release/versions.json"
maxv="$(printf '%s' "$vers" | python3 -c '
import json, sys
d = json.load(sys.stdin)
vs = [d[k] for k in ("desktop", "android", "ios") if isinstance(d.get(k), str)]
print(max(vs, key=lambda v: tuple(int(x) for x in v.split("."))))
')" || die_stuck "解析 release/versions.json 失败"
if ! semver_gt "$BASE_VER" "$maxv"; then
  IFS=. read -r a b c <<EOF
$maxv
EOF
  refuse "test 版本 ${BASE_VER}-test.N 不高于正式版本线 ${maxv}，test 设备会收不到" \
    "改用更高的 X.Y.Z：just release-test --base ${a}.${b}.$((c + 1)) ${ENDS[*]}"
fi
VER="${BASE_VER}-test.${N}"
TAG="v${VER}"
printf '%s\n' "$tags" | grep -qx "$TAG" && die_stuck "算出的 ${TAG} 已存在，tag 不复用，判定不了"
okmsg "${TAG}（上一个：v${LATEST_BASE}-test.${LATEST_N}；正式线最高 ${maxv}）"

step "更新说明文件"
if git ls-tree -r --name-only origin/main -- release/notes | grep -F "/${VER}." >/dev/null; then
  die_stuck "release/notes/ 下有 ${VER} 的文件：test tag 不写手写更新说明（docs/release-notes-rules.md）"
fi
tmpwt="$(mktemp -d)/main"
git worktree add -q --detach "$tmpwt" "$MAIN" || die_stuck "开临时 worktree 失败"
trap 'git worktree remove --force "$tmpwt" >/dev/null 2>&1; rm -rf "$(dirname "$tmpwt")"' EXIT
if command -v node >/dev/null 2>&1 && [ -f "${tmpwt}/tools/release-notes.mjs" ]; then
  (cd "$tmpwt" && node tools/release-notes.mjs lint release/notes) >"${OUT}/notes-lint.log" 2>&1 ||
    die_stuck "release/notes 没过 lint" --log "${OUT}/notes-lint.log"
  okmsg "release/notes lint 通过；test tag 不需要说明文件"
else
  say "（没有 node，跳过 release/notes lint；test tag 本来就不需要说明文件）"
fi

step "按端判定（tools/release/plan-builds.sh，origin/main ${MAIN:0:10}）"
(cd "$tmpwt" && TAG="$TAG" GITHUB_OUTPUT="" bash tools/release/plan-builds.sh) >"${OUT}/plan.log" 2>&1 ||
  die_stuck "plan-builds 判定失败（所有端都没有改动时也会这样）" --log "${OUT}/plan.log"
PLANNED="$(sed -nE 's/^(android|macos|windows|ios)=build$/\1/p' "${OUT}/plan.log" | sort | tr '\n' ' ')"
WANT="$(printf '%s\n' "${ENDS[@]}" | sort | tr '\n' ' ')"
cat "${OUT}/plan.log" >&2
[ "$PLANNED" = "$WANT" ] ||
  refuse "plan-builds 会构建「${PLANNED% }」，与你给的「${WANT% }」不一致" \
    "test tag 按改动路径自动决定构建哪几端，不能指定。核对这批改了什么；确认无误就按判定结果重跑：just release-test ${PLANNED% }"
okmsg "将构建：${PLANNED% }"

step "origin/main ${MAIN:0:10} 的 CI"
# main 的 CI = 这个提交上所有在 main 上 push 触发的 workflow 运行，不限名单（名单外的 CI Secrets、
# Dogfood 等红了也要拦）。不读提交上的全部 check run：同一提交上失败的 Release
# （release-run/<tag> 上的 workflow_dispatch）也挂在这个提交上，会被误判成 main 红，
# tag 没建成也无法同号重试（#1396）。
waited=0
while :; do
  # jq 只取字段（名字可能带空格，放最后、tab 分隔）；事件、分支的过滤在下面 awk 里做。
  raw="$(gh api "repos/${REPO}/actions/runs?head_sha=${MAIN}&event=push&branch=main&per_page=100" \
    --jq '.workflow_runs[] | "\(.status)\t\(.conclusion // "-")\t\(.event)\t\(.head_branch)\t\(.name)"' 2>&1)" ||
    die_stuck "读不到 origin/main ${MAIN:0:10} 的 CI 运行结果：$(printf '%s' "$raw" | head -1)"
  runs="$(printf '%s\n' "$raw" | awk -F'\t' 'NF >= 5 && $3 == "push" && $4 == "main" { print $1 " " $2 " " $5 }')"
  st="$(gh api "repos/${REPO}/commits/${MAIN}/status" --jq '"\(.state) \(.total_count)"' 2>&1)" ||
    die_stuck "读不到 origin/main ${MAIN:0:10} 的 commit status：$(printf '%s' "$st" | head -1)"
  red="$(printf '%s\n' "$runs" | awk '$1 == "completed" && $2 != "success" && $2 != "skipped" && $2 != "neutral"' | head -5)"
  case "$st" in failure* | error*) red="${red}
commit status: ${st}" ;; esac
  [ -z "$(printf '%s' "$red" | tr -d '[:space:]')" ] ||
    die_stuck "origin/main ${MAIN:0:10} 的 CI 有红，不打 test tag：$(printf '%s' "$red" | sed '/^$/d' | tr '\n' ';')"
  pending="$(printf '%s\n' "$runs" | awk 'NF && $1 != "completed"' | wc -l | tr -d ' ')"
  case "$st" in "pending "[1-9]*) pending=$((pending + 1)) ;; esac
  total="$(printf '%s\n' "$runs" | awk 'NF' | wc -l | tr -d ' ')"
  if [ "$pending" -eq 0 ] && [ "$total" -gt 0 ]; then
    okmsg "origin/main 的 ${total} 条 CI 运行全部通过"
    break
  fi
  if [ "$total" -eq 0 ] && [ "$waited" -ge "$MAIN_CI_EMPTY_WAIT" ]; then
    okmsg "origin/main 这个提交没有 push 触发的任何 CI（等了 ${waited}s）"
    break
  fi
  [ "$waited" -lt "$MAIN_CI_WAIT" ] || die_stuck "origin/main ${MAIN:0:10} 的检查 ${MAIN_CI_WAIT}s 内没跑完，判定不了"
  sleep 30
  waited=$((waited + 30))
done
if [ "$DRY" = 1 ]; then
  printf '\nRELEASE-TEST DRY-RUN %s %s\n' "$TAG" "${ENDS[*]}"
  exit 0
fi

step "触发发版 ${TAG}"
# #1349：发版唯一入口 = 手动触发 release.yml（release=true）。tag 由流程在发版前验证全绿后才建，
# 这里不推 tag。触发在一条临时分支上（指向本次判定用的 origin/main 提交），这样发版前验证检出的
# 就是这个提交，期间 main 前进了也不影响；跑完删掉这条分支。
RC_BRANCH="release-run/${TAG}"
if ! git push origin "${MAIN}:refs/heads/${RC_BRANCH}" >"${OUT}/push.log" 2>&1; then
  die_stuck "推送临时分支 ${RC_BRANCH} 失败（远端没有它，可修好后重跑）" --log "${OUT}/push.log"
fi
cleanup_branch() { git push origin --delete "$RC_BRANCH" >/dev/null 2>&1 || true; }
if ! gh workflow run release.yml -R "$REPO" --ref "$RC_BRANCH" -f "tag=${TAG}" -f release=true >"${OUT}/dispatch.log" 2>&1; then
  cleanup_branch
  die_stuck "触发 release.yml（tag=${TAG}）失败，没有建任何 tag" --log "${OUT}/dispatch.log"
fi

step "等 Release workflow"
run=""
waited=0
while [ "$waited" -le "$RUN_WAIT" ]; do
  run="$(gh run list -R "$REPO" --workflow release.yml --event workflow_dispatch --limit 30 \
    --json databaseId,headBranch --jq ".[] | select(.headBranch == \"${RC_BRANCH}\") | .databaseId" 2>/dev/null | head -1)"
  [ -n "$run" ] && break
  sleep 5
  waited=$((waited + 5))
done
[ -n "$run" ] || { cleanup_branch; die_stuck "触发 ${TAG} 后 ${RUN_WAIT}s 没等到 Release run，判定不了"; }
okmsg "Release run ${run}"
bash "${REPO_ROOT}/tools/release/with-timeout.sh" "gh run watch ${run}" "$TIMEOUT" 1 -- \
  gh run watch "$run" -R "$REPO" --exit-status --interval 60 >"${OUT}/watch.log" 2>&1
cleanup_branch
concl="$(gh run view "$run" -R "$REPO" --json conclusion --jq .conclusion 2>/dev/null)"
if [ "$concl" != success ]; then
  gh run view "$run" -R "$REPO" --log-failed 2>&1 | tail -n 120 >"${OUT}/failed.log"
  die_stuck "Release ${TAG}（run ${run}）结论 ${concl:-未出}，test 包没发出来。若发版前验证就红了，没有建 tag，同一个版本号可直接重试；若 tag 已建（构建阶段红），tag 保留不动，修好后下一次用 -test.$((N + 1))" --log "${OUT}/failed.log"
fi

step "核对 test-channel 分端清单"
for e in "${ENDS[@]}"; do
  v="$(gh release download test-channel -R "$REPO" -p "manifest-${e}.json" -O - 2>/dev/null |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' 2>/dev/null)"
  [ "$v" = "$VER" ] || die_stuck "Release run ${run} 绿了，但 test-channel/manifest-${e}.json 的 version 是「${v:-读不到}」，不是 ${VER}"
  okmsg "${e}：test-channel → ${VER}"
done
printf '\nRELEASE-TEST OK %s %s\n' "$TAG" "${ENDS[*]}"
say "下一步：通知产品负责人做 test 回归（体验回归由人做）。正式发布不在 owner 职责内。"
