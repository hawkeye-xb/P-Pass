#!/usr/bin/env bash
# acceptance gate：用户看得到的改动要有产品负责人的验收记录；看不见的核心改动要有已采纳方案与测试。否则红。
#
#   acceptance-gate.sh check    --files <改动文件列表> --body <PR 正文文件> [--repo <仓库根>] [--core-rules <规则文件>] [--diff <unified diff>]
#   acceptance-gate.sh classify [--repo <仓库根>] [--core-rules <规则文件>] [--diff <unified diff>] < 改动文件列表
#                               打印 core / core-hidden / ui / notes / none
#   acceptance-gate.sh record   --body <文本文件>     文本里有没有任一格式的验收记录（0 有 / 1 没有；发版前的模块验收检查用）
#
# 级别判定与验收行判定只在这里一份：worker-done.sh（classify）、review.sh（classify + check）、CI 的 acceptance gate（check）、
# release-acceptance.sh（record）都调用本脚本，别在别处再抄一份。
#
# 口径与 owner-triage.sh 一致。「用户可见」= 界面与文案路径（owner-triage.sh 的 UI_GLOBS）或 apps/** 下的非测试文件
# （测试 = 下面 TEST_RE 圈出的位置）。核心 = .github/core-paths.txt（给了 --diff 时，只改版本号行的文件不算，见 tools/ci-paths.sh）。
#   core        命中核心且用户可见：已采纳方案（triage 时就要有）+ 验收记录；「随模块验收」只在正文同时引用已采纳方案时算数
#   core-hidden 命中核心、用户看不见（如发布链脚本，#1448）：不要验收行，要正文引用 origin/main 上「已采纳」的方案
#               （docs/decisions/<文件>.md），且改动里带测试文件（带反证的自动化测试）
#   ui          用户可见：验收记录，或整体模式「随模块验收 #<模块卡>」（#1452）
#   notes       只改更新说明（非测试文件全在 release/notes/** 与 CHANGELOG.md，且至少一个 release/notes/**）：
#               文案确认行、任一验收记录，或「随模块验收 #<模块卡>」；notes 与界面混改是 ui；只改 CHANGELOG.md 是 none
#   none        自动级，直接绿
# 验收记录（单独成行，行首可有列表/引用/加粗符号，时间处是具体日期）：
#   产品负责人 <时间> 按 SOP <链接> 操作，owner 判日志通过     （#1452 起的标准写法：owner 判定之后写）
#   产品负责人 <时间> 真机验收通过                            （旧写法，继续认）
#   产品负责人 <时间> 文案确认通过                            （只对 notes 算数）
# 退出码：0 绿 / 1 红 / 2 用法错误。

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=decision-lib.sh
. "${HERE}/decision-lib.sh"

# 单独成行：「产品负责人 <日期[ 时间]> [本地]真机验收通过」，允许行首的列表/引用/加粗符号。
ACCEPT_RE='^[*_> -]*产品负责人 ([0-9]{4}-)?[0-9]{2}-[0-9]{2}( +[0-9]{1,2}:[0-9]{2})? *(本地)?真机验收通过([*_ ]*|\*\*.*)$'
# 更新说明的文案确认行：格式同上，只是动词换成「文案确认通过」。
COPY_RE='^[*_> -]*产品负责人 ([0-9]{4}-)?[0-9]{2}-[0-9]{2}( +[0-9]{1,2}:[0-9]{2})? *文案确认通过([*_ ]*|\*\*.*)$'
# 按 SOP 验收（#1452）：「产品负责人 <时间> 按 SOP <链接> 操作，owner 判日志通过」。
SOP_RE='^[*_> -]*产品负责人 ([0-9]{4}-)?[0-9]{2}-[0-9]{2}( +[0-9]{1,2}:[0-9]{2})? *按 SOP +[^ ]+ +操作(，|,) *owner 判日志通过(。)?([*_ ]*|\*\*.*)$'
# 整体模式（#1452）：「随模块验收 #<模块卡>」，单独成行。
MODULE_RE='^[*_> -]*随模块验收 +#[0-9]+[*_ ]*$'
# 注意：方括号里不放全角字符（C locale 下 grep 按字节解析，会把它拆成几个字节）。
# 更新说明路径（release/notes/**）与随版本写的 CHANGELOG.md。
NOTES_RE='^(release/notes/|CHANGELOG\.md$)'

# 只认真实测试位置：*.test.* / *.spec.* 文件，或测试目录下的文件（test、tests、__tests__、androidTest、
# sharedTest、iOS 的 PPassTests 与各包的 Tests 目录；对照过 build.gradle.kts / Package.swift / project.yml / Cargo）。
# 注意 iOS 的 TransportFFITests/Package.swift 是 App 依赖的包清单，不是测试，所以不能按「*Tests 目录」放过。不按文件名后缀 Test 判，否则 SpeedTest.svelte 这种正式组件会被漏掉。
TEST_RE='(\.(test|spec)\.[^/]*$)|((^|/)(PPassTests|Tests|tests|test|__tests__|androidTest|sharedTest)/)'

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

MODE="${1:-}"
[ -n "$MODE" ] || usage
shift
FILES_F=""
BODY_F=""
REPO="$(cd "${HERE}/../.." && pwd)"
CORE_RULES=""
DIFF_F=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --files) FILES_F="${2:-}"; shift 2 || shift ;;
    --body) BODY_F="${2:-}"; shift 2 || shift ;;
    --repo) REPO="${2:-}"; shift 2 || shift ;;
    --core-rules) CORE_RULES="${2:-}"; shift 2 || shift ;;
    --diff) DIFF_F="${2:-}"; shift 2 || shift ;;
    *) usage ;;
  esac
done

# 用户可见：apps/** 下的非测试文件（如安卓备份行为 backup/**），或界面与文案路径。
# 界面路径清单与 owner-triage.sh 共用同一份；读不到按可见处理（宁严勿松）。
visible() { # visible <非测试文件列表>：可见打印 yes
  local nontest="$1" ui_globs ui
  [ -n "$nontest" ] || return 0
  if [ "$(printf '%s\n' "$nontest" | bash "${REPO}/tools/ci-paths.sh" hit - 'apps/**' 2>/dev/null)" != "false" ]; then
    echo yes
    return
  fi
  ui_globs="$(sed -n 's/^UI_GLOBS="\(.*\)"$/\1/p' "${REPO}/tools/flow/owner-triage.sh" 2>/dev/null)"
  if [ -z "$ui_globs" ]; then echo yes; return; fi
  set -f
  # shellcheck disable=SC2086 # 清单是空格分隔的 glob，刻意拆开
  ui="$(printf '%s\n' "$nontest" | bash "${REPO}/tools/ci-paths.sh" hit - $ui_globs 2>/dev/null)"
  set +f
  [ "$ui" = "false" ] || echo yes
}

classify() {
  local files core nontest
  files="$(cat)"
  [ -n "$CORE_RULES" ] || CORE_RULES="${REPO}/.github/core-paths.txt"
  # 过滤后为空就不判（ci-paths 对空输入 fail-closed 判 true）。
  nontest="$(printf '%s\n' "$files" | grep -Ev "$TEST_RE" | grep -v '^$')"
  if [ -n "$DIFF_F" ]; then
    core="$(printf '%s\n' "$files" | bash "${REPO}/tools/ci-paths.sh" core - "$CORE_RULES" --diff "$DIFF_F" 2>/dev/null)"
  else
    core="$(printf '%s\n' "$files" | bash "${REPO}/tools/ci-paths.sh" core - "$CORE_RULES" 2>/dev/null)"
  fi
  if [ "$core" != "false" ]; then
    # 核心里再分可见与否：只改更新说明也算可见（文案）。
    if [ -n "$(visible "$nontest")" ]; then echo core; else echo core-hidden; fi
    return
  fi
  [ -n "$nontest" ] || { echo none; return; }
  # 只改更新说明（可带 CHANGELOG.md）：文案确认，不要真机验收。
  if [ -z "$(printf '%s\n' "$nontest" | grep -Ev "$NOTES_RE")" ] &&
    printf '%s\n' "$nontest" | grep -q '^release/notes/'; then
    echo notes
    return
  fi
  if [ -n "$(visible "$nontest")" ]; then echo ui; else echo none; fi
}

# 正文引用的、origin/main 上「已采纳」的方案（一行一个）。在仓库根下判，取 origin/main 上的版本：
# PR 自己加进来的方案文件不算（没合进 main 就不是已采纳）。
adopted_in_body() { (cd "$REPO" && adopted_adrs "$(cat "$BODY_F")"); }
has_record() { grep -qE "$SOP_RE" "$1" || grep -qE "$ACCEPT_RE" "$1"; }

case "$MODE" in
  classify) classify ;;
  record)
    [ -f "$BODY_F" ] || usage
    has_record "$BODY_F" || grep -qE "$COPY_RE" "$BODY_F"
    ;;
  check)
    [ -f "$FILES_F" ] && [ -f "$BODY_F" ] || usage
    KIND="$(classify <"$FILES_F")"
    case "$KIND" in
      none)
        echo "acceptance gate：不碰界面与核心路径（自动级），不需要验收 ✅"
        exit 0
        ;;
      core-hidden)
        adrs="$(adopted_in_body)"
        tests="$(grep -E "$TEST_RE|(^|/)test-[^/]*\.sh$" "$FILES_F" | head -n 3)"
        if [ -n "$adrs" ] && [ -n "$tests" ]; then
          echo "acceptance gate：核心改动、用户看不见，正文引用已采纳方案（$(printf '%s' "$adrs" | tr '\n' ' ')）且带测试 ✅"
          exit 0
        fi
        echo "acceptance gate ❌：改动碰核心路径、用户看不见（不要真机验收行），但缺："
        [ -n "$adrs" ] || echo "  - PR 正文引用 origin/main 上「已采纳」的方案（docs/decisions/<日期>-<名>.md）"
        [ -n "$tests" ] || echo "  - 改动里带测试文件（带反证的自动化测试）"
        exit 1
        ;;
    esac
    if has_record "$BODY_F"; then
      echo "acceptance gate：${KIND} 级改动，PR 正文有产品负责人验收记录 ✅"
      exit 0
    fi
    if [ "$KIND" = notes ] && grep -qE "$COPY_RE" "$BODY_F"; then
      echo "acceptance gate：只改更新说明，PR 正文有产品负责人文案确认记录 ✅"
      exit 0
    fi
    if grep -qE "$MODULE_RE" "$BODY_F"; then
      if [ "$KIND" != core ]; then
        echo "acceptance gate：${KIND} 级改动，整体模式「$(grep -E "$MODULE_RE" "$BODY_F" | head -n 1 | sed 's/^[*_> -]*//')」，正式发版前统一验收 ✅"
        exit 0
      fi
      if [ -n "$(adopted_in_body)" ]; then
        echo "acceptance gate：核心且用户可见，引用了已采纳方案，整体模式随模块验收 ✅"
        exit 0
      fi
      echo "acceptance gate ❌：碰核心路径的改动，「随模块验收」要同时在正文引用 origin/main 上「已采纳」的方案（docs/decisions/<日期>-<名>.md）。"
      exit 1
    fi
    if [ "$KIND" = notes ]; then
      echo "acceptance gate ❌：只改更新说明（release/notes/**），PR 正文缺文案确认行。"
      echo "产品负责人确认文案后，在 PR 正文单独写一行：「产品负责人 <日期 时间> 文案确认通过」（如 2026-11-05 15:30），"
      echo "或整体模式写「随模块验收 #<模块卡>」。"
      exit 1
    fi
    WHAT="界面或文案路径、App 代码"
    [ "$KIND" != core ] || WHAT="核心路径（用户看得到）"
    echo "acceptance gate ❌：改动碰${WHAT}，PR 正文缺验收记录。"
    echo "产品负责人按 SOP 操作、owner 判日志通过后，由 owner 在 PR 正文单独写一行："
    echo "「产品负责人 <日期 时间> 按 SOP <链接> 操作，owner 判日志通过」（旧写法「产品负责人 <日期 时间> 真机验收通过」也认），再 gh pr ready；"
    [ "$KIND" = core ] || echo "或整体模式写「随模块验收 #<模块卡>」，正式发版前统一验收。"
    exit 1
    ;;
  *) usage ;;
esac
