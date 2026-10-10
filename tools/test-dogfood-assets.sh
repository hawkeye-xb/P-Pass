#!/usr/bin/env bash
# REL-08 (#510) 门禁：release 资产里的 shell 脚本在「只有资产」的干净目录里
# 必须自足——不许 source 资产之外的文件，也不许靠仓库布局兜底。
#
# 判据（对 tools/stage-dogfood-scripts.sh 的产出）：
#   1. 暂存到仓库之外的空目录；每个 .sh 过 `bash -n`；
#   2. 每个 .sh 里的 `source` / `.` 目标必须是「同目录 + 单个文件名」，且该
#      文件就在暂存目录里（资产平铺，`$ROOT/tools/x.sh` 这种在资产里不存在）；
#   3. 换一个无关 cwd 跑暂存目录里的 `dogfood-smoke.sh --help`：它在 set -e 下
#      先 source helper 再解析参数，helper 缺失即非零；
#   4. workflow 不许绕过暂存脚本直接 `cp tools/*.sh`，且 artifacts.yml 的
#      paths 过滤覆盖清单里的每个文件（改 helper 也要重打资产）；
#   5. 每个 .sh 过 shellcheck SC2251：`! cmd` 在 set -e 下不会失败，写成断言
#      就是空转（#510 顺带修掉的脱敏抽查就是这样永远绿的）。shellcheck 缺失
#      直接红，不静默跳过。
# 可选：PPF_SMOKE_BIN_DIR=<含 daemon/testclient(/lib) 的目录> 时，把它们也
# 放进暂存目录，从无关 cwd 跑完整冒烟，期望 ALL GREEN（验收「干净目录只用
# release 资产跑通」）。
#
# 反证：`--self-test` 对清单/脚本/workflow 各做一次变异，门禁必须全红，
# 未变异的基线必须绿。CI 先跑反证再跑门禁——反证挂了就别信门禁的绿。
#
# 用法: tools/test-dogfood-assets.sh [--self-test]
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# 所有临时目录都建在同一个根下：mktmp 常在 $(...) 子 shell 里调用，往数组
# 里登记会丢，统一根目录才能在 EXIT 时一把清干净。
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/ppf-assets.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT
mktmp() { mktemp -d "$TMPROOT/d.XXXXXX"; }

fail() { echo "FAIL: $*" >&2; return 1; }

# check_scripts <含 stage-dogfood-scripts.sh 的 tools 目录>
check_scripts() {
  local tools="$1" dest cwd listed f line target
  dest="$(mktmp)/assets"
  listed="$(bash "$tools/stage-dogfood-scripts.sh" "$dest")" || fail "暂存脚本失败" || return 1
  [[ -n "$listed" ]] || fail "暂存清单为空" || return 1

  # 暂存目录里只应有清单打印的文件（清单即 stdout，二者不许分叉）
  for f in "$dest"/*; do
    printf '%s\n' "$listed" | grep -qxF "$f" || fail "暂存目录多出未列入 stdout 的文件: $f" || return 1
  done

  for f in "$dest"/*.sh; do
    bash -n "$f" || fail "bash -n 不过: $(basename "$f")" || return 1
    command -v shellcheck >/dev/null || fail "找不到 shellcheck（SC2251 检查不能跳过）" || return 1
    shellcheck --include=SC2251 "$f" >&2 \
      || fail "$(basename "$f") 有 set -e 下不生效的 \`! cmd\` 断言（SC2251）" || return 1
    # 取所有 source / . 行（忽略注释）；目标形如 "$VAR/name.sh" 或 "${VAR}/name.sh"
    while IFS= read -r line; do
      target="$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]*(source|\.)[[:space:]]+//; s/[[:space:]].*$//; s/"//g')"
      if ! printf '%s\n' "$target" | grep -qE '^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/[^/]+$'; then
        fail "$(basename "$f") source 了非同目录路径: $target（资产是平铺的，只能 source 同目录文件）" || return 1
      fi
      [[ -f "$dest/${target##*/}" ]] \
        || fail "$(basename "$f") source 的 ${target##*/} 不在资产清单里（tools/stage-dogfood-scripts.sh）" || return 1
    done < <(grep -E '^[[:space:]]*(source|\.)[[:space:]]+' "$f" || true)
  done

  [[ -f "$dest/dogfood-smoke.sh" ]] || fail "清单里没有 dogfood-smoke.sh" || return 1
  cwd="$(mktmp)"
  (cd "$cwd" && bash "$dest/dogfood-smoke.sh" --help >/dev/null) \
    || fail "干净目录里 dogfood-smoke.sh --help 非零（helper 没加载上？）" || return 1

  if [[ -n "${PPF_SMOKE_BIN_DIR:-}" ]]; then
    cp -R "$PPF_SMOKE_BIN_DIR"/. "$dest"/
    if ! (cd "$cwd" && bash "$dest/dogfood-smoke.sh" "$cwd/work") 2>&1 | tee "$cwd/smoke.out"; then
      tail -5 "$cwd/work/daemon.err" 2>/dev/null >&2 || true
      fail "干净目录完整冒烟失败"; return 1
    fi
    grep -q 'DOGFOOD SMOKE: ALL GREEN' "$cwd/smoke.out" || fail "完整冒烟未 ALL GREEN" || return 1
  fi
}

# check_workflows <workflows 目录> <tools 目录>
check_workflows() {
  local wf="$1" tools="$2" hits f
  hits="$(grep -nE 'cp[[:space:]]+([^|;&]*[[:space:]])?tools/[^[:space:]]+\.sh' "$wf"/*.yml || true)"
  [[ -z "$hits" ]] || fail "workflow 绕过暂存脚本直接 cp tools/*.sh:
$hits" || return 1
  grep -q 'tools/stage-dogfood-scripts.sh' "$wf/artifacts.yml" || fail "artifacts.yml 没调暂存脚本" || return 1
  for f in stage-dogfood-scripts.sh $(sed -n '/^SCRIPTS=(/,/^)/p' "$tools/stage-dogfood-scripts.sh" | grep -oE '[A-Za-z0-9_.-]+\.sh'); do
    grep -qF "\"tools/$f\"" "$wf/artifacts.yml" || fail "artifacts.yml paths 过滤缺 tools/$f" || return 1
  done
}

run_gate() { # run_gate <tools> <workflows>
  check_scripts "$1" && check_workflows "$2" "$1"
}

self_test() {
  local base t w rc=0
  base="$(mktmp)"
  mkdir -p "$base/tools" "$base/wf"
  cp "$REPO/tools/stage-dogfood-scripts.sh" "$REPO/tools/dogfood-smoke.sh" "$REPO/tools/ipc-lib.sh" "$base/tools/"
  cp "$REPO/.github/workflows/"*.yml "$base/wf/"

  expect() { # expect <green|red> <名字> <tools> <wf>
    local want="$1" name="$2" got
    if PPF_SMOKE_BIN_DIR='' run_gate "$3" "$4" >/dev/null 2>"$base/err"; then got=green; else got=red; fi
    if [[ "$got" == "$want" ]]; then
      echo "ok   [$want] $name"
      [[ "$got" == green ]] || grep -m1 '^FAIL' "$base/err" | sed 's/^/       ↳ /' || true
    else
      echo "BAD  期望 $want 实得 $got: $name"; cat "$base/err"; rc=1
    fi
  }
  mut() { # mut <名字>：复制基线，echo 新根
    t="$(mktmp)"; cp -R "$base/tools" "$base/wf" "$t/"; echo "$t"
  }

  expect green "基线（未变异）" "$base/tools" "$base/wf"

  w="$(mut)"; sed -i.bak '/^  ipc-lib.sh/d' "$w/tools/stage-dogfood-scripts.sh"
  expect red "清单去掉 ipc-lib.sh（#510 原样复现）" "$w/tools" "$w/wf"

  w="$(mut)"
  # shellcheck disable=SC2016 # 变异文本里的 $HERE 就是要字面量
  sed -i.bak 's#^source "\$HERE/ipc-lib.sh"#source "$HERE/../tools/ipc-lib.sh"#' "$w/tools/dogfood-smoke.sh"
  grep -q 'HERE/../tools/ipc-lib.sh' "$w/tools/dogfood-smoke.sh" || { echo "BAD 变异没打上"; rc=1; }
  expect red "smoke 改回按仓库布局 source helper" "$w/tools" "$w/wf"

  w="$(mut)"
  # shellcheck disable=SC2016 # 变异文本里的 $HERE 就是要字面量
  printf '\n# shellcheck source=./extra.sh\nsource "$HERE/extra.sh"\n' >> "$w/tools/ipc-lib.sh"
  expect red "helper 新增 source 了清单外文件" "$w/tools" "$w/wf"

  # #539 起 release.yml 不再暂存这些脚本（macOS zip 已从正式发布去掉），资产只经 artifacts.yml 出。
  w="$(mut)"; sed -i.bak 's#tools/stage-dogfood-scripts.sh /tmp/bin#tools/stage-dogfood-scripts.sh /tmp/bin; cp tools/dogfood-smoke.sh /tmp/bin/#' "$w/wf/artifacts.yml"
  grep -q 'cp tools/dogfood-smoke.sh /tmp/bin/' "$w/wf/artifacts.yml" || { echo "BAD 变异没打上"; rc=1; }
  expect red "artifacts.yml 绕过暂存脚本直接 cp" "$w/tools" "$w/wf"

  w="$(mut)"
  sed -i.bak 's#^echo "DOGFOOD SMOKE: ALL GREEN"#! grep -q leak /dev/null\n&#' "$w/tools/dogfood-smoke.sh"
  grep -q '^! grep -q leak' "$w/tools/dogfood-smoke.sh" || { echo "BAD 变异没打上"; rc=1; }
  expect red "smoke 写回 set -e 下空转的 \`! cmd\` 断言（SC2251）" "$w/tools" "$w/wf"

  w="$(mut)"; sed -i.bak '/"tools\/ipc-lib.sh"/d' "$w/wf/artifacts.yml"
  expect red "artifacts.yml paths 过滤漏掉 ipc-lib.sh" "$w/tools" "$w/wf"

  return "$rc"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test && echo "SELF-TEST: ALL MUTATIONS CAUGHT"
else
  run_gate "$REPO/tools" "$REPO/.github/workflows"
  echo "DOGFOOD ASSETS: OK"
fi
