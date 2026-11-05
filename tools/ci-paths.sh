#!/usr/bin/env bash
# #1187：按改动路径做两种判定，给 CI 的 changes job 与核心审批用。
#
#   tools/ci-paths.sh hit  <base-sha|-> <glob>...         改动里有没有文件命中任一 glob
#   tools/ci-paths.sh core <base-sha|-> [规则文件] [--diff <文件>]
#                                                         改动有没有碰核心（默认 .github/core-paths.txt）
#
# base 传 `-` 时从 stdin 读改动文件列表（测试用）；否则取 `git diff --name-only <base>...HEAD`。
# `--diff` 可放在规则文件前或后，见下面「只改版本号」。
# stdout 恒为一行 `true` / `false`（true = 要跑 / 碰了核心）。理由写 stderr。
# **退出码恒为 0**，任何异常都判 true（fail-closed），与 tools/ci-needs-full-lane.sh 同一口径：
# 判错方向的代价是多跑一次，而不是静默放行。
#
# ## glob 语法（与 GitHub Actions 的 paths 一致）
#   `**` 跨目录，`*` 与 `?` 不跨 `/`。`dir/**` 匹配 dir 下全部文件。
#   hit 里没有通配符的裸路径按目录处理：匹配它自己或它下面的文件（按 `/` 分段，
#   `apps/android/app` 不命中 `apps/android/appx/y`）。core 的规则仍是整串精确匹配。
#
# ## 核心规则文件（.github/core-paths.txt）
#   + <glob>   命中即核心
#   zone <glob> 必审区：区内文件默认是核心……
#   - <glob>   ……除非命中这里（只对 zone 生效，压不过 +）
#   一个文件是核心 ⇔ 命中任一 `+`，或（命中任一 zone 且不命中任一 `-`）。
#   必审区反着写的原因：新加的文件不用记得登记就自动受审；漏写 `-` 的代价只是多批一次。
#
# ## 只改版本号不算核心（#1451，产品负责人 2026-11-05 同意）
#   tools/bump-version.sh 只改版本号行，更新链逻辑本身仍是核心。给了改动的 unified diff 时，
#   命中核心的文件若同时满足下面几条，就不算核心：
#     - 在 version_line_re 白名单表里（一个文件一种行）；
#     - diff 里这个文件恰好一节，头是 `diff --git a/<f> b/<f>`，有 `--- a/<f>` 与 `+++ b/<f>`，
#       没有新增 / 删除 / 改名 / 改权限 / 二进制等别的头；
#     - 改动恰好删一行、紧接着加一行（原地换值），两行都匹配白名单的版本号行（新旧值都是 SemVer）。
#     - 版本号行只认顶层那一行（tauri.conf.json 按两个空格缩进；嵌套对象里的 "version" 键不算）；
#     - 每个 hunk 的实际行数与 @@ 头声明一致（对不上 = diff 被截断或拼错，照旧算核心）。
#   同一文件还改了任何别的行（如 updater 的 pubkey、endpoints）→ 仍是核心。
#   diff 来源：给了 `--diff <文件>` 就用它；没给且 base 是真实 sha，自取
#   `git diff --no-renames <base>...HEAD`；stdin 模式（`-`）没给 `--diff` 就照旧按文件判。
#   diff 读不到、取不到、解析不了、文件名带引号转义 → 一律按核心判。

set -uo pipefail

say() { printf '%s\n' "$*" >&2; }

# 字面部分转义成正则，`*` `?` 留给 glob 语义处理。
glob_literal() {
  printf '%s' "$1" | sed -e 's/[.+^$(){}|\\[]/\\&/g'
}

# glob → 扩展正则（锚定全串）。
glob_re() {
  glob_literal "$1" |
    sed -e 's#\*\*/#@DSS@#g' -e 's#\*\*#@DS@#g' \
      -e 's#\*#[^/]*#g' -e 's#?#[^/]#g' \
      -e 's#@DSS@#(.*/)?#g' -e 's#@DS@#.*#g' |
    sed -e 's/^/^/' -e 's/$/$/'
}

# hit 专用：没有通配符的裸路径按「它自己或它下面的文件」匹配（#1343）。
# android_globs 从 workflow 取到的是目录名时，必须能命中目录里的改动；
# 按 / 分段，所以 apps/android/app 不命中 apps/android/appx/y。
hit_glob_re() {
  local g="$1"
  case "$g" in
    *[*?]*) glob_re "$g" ;;
    *) printf '^%s(/.*)?$\n' "$(glob_literal "$g")" ;;
  esac
}

# 规则在读入时就编译成正则（glob_re 要起 sed），逐文件匹配只用 bash 内置的 =~，
# 否则全仓几千个文件 × 几十条规则要起几十万个进程。
matches() { # matches <file> <已编译的正则>
  [[ $1 =~ $2 ]]
}

list_changed_files() {
  if [ "${1:-}" = "-" ]; then
    cat
    return 0
  fi
  [ -n "${1:-}" ] || return 1
  case "$1" in
    0000000000000000000000000000000000000000) return 1 ;;
  esac
  git diff --name-only "$1...HEAD" 2>/dev/null
}

# 取改动列表；取不到或为空都判 true（空列表说明没搞清状况，不是「什么都没改」）。
load_files() {
  if ! FILES="$(list_changed_files "${1:-}")"; then
    say "取不到改动文件列表（没给 base、新分支或 git diff 失败）→ 保守判定：true"
    return 1
  fi
  case "$FILES" in
    *[![:space:]]*) return 0 ;;
  esac
  say "改动文件列表为空 → 保守判定：true"
  return 1
}

cmd_hit() {
  local base="${1:-}"
  shift || true
  if [ "$#" -eq 0 ]; then
    say "没给 glob → 保守判定：true"
    echo true
    return 0
  fi
  load_files "$base" || { echo true; return 0; }
  local f g
  RES=()
  for g in "$@"; do RES+=("$(hit_glob_re "$g")"); done
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    for g in "${RES[@]}"; do
      if matches "$f" "$g"; then
        say "「${f}」命中「${g}」→ true"
        echo true
        return 0
      fi
    done
  done <<EOF
$FILES
EOF
  say "没有改动命中给定路径 → false"
  echo false
}

is_core() { # is_core <file>；规则已读进 PLUS / ZONE / MINUS
  local g
  for g in "${PLUS[@]+"${PLUS[@]}"}"; do
    matches "$1" "$g" && { WHY="+ ${g}"; return 0; }
  done
  for g in "${ZONE[@]+"${ZONE[@]}"}"; do
    if matches "$1" "$g"; then
      local m
      for m in "${MINUS[@]+"${MINUS[@]}"}"; do
        matches "$1" "$m" && return 1
      done
      WHY="zone ${g}"
      return 0
    fi
  done
  return 1
}

# 「只改版本号」白名单表：给文件名，输出它的版本号行正则（bash ERE，匹配去掉 +/- 前缀后的整行）；
# 不在表里返回 1。要加一行就在 case 里加一个分支。SemVer 2.0.0 的核心 + 可选预发布 / 构建元数据。
SEMVER_RE='(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?'
version_line_re() {
  case "$1" in
    # tools/bump-version.sh：sed "s/\"version\": \"<旧>\"/\"version\": \"<新>\"/"
    # 只认顶层那一行（文件按两个空格缩进）：嵌套对象里的 "version" 键（比如以后 plugins 里加一个）不算版本号行，
    # 改它仍走核心审批。
    apps/desktop/src-tauri/tauri.conf.json)
      printf '%s' '^  "version": "'"${SEMVER_RE}"'",?[[:space:]]*$'
      ;;
    *) return 1 ;;
  esac
}

# version_only <文件>：DIFF_FILE 里这个文件的改动是否只有白名单里的版本号行。
# 任何不认识的情况都返回 1（= 照旧算核心），理由写进 WHY_NOT。
version_only() {
  local f="$1" re line sect n=0 minus=0 plus=0 in_hunk=false
  WHY_NOT=""
  [ -n "${DIFF_FILE:-}" ] || { WHY_NOT="没有 diff"; return 1; }
  re="$(version_line_re "$f")" || { WHY_NOT="不在版本号白名单里"; return 1; }
  # 取出这个文件的那一节（可能多节，下面数）；节头之外的行原样带出，由 bash 逐行认。
  sect="$(awk -v h="diff --git a/${f} b/${f}" '
    /^diff --git / { on = ($0 == h); if (on) print "@@SECTION@@"; next }
    on { print }' "$DIFF_FILE" 2>/dev/null)" || { WHY_NOT="解析 diff 失败"; return 1; }
  [ -n "$sect" ] || { WHY_NOT="diff 里没有这个文件（新增 / 删除 / 改名 / 没给 patch 都算）"; return 1; }
  local hdr_minus=false hdr_plus=false prev=""
  # 每个 hunk 核对 @@ 头声明的行数（省略时为 1）：行数对不上 = diff 被截断或拼错，按看不懂处理（照旧算核心）。
  local want_old=-1 want_new=-1 got_old=0 got_new=0 h
  hunk_ok() {
    [ "$want_old" -lt 0 ] && return 0
    [ "$got_old" -eq "$want_old" ] && [ "$got_new" -eq "$want_new" ] && return 0
    WHY_NOT="hunk 实际行数（旧 ${got_old} / 新 ${got_new}）与 @@ 头声明（旧 ${want_old} / 新 ${want_new}）不符"
    return 1
  }
  hunk_start() { # hunk_start <@@ 行>
    hunk_ok || return 1
    h="$(printf '%s' "$1" | sed -n 's/^@@ -[0-9][0-9]*\(,\([0-9][0-9]*\)\)\{0,1\} +[0-9][0-9]*\(,\([0-9][0-9]*\)\)\{0,1\} @@.*/\2 \4/p')"
    [ -n "$h" ] || { WHY_NOT="看不懂的 hunk 头「$1」"; return 1; }
    want_old="${h% *}"
    want_new="${h#* }"
    [ -n "$want_old" ] || want_old=1
    [ -n "$want_new" ] || want_new=1
    got_old=0
    got_new=0
  }
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "@@SECTION@@" ]; then
      n=$((n + 1))
      in_hunk=false
      continue
    fi
    if [ "$in_hunk" = false ]; then
      case "$line" in
        "--- a/${f}") hdr_minus=true ;;
        "+++ b/${f}") hdr_plus=true ;;
        "index "*) ;;
        "@@ "*) hunk_start "$line" || return 1; in_hunk=true ;;
        *) WHY_NOT="diff 头里有「${line}」（新增 / 删除 / 改名 / 改权限 / 二进制都不算只改版本号）"; return 1 ;;
      esac
      continue
    fi
    case "$line" in
      "@@ "*) hunk_start "$line" || return 1; prev=hunk ;;
      " "* | "") got_old=$((got_old + 1)); got_new=$((got_new + 1)); prev=ctx ;;
      -*)
        [[ ${line#-} =~ $re ]] || { WHY_NOT="删了非版本号行「${line}」"; return 1; }
        got_old=$((got_old + 1))
        minus=$((minus + 1))
        prev=minus
        ;;
      +*)
        [[ ${line#+} =~ $re ]] || { WHY_NOT="加了非版本号行「${line}」"; return 1; }
        # 新行必须紧跟在被删的旧行后面：原地换值，不许把版本号行挪到别的位置（比如挪进 plugins）。
        [ "$prev" = minus ] || { WHY_NOT="新增的版本号行不是原地替换旧行"; return 1; }
        got_new=$((got_new + 1))
        plus=$((plus + 1))
        prev=plus
        ;;
      *) WHY_NOT="diff 里有看不懂的行「${line}」"; return 1 ;;
    esac
  done <<EOF
$sect
EOF
  hunk_ok || return 1
  [ "$n" -eq 1 ] || { WHY_NOT="diff 里这个文件有 ${n} 节（应恰好 1 节）"; return 1; }
  [ "$hdr_minus" = true ] && [ "$hdr_plus" = true ] || { WHY_NOT="diff 缺 ---/+++ 头"; return 1; }
  [ "$minus" -eq 1 ] && [ "$plus" -eq 1 ] ||
    { WHY_NOT="版本号行删 ${minus} 加 ${plus}（应各恰好 1 行）"; return 1; }
  return 0
}

cmd_core() {
  local base="${1:-}"
  shift || true
  local rules="" diff_arg="" have_diff=false
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --diff)
        if [ "$#" -lt 2 ]; then
          say "--diff 后面没给文件 → 保守判定：true"
          echo true
          return 0
        fi
        diff_arg="$2"
        have_diff=true
        shift 2
        ;;
      *)
        if [ -n "$rules" ]; then
          say "多余的参数「${1}」→ 保守判定：true"
          echo true
          return 0
        fi
        rules="$1"
        shift
        ;;
    esac
  done
  [ -n "$rules" ] || rules="$(cd "$(dirname "$0")/.." && pwd)/.github/core-paths.txt"
  PLUS=()
  ZONE=()
  MINUS=()
  if [ ! -r "$rules" ]; then
    say "读不到规则文件「${rules}」→ 保守判定：true"
    echo true
    return 0
  fi
  local line kind pat
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    read -r kind pat <<<"$line" || true
    [ -n "${kind:-}" ] || continue
    case "$kind" in
      +) PLUS+=("$(glob_re "$pat")") ;;
      zone) ZONE+=("$(glob_re "$pat")") ;;
      -) MINUS+=("$(glob_re "$pat")") ;;
      *)
        say "规则文件里有看不懂的行「${line}」→ 保守判定：true"
        echo true
        return 0
        ;;
    esac
  done <"$rules"
  if [ "${#PLUS[@]}" -eq 0 ] && [ "${#ZONE[@]}" -eq 0 ]; then
    say "规则文件里没有任何 + / zone → 保守判定：true"
    echo true
    return 0
  fi
  load_files "$base" || { echo true; return 0; }
  DIFF_FILE=""
  local own_diff=""
  if [ "$have_diff" = true ]; then
    if [ -r "$diff_arg" ] && [ -f "$diff_arg" ]; then
      DIFF_FILE="$diff_arg"
    else
      say "读不到 diff 文件「${diff_arg}」→ 不认「只改版本号」例外"
    fi
  elif [ "$base" != "-" ]; then
    # 与 list_changed_files 同一个 base；固定前缀、关掉外部 diff / textconv / 颜色，
    # 免得本机 git 配置把格式改掉（改掉了也只是解析不了 → 核心）。
    if own_diff="$(mktemp 2>/dev/null)" &&
      git -c core.quotepath=false diff --no-renames --no-color --no-ext-diff --no-textconv \
        --src-prefix=a/ --dst-prefix=b/ "${base}...HEAD" >"$own_diff" 2>/dev/null; then
      DIFF_FILE="$own_diff"
    else
      say "取不到 git diff ${base}...HEAD → 不认「只改版本号」例外"
    fi
  fi
  local f hit=false
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    WHY_NOT=""
    if is_core "$f"; then
      if [ -n "$DIFF_FILE" ] && version_only "$f"; then
        say "不算核心：${f}（${WHY}，但只改了版本号行）"
        continue
      fi
      if [ -n "$DIFF_FILE" ] && version_line_re "$f" >/dev/null; then
        say "核心：${f}（${WHY}；不是只改版本号：${WHY_NOT}）"
      else
        say "核心：${f}（${WHY}）"
      fi
      hit=true
    fi
  done <<EOF
$FILES
EOF
  [ -z "$own_diff" ] || rm -f "$own_diff"
  [ "$hit" = true ] || say "没有碰核心 → false"
  echo "$hit"
}

case "${1:-}" in
  hit) shift; cmd_hit "$@" ;;
  core) shift; cmd_core "$@" ;;
  *)
    say "用法: tools/ci-paths.sh hit <base|-> <glob>... | core <base|-> [规则文件] [--diff <文件>]（未知子命令 → true）"
    echo true
    ;;
esac
exit 0
