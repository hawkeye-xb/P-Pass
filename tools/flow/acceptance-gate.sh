#!/usr/bin/env bash
# acceptance gate：用户看得到的改动，PR 正文必须有产品负责人验收那一行，否则红。
#
#   acceptance-gate.sh check    --files <改动文件列表> --body <PR 正文文件> [--repo <仓库根>] [--core-rules <规则文件>]
#   acceptance-gate.sh classify [--repo <仓库根>] [--core-rules <规则文件>] < 改动文件列表   打印 core / ui / notes / none
#
# 级别判定与验收行判定只在这里一份：worker-done.sh（classify）、review.sh（classify + check）、CI 的 acceptance gate（check）
# 都调用本脚本，别在别处再抄一份。
#
# 口径与 owner-triage.sh 一致：碰核心路径（.github/core-paths.txt）或界面与文案路径
# （owner-triage.sh 里的 UI_GLOBS）、apps/** 下的非测试文件（测试 = 下面 TEST_RE 圈出的位置）= 需要验收；其余（自动级）直接绿。
# 验收方式按改动类型分（#1448）：
#   core / ui  真机验收：「产品负责人 <时间> 真机验收通过」
#   notes      只改更新说明（非测试文件全在 release/notes/** 与 CHANGELOG.md 里，且至少有一个 release/notes/** 文件）：
#              发版前没有真机可看，验收方式是文案确认：「产品负责人 <时间> 文案确认通过」（已有真机验收行也算）。
#              notes 与界面混改仍是 ui，要真机验收行；只改 CHANGELOG.md 是 none。
# 退出码：0 绿 / 1 红 / 2 用法错误。

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# 单独成行：「产品负责人 <日期[ 时间]> [本地]真机验收通过」，允许行首的列表/引用/加粗符号。
ACCEPT_RE='^[*_> -]*产品负责人 ([0-9]{4}-)?[0-9]{2}-[0-9]{2}( +[0-9]{1,2}:[0-9]{2})? *(本地)?真机验收通过([*_ ]*|\*\*.*)$'
# 更新说明的文案确认行：格式同上，只是动词换成「文案确认通过」。
COPY_RE='^[*_> -]*产品负责人 ([0-9]{4}-)?[0-9]{2}-[0-9]{2}( +[0-9]{1,2}:[0-9]{2})? *文案确认通过([*_ ]*|\*\*.*)$'
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
while [ "$#" -gt 0 ]; do
  case "$1" in
    --files) FILES_F="${2:-}"; shift 2 || shift ;;
    --body) BODY_F="${2:-}"; shift 2 || shift ;;
    --repo) REPO="${2:-}"; shift 2 || shift ;;
    --core-rules) CORE_RULES="${2:-}"; shift 2 || shift ;;
    *) usage ;;
  esac
done

# 界面路径清单与 owner-triage.sh 共用同一份；读不到按需要验收处理（宁严勿松）。
classify() {
  local files core ui_globs ui nontest
  files="$(cat)"
  [ -n "$CORE_RULES" ] || CORE_RULES="${REPO}/.github/core-paths.txt"
  core="$(printf '%s\n' "$files" | bash "${REPO}/tools/ci-paths.sh" core - "$CORE_RULES" 2>/dev/null)"
  if [ "$core" != "false" ]; then echo core; return; fi
  # apps/** 下的非测试文件都算用户看得到的行为（如安卓备份行为 backup/**）；UI_GLOBS 只管界面与文案，不够。
  # 过滤后为空就不判（ci-paths 对空输入 fail-closed 判 true）。
  nontest="$(printf '%s\n' "$files" | grep -Ev "$TEST_RE" | grep -v '^$')"
  [ -n "$nontest" ] || { echo none; return; }
  # 只改更新说明（可带 CHANGELOG.md）：文案确认，不要真机验收。
  if [ -z "$(printf '%s\n' "$nontest" | grep -Ev "$NOTES_RE")" ] &&
    printf '%s\n' "$nontest" | grep -q '^release/notes/'; then
    echo notes
    return
  fi
  if [ "$(printf '%s\n' "$nontest" | bash "${REPO}/tools/ci-paths.sh" hit - 'apps/**' 2>/dev/null)" != "false" ]; then
    echo ui
    return
  fi
  ui_globs="$(sed -n 's/^UI_GLOBS="\(.*\)"$/\1/p' "${REPO}/tools/flow/owner-triage.sh" 2>/dev/null)"
  if [ -z "$ui_globs" ]; then echo ui; return; fi
  set -f
  # shellcheck disable=SC2086 # 清单是空格分隔的 glob，刻意拆开
  ui="$(printf '%s\n' "$nontest" | bash "${REPO}/tools/ci-paths.sh" hit - $ui_globs 2>/dev/null)"
  set +f
  if [ "$ui" != "false" ]; then echo ui; else echo none; fi
}

case "$MODE" in
  classify) classify ;;
  check)
    [ -f "$FILES_F" ] && [ -f "$BODY_F" ] || usage
    KIND="$(classify <"$FILES_F")"
    if [ "$KIND" = none ]; then
      echo "acceptance gate：不碰界面与核心路径（自动级），不需要真机验收 ✅"
      exit 0
    fi
    if grep -qE "$ACCEPT_RE" "$BODY_F"; then
      echo "acceptance gate：${KIND} 级改动，PR 正文有真机验收记录 ✅"
      exit 0
    fi
    if [ "$KIND" = notes ]; then
      if grep -qE "$COPY_RE" "$BODY_F"; then
        echo "acceptance gate：只改更新说明，PR 正文有产品负责人文案确认记录 ✅"
        exit 0
      fi
      echo "acceptance gate ❌：只改更新说明（release/notes/**），PR 正文缺文案确认行。"
      echo "产品负责人确认文案后，在 PR 正文单独写一行：「产品负责人 <日期 时间> 文案确认通过」（如 2026-11-05 15:30），再 gh pr ready。"
      exit 1
    fi
    WHAT="界面或文案路径"
    [ "$KIND" != core ] || WHAT="核心路径"
    echo "acceptance gate ❌：改动碰${WHAT}，PR 正文缺验收行。"
    echo "产品负责人真机验收通过后，在 PR 正文单独写一行：「产品负责人 <日期 时间> 真机验收通过」（如 2026-11-05 15:30），再 gh pr ready。"
    exit 1
    ;;
  *) usage ;;
esac
