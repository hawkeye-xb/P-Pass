#!/usr/bin/env bash
# worker 流程三条命令（tools/flow/worker-*.sh）的判据测试。
#
# 临时仓库（裸 origin + 主仓克隆）里走真实路径；gh 与 just 是 PATH 注入的桩：
#   gh   读写 $FAKE_GH 目录：<号>.state/.title/.labels/.body/.type，评论追加到 <号>.comments
#   just ci / ci-docs 看 $FAKE_GH/ci_fail；just verify 看 has_verify / verify_fail
# 每条拒绝都配一条只去掉触发条件的放行用例作反证。
#
# just doctor 的用例也在这里：私仓两种模式、.ppass-verify-clone 标记、WSL 桩 bash、拦截未装、
# 磁盘低于下限、提交身份不在白名单、gh 不可用，每条都配反证（去掉触发条件必须通过）。
#
# 用法: tools/test-flow-worker.sh
# 退出码: 0 全过 / 1 有失败

set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() {
  printf '  ✅ %s\n' "$1"
  PASS=$((PASS + 1))
}
bad() {
  printf '  ❌ %s\n' "$1"
  FAIL=$((FAIL + 1))
}
check() { # check <描述> <命令...>：命令成功即通过
  local d="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

export HOME="${TMP}/home"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
mkdir -p "$HOME"
git config --global user.name "Flow Test"
git config --global user.email "flow-test@example.invalid"
git config --global init.defaultBranch main
export PPASS_HOOK_REPO="o/r"
export PPASS_FLOW_SKIP_HOOK_INSTALL=1
export PPASS_NO_LOCK=1
# doctor 的磁盘下限在测试里放开（CI runner 的剩余空间不固定）；设备只列不判，测试不去碰真设备。
export PPASS_DOCTOR_MIN_FREE_GB=0
export PPASS_DOCTOR_SKIP_DEVICES=1
unset PPASS_HOOK_BYPASS PPASS_HOOK_BYPASS_REASON PPASS_HOOK_ROOT PPASS_WT_ROOT

# 假命令：MSYS/Cygwin（Git Bash）不能执行指向 .exe 的符号链接，改生成 wrapper 脚本；
# 其他平台保持 symlink。调用方：fake_cmd <目录> <命令名>。
fake_cmd() {
  local dir="$1" c="$2" p
  p="$(command -v "$c")" && [ "${p#/}" != "$p" ] || return 1
  case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*)
      # 原生 git.exe spawn 钩子的解释器时要真正的 sh.exe，wrapper 脚本不行：
      # 不放进假 bin，让 PATH 末尾的真实 /usr/bin 供给（见 EXTRA_PATH）。
      [ "$c" = sh ] && return 0
      printf '#!/bin/sh\nexec "%s" "$@"\n' "$p" >"${dir}/${c}" && chmod +x "${dir}/${c}"
      ;;
    *)
      ln -s "$p" "${dir}/${c}"
      ;;
  esac
}

BIN="${TMP}/pathbin"
mkdir -p "$BIN"
for c in git bash env sh sed awk tar mktemp cat tr head tail grep rm cp chmod touch sort cmp \
  basename dirname mkdir mv cut wc ls diff df uname rmdir; do
  fake_cmd "$BIN" "$c" || {
    echo "找不到命令 ${c}，无法搭测试环境"
    exit 1
  }
done
# Git Bash 上原生 git.exe 需要真实 sh.exe：把 MSYS 的 /usr/bin 放在假 PATH 末尾。
case "$(uname -s 2>/dev/null)" in
  MINGW* | MSYS* | CYGWIN*) EXTRA_PATH=":/usr/bin:/mingw64/bin" ;;
  *) EXTRA_PATH="" ;;
esac
export EXTRA_PATH

export FAKE_GH="${TMP}/gh"
mkdir -p "$FAKE_GH"
cat >"${BIN}/gh" <<'STUB'
#!/usr/bin/env bash
G="$FAKE_GH"
case "$1 $2" in
  "auth status") exit 0 ;;
  "issue list") exit 0 ;;
  "label create") echo "label create $3" >>"$G/calls"; exit 0 ;;
  "issue view")
    n="$3"
    [ -f "$G/$n.body" ] || { echo "GraphQL: Could not resolve to an issue ($n)" >&2; exit 1; }
    printf 'state:%s\ntitle:%s\nlabels:%s\nbody:\n' "$(cat "$G/$n.state")" "$(cat "$G/$n.title")" "$(cat "$G/$n.labels")"
    cat "$G/$n.body"
    ;;
  "issue edit")
    n="$3"; shift 3
    add="" del=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --add-label) add="$2"; shift 2 ;;
        --remove-label) del="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    cur="$(cat "$G/$n.labels")"
    new=""
    for l in $(printf '%s' "$cur" | tr ',' ' '); do
      skip=0
      for d in $(printf '%s' "$del" | tr ',' ' '); do [ "$l" = "$d" ] && skip=1; done
      [ "$skip" = 1 ] || new="${new:+$new,}$l"
    done
    for a in $(printf '%s' "$add" | tr ',' ' '); do
      case ",$new," in *",$a,"*) ;; *) new="${new:+$new,}$a" ;; esac
    done
    printf '%s' "$new" >"$G/$n.labels"
    ;;
  "issue comment")
    n="$3"; shift 3
    while [ $# -gt 0 ]; do
      [ "$1" = "--body-file" ] && { { cat "$2"; echo "-----"; } >>"$G/$n.comments"; }
      shift
    done
    ;;
  "pr view")
    [ -e "$G/pr.created" ] && [ "$(cat "$G/pr.created")" = "$3" ] && { echo "https://example.invalid/pr/1"; exit 0; }
    exit 1 ;;
  "pr create")
    shift 2
    while [ $# -gt 0 ]; do
      case "$1" in
        --head) printf '%s' "$2" >"$G/pr.created"; shift 2 ;;
        --title) printf '%s' "$2" >"$G/pr.title"; shift 2 ;;
        --body-file) cp "$2" "$G/pr.body"; shift 2 ;;
        *) shift ;;
      esac
    done
    echo "https://example.invalid/pr/1" ;;
  "api repos/o/r/issues/"*) [ -f "$G/${2##*/}.type" ] && cat "$G/${2##*/}.type"; exit 0 ;;
  *)
    case "$1" in
      api) n="${2##*/}"; [ -f "$G/$n.type" ] && cat "$G/$n.type"; exit 0 ;;
    esac
    echo "stub gh: unsupported $*" >&2; exit 2 ;;
esac
STUB
cat >"${BIN}/just" <<'STUB'
#!/usr/bin/env bash
G="$FAKE_GH"
case "$1" in
  ci | ci-docs | android-test | ios-test | mobile-static-check)
    echo "==> just $* running"
    # 回放 #1342：断言写死中文原文，只在英文测试语言下红
    if [ "$*" = "ios-test --lang en" ] && [ -e "$G/zh_hardcoded" ]; then echo "error: XCTAssertEqual failed: FAKE-EN-RED"; exit 1; fi
    if [ -e "$G/ci_fail" ]; then echo "error: lint failed: FAKE-CI-RED"; exit 1; fi
    echo "==> CI pipeline: all green FAKE-CI-GREEN"
    ;;
  --show) [ "$2" = verify ] && [ -e "$G/has_verify" ] ;;
  verify)
    echo "verify scenario $2"
    if [ -e "$G/verify_fail" ]; then echo "FAKE-VERIFY-RED"; exit 1; fi
    echo "FAKE-VERIFY-GREEN"
    ;;
  *) echo "stub just: unsupported $*" >&2; exit 2 ;;
esac
STUB
cat >"${BIN}/cargo" <<'STUB'
#!/usr/bin/env bash
echo "==> cargo $* running"
if [ -e "$FAKE_GH/ci_fail" ]; then echo "error: lint failed: FAKE-CI-RED"; exit 1; fi
echo "==> CI pipeline: all green FAKE-CI-GREEN (cargo $*)"
STUB
chmod +x "${BIN}/gh" "${BIN}/just" "${BIN}/cargo"
export PATH="$BIN${EXTRA_PATH}"

# ── 仓库：裸 origin + 主仓 ─────────────────────────────────────────────
git init -q --bare "${TMP}/origin.git"
git init -q "${TMP}/main"
(
  cd "${TMP}/main" || exit 1
  git remote add origin "${TMP}/origin.git"
  mkdir -p tools .github src docs/decisions core
  cp -R "${SRC}/tools/flow" tools/flow
  cp -R "${SRC}/tools/hooks" tools/hooks
  # 测试只看 doctor 有没有接通 install.sh --check；真 hook 的判据在 tools/test-local-hooks.sh。
  # 这里装一个空转发器，免得测试里「故意提交范围外文件」的夹具被真 hook 提前拦掉。
  printf '#!/usr/bin/env bash\nexit 0\n' >tools/hooks/dispatch.sh
  printf 'Flow Test <flow-test@example.invalid>\n' >.github/allowed-identities.txt
  cp "${SRC}/tools/ci-paths.sh" tools/ci-paths.sh
  mkdir -p tools/e3/lib
  cp "${SRC}/tools/e3/lib/dev-cache.sh" tools/e3/lib/dev-cache.sh
  printf '+ core/**\n' >.github/core-paths.txt
  echo a >src/a.txt
  echo d >docs/d.md
  echo c >core/c.txt
  # tools 挑选（#1365）的夹具：test-ref 引用 ci-paths.sh，test-other 不引用
  printf '#!/usr/bin/env bash\n# 引用 tools/ci-paths.sh\necho FAKE-TOOLTEST-REF-RAN\n[ ! -e "$FAKE_GH/tool_fail" ] || { echo FAKE-TOOLTEST-RED; exit 1; }\n' >tools/test-ref.sh
  printf '#!/usr/bin/env bash\necho FAKE-TOOLTEST-OTHER-RAN\n' >tools/test-other.sh
  printf '# A\n\n- 状态：已采纳\n' >docs/decisions/2026-11-01-adopted.md
  printf '# P\n\n- 状态：提议\n' >docs/decisions/2026-11-01-proposed.md
  git add -A
  git commit -q -m init
  git push -q origin HEAD:refs/heads/main
  # doctor 要求提交拦截已装；后面「拦截未装」的用例会先解开再装回来。
  bash tools/hooks/install.sh >/dev/null 2>&1
)
export PPASS_WT_ROOT="${TMP}/wt"
M="${TMP}/main"

issue() { # issue <号> <标签> <标题> <范围 glob，空格分隔，空=无范围块> [类型] [正文附加行]
  local n="$1" labels="$2" title="$3" scope="$4" type="${5:-}" extra="${6:-}"
  set -f # 范围里的 ** 不能被 shell 展开
  printf 'OPEN' >"${FAKE_GH}/${n}.state"
  printf '%s' "$labels" >"${FAKE_GH}/${n}.labels"
  printf '%s' "$title" >"${FAKE_GH}/${n}.title"
  [ -z "$type" ] || printf '%s\n' "$type" >"${FAKE_GH}/${n}.type"
  {
    printf '## 🟥 挂号段\r\n\r\n**产品诉求**：x\r\n\r\n**范围（只许动这些）**：\r\n'
    if [ -n "$scope" ]; then
      printf '```\r\n'
      for g in $scope; do printf '%s\r\n' "$g"; done
      printf '```\r\n'
    fi
    printf '\r\n**验收场景**：y\r\n'
    [ -z "$extra" ] || printf '\r\n%s\r\n' "$extra"
  } >"${FAKE_GH}/${n}.body"
  set +f
}
labels_of() { cat "${FAKE_GH}/$1.labels"; }
has_lbl() { case ",$(labels_of "$1")," in *",$2,"*) return 0 ;; esac; return 1; }
comments_of() { cat "${FAKE_GH}/$1.comments" 2>/dev/null; }
on_origin() { git --git-dir="${TMP}/origin.git" rev-parse -q --verify "refs/heads/$1" >/dev/null; }
START() { (cd "$M" && bash tools/flow/worker-start.sh "$@"); }
STUCK() { (cd "$M" && bash tools/flow/worker-stuck.sh "$@"); }
DONE() { local d="$1"; shift; (cd "$d" && bash tools/flow/worker-done.sh "$@"); }
REAL_BASH="$(command -v bash)"
DOCTOR() { (cd "$M" && "$REAL_BASH" tools/flow/doctor.sh); }

# ── just doctor ───────────────────────────────────────────────────────
echo "== just doctor =="
if DOCTOR >"${TMP}/d0" 2>&1; then ok "doctor 在健康的主副本里通过"; else bad "doctor 在健康的主副本里失败：$(tail -5 "${TMP}/d0")"; fi
grep -q "协作者模式" "${TMP}/d0" && ok "没有 ../private → 报协作者模式" || bad "没有 ../private 时没报协作者模式"
grep -q "完整模式" "${TMP}/d0" && bad "没有 ../private 却报了完整模式" || ok "反证：没有 ../private 不报完整模式"
mkdir -p "${TMP}/private"
if DOCTOR >"${TMP}/d1" 2>&1 && grep -q "完整模式" "${TMP}/d1"; then ok "反证：放上 ../private → 报完整模式"; else bad "有 ../private 时没报完整模式"; fi
rmdir "${TMP}/private"

touch "${M}/.ppass-verify-clone"
if DOCTOR >"${TMP}/d2" 2>&1; then bad "带 .ppass-verify-clone 仍放行"; else ok "带 .ppass-verify-clone → doctor 拒绝"; fi
grep -q "回归专用克隆" "${TMP}/d2" && ok "拒绝理由点名 Windows 回归专用克隆" || bad "拒绝理由没点名回归克隆"
rm -f "${M}/.ppass-verify-clone"
DOCTOR >/dev/null 2>&1 && ok "反证：去掉标记 → doctor 通过" || bad "去掉标记后 doctor 仍失败"

# bash 是 WSL 桩（用假 bash 模拟）：doctor 必须报错，而不是继续往下跑
mkdir -p "${TMP}/wslbin"
cat >"${TMP}/wslbin/bash" <<'STUB'
#!/bin/sh
echo "Windows Subsystem for Linux has no installed distributions." >&2
exit 1
STUB
chmod +x "${TMP}/wslbin/bash"
if (cd "$M" && PATH="${TMP}/wslbin:${PATH}" "$REAL_BASH" tools/flow/doctor.sh) >"${TMP}/d3" 2>&1; then
  bad "bash 是 WSL 桩也放行"
else
  ok "bash 是 WSL 桩（假 bash）→ doctor 报错"
fi
grep -q "Git Bash" "${TMP}/d3" && ok "报错里给了 Git Bash 的修法" || bad "报错里没给 Git Bash 的修法"

# 拦截没装：just start 必须非 0；装上后放行（反证）
issue 18 "status:ready" "[T-18] hook off" "src/**"
git -C "$M" config --unset core.hooksPath || true
if START 18 >"${TMP}/d4" 2>&1; then bad "拦截未装时 just start 仍放行"; else ok "拦截未装 → just start 非 0"; fi
grep -q "本地提交拦截" "${TMP}/d4" && ok "拒绝理由点名本地提交拦截" || bad "拒绝理由没点名本地提交拦截"
[ ! -d "${PPASS_WT_ROOT}/18-hook-off" ] && ok "拦截未装时没建 worktree（没带病继续）" || bad "拦截未装却建了 worktree"
(cd "$M" && bash tools/hooks/install.sh >/dev/null 2>&1)
if START 18 >"${TMP}/d5" 2>&1; then ok "反证：装上拦截 → just start 通过"; else bad "装上拦截后 start 仍失败：$(tail -5 "${TMP}/d5")"; fi

# 磁盘低于下限：拒绝；把下限调回去：通过
if (cd "$M" && PPASS_DOCTOR_MIN_FREE_GB=999999 "$REAL_BASH" tools/flow/doctor.sh) >"${TMP}/d6" 2>&1; then bad "磁盘低于下限也放行"; else ok "磁盘低于下限 → doctor 拒绝"; fi
grep -q "磁盘" "${TMP}/d6" && ok "拒绝理由点名磁盘" || bad "拒绝理由没点名磁盘"
PPASS_DOCTOR_MIN_FREE_GB=0 DOCTOR >/dev/null 2>&1 && ok "反证：磁盘下限 0 → 通过" || bad "磁盘下限 0 仍失败"

# 提交身份不在白名单：拒绝；改回去：通过
git -C "$M" config user.email "outsider@example.invalid"
if DOCTOR >"${TMP}/d7" 2>&1; then bad "提交身份不在白名单也放行"; else ok "提交身份不在白名单 → doctor 拒绝"; fi
grep -q "allowed-identities" "${TMP}/d7" && ok "拒绝理由点名白名单" || bad "拒绝理由没点名白名单"
git -C "$M" config --unset user.email
DOCTOR >/dev/null 2>&1 && ok "反证：身份改回白名单 → 通过" || bad "身份改回后仍失败"

# gh 不可用：拒绝；放回去：通过
mv "${BIN}/gh" "${BIN}/gh.off"
if DOCTOR >"${TMP}/d8" 2>&1; then bad "gh 不可用也放行"; else ok "gh 不可用 → doctor 拒绝"; fi
grep -q "gh" "${TMP}/d8" && ok "拒绝理由点名 gh" || bad "拒绝理由没点名 gh"
mv "${BIN}/gh.off" "${BIN}/gh"
DOCTOR >/dev/null 2>&1 && ok "反证：gh 可用 → 通过" || bad "gh 恢复后仍失败"

# ── just start ────────────────────────────────────────────────────────
echo "== just start =="
issue 10 "status:inbox" "[T-10] not ready" "src/**"
if START 10 >/dev/null 2>&1; then bad "start 放行了非 ready 的卡"; else ok "start 拒绝非 ready（status:inbox）"; fi
has_lbl 10 "status:inbox" && ok "拒绝后标签不变" || bad "拒绝后标签被改了"
[ ! -d "${PPASS_WT_ROOT}/10-not-ready" ] && ok "拒绝后没建 worktree" || bad "拒绝后建了 worktree"

issue 11 "status:ready" "[T-11] no scope" ""
if START 11 >/dev/null 2>&1; then bad "start 放行了没有范围代码块的卡"; else ok "start 拒绝无「范围」代码块"; fi
has_lbl 11 "status:ready" && ok "拒绝后仍是 ready" || bad "拒绝后标签被改了"

issue 12 "status:ready" "[T-12] closed one" "src/**"
printf 'CLOSED' >"${FAKE_GH}/12.state"
if START 12 >/dev/null 2>&1; then bad "start 放行了已关闭的卡"; else ok "start 拒绝已关闭的卡"; fi

issue 13 "status:ready" "[T-13] Fix the Thing" "src/**" "Bug"
OUT="$(START 13 2>&1)"
rc=$?
[ "$rc" = 0 ] && ok "start 放行 ready + 有范围的卡（反证：与上面三条只差触发条件）" || bad "start 拒绝了合格的卡：$OUT"
check "worktree 建在 <根>/<号>-<slug>" test -d "${PPASS_WT_ROOT}/13-fix-the-thing"
check "Bug → fix/ 分支" git -C "${PPASS_WT_ROOT}/13-fix-the-thing" symbolic-ref --short HEAD
[ "$(git -C "${PPASS_WT_ROOT}/13-fix-the-thing" symbolic-ref --short HEAD)" = "fix/13-fix-the-thing" ] && ok "分支名 fix/13-fix-the-thing" || bad "分支名不对"
has_lbl 13 "status:doing" && ! has_lbl 13 "status:ready" && ok "标签 ready → doing" || bad "标签没从 ready 换成 doing"
[ -z "$(git -C "${PPASS_WT_ROOT}/13-fix-the-thing" config --get branch.fix/13-fix-the-thing.merge)" ] && ok "上游已解除（裸 git push 不会推到 main）" || bad "上游仍指向 origin/main"
printf '%s' "$OUT" | grep -q "just done" && ok "打印了下一步" || bad "没打印下一步"
# 标记在主副本根上，从卡 worktree 里也要认出来（不是只看 cwd）
touch "${M}/.ppass-verify-clone"
if (cd "${PPASS_WT_ROOT}/13-fix-the-thing" && "$REAL_BASH" tools/flow/doctor.sh) >"${TMP}/d9" 2>&1; then
  bad "卡 worktree 里没认出主副本根上的回归克隆标记"
else
  ok "卡 worktree 里也拒绝带 .ppass-verify-clone 的主副本"
fi
rm -f "${M}/.ppass-verify-clone"
issue 14 "status:ready" "[T-14] feature" "src/**" "Feature"
START 14 >/dev/null 2>&1
git -C "${PPASS_WT_ROOT}/14-feature" symbolic-ref --short HEAD | grep -q '^feat/14-' && ok "Feature → feat/" || bad "Feature 没推成 feat/"
issue 15 "status:ready" "[T-15] doc tweak" "docs/**" ""
START 15 >/dev/null 2>&1
git -C "${PPASS_WT_ROOT}/15-doc-tweak" symbolic-ref --short HEAD | grep -q '^docs/15-' && ok "Task + 全在 docs/ → docs/（hook 不认 chore）" || bad "Task 没推成 docs/"
issue 16 "status:ready,core" "[T-16] core card" "core/**" "Bug"
OUT="$(START 16 2>&1)"
printf '%s' "$OUT" | grep -q "只写复现" && ok "核心卡提示「只写复现、根因和两个修法」" || bad "核心卡没有提示"
printf '%s' "$OUT" | grep -q "按方案实现" && bad "没引用方案的核心卡出了「按方案实现」" || ok "反证：核心卡没引用方案 → 不出「按方案实现」"
issue 18 "status:ready,core" "[T-18] core adopted" "core/**" "Bug" "**ADR**：docs/decisions/2026-11-01-adopted.md"
OUT="$(START 18 2>&1)"
printf '%s' "$OUT" | grep -q "按方案实现" && ! printf '%s' "$OUT" | grep -q "只写复现" &&
  ok "核心卡引用已采纳方案 → 提示「按方案实现」，不出「只写复现」" || bad "核心卡引用已采纳方案仍没提示按方案实现：$OUT"
printf '%s' "$OUT" | grep -q "方案：docs/decisions/2026-11-01-adopted.md" && ok "提示里列出已采纳方案路径" || bad "提示里没列方案路径"
issue 19 "status:ready,core" "[T-19] core proposed" "core/**" "Bug" "**ADR**：docs/decisions/2026-11-01-proposed.md"
OUT="$(START 19 2>&1)"
printf '%s' "$OUT" | grep -q "只写复现" && ! printf '%s' "$OUT" | grep -q "按方案实现" &&
  ok "反证：核心卡只引用「提议」方案 → 仍提示「只写复现、根因和两个修法」" || bad "引用「提议」方案的核心卡提示不对：$OUT"
issue 17 "status:ready" "[T-17] plain" "src/**" "Bug"
OUT="$(START 17 2>&1)"
printf '%s' "$OUT" | grep -q "只写复现" && bad "非核心卡也出了核心提示" || ok "反证：非核心卡不出核心提示"

# 范围解析与 hook 里那份逐字相同（防漂移）；先证明比对本身会红
awk_block() { sed -n "/awk '\$/,/^')\"/p" "$1" | sed 1d; }
HOOK_AWK="$(awk_block "${SRC}/tools/hooks/pre-commit")"
LIB_AWK="$(awk_block "${SRC}/tools/flow/worker-lib.sh")"
[ -n "$HOOK_AWK" ] && [ "$HOOK_AWK" = "$LIB_AWK" ] && ok "范围解析 awk 与 tools/hooks/pre-commit 逐字一致" || bad "范围解析 awk 与 hook 漂移"
[ "$HOOK_AWK" != "$(printf '%s' "$HOOK_AWK" | sed 's/infence = 1/infence = 2/')" ] && ok "反证：改动一处比对即红" || bad "比对对改动不敏感"

# ── just done ─────────────────────────────────────────────────────────
echo "== just done =="
card() { # card <号> <标题> <范围> → 领卡并输出 worktree 目录
  issue "$1" "status:ready" "$2" "$3" "Bug"
  START "$1" >/dev/null 2>&1 || { echo "领卡失败" >&2; return 1; }
  ls -d "${PPASS_WT_ROOT}/$1-"*
}
commit_file() { # commit_file <目录> <文件> [内容]
  mkdir -p "$(dirname "$1/$2")"
  echo "${3:-x}" >"$1/$2"
  git -C "$1" add -A && git -C "$1" commit -q -s -m "change $2"
}

# 越界 → 不推、blocked；去掉越界后放行
W="$(card 20 "[T-20] scope" "src/**")"
commit_file "$W" src/ok.txt
commit_file "$W" docs/outside.md
if DONE "$W" >"${TMP}/o20" 2>&1; then bad "done 放行了越界改动"; else ok "done 拒绝范围外文件（退出码非 0）"; fi
on_origin "fix/20-scope" && bad "越界仍被推送" || ok "越界时没有推送"
has_lbl 20 "status:blocked" && ! has_lbl 20 "status:doing" && ok "越界时打 status:blocked（去掉 doing）" || bad "越界时标签不对"
comments_of 20 | grep -q "docs/outside.md" && ok "评论点名了越界文件" || bad "评论没点名越界文件"
git -C "$W" rm -q docs/outside.md && git -C "$W" commit -q -s -m "drop outside"
if DONE "$W" >"${TMP}/o20b" 2>&1; then ok "反证：撤掉越界后放行并推送"; else bad "撤掉越界后仍失败：$(tail -5 "${TMP}/o20b")"; fi
on_origin "fix/20-scope" && ok "绿时已推送到 origin" || bad "绿时没推送"
has_lbl 20 "status:review" && ! has_lbl 20 "status:blocked" && ! has_lbl 20 "status:doing" && ok "标签 → status:review，blocked 已去掉" || bad "交卡后标签不对：$(labels_of 20)"
C="$(comments_of 20)"
for k in "fix/20-scope" "E1" "FAKE-CI-GREEN" "just ci" "change src/ok.txt" ".evidence/20"; do
  printf '%s' "$C" | grep -qF -- "$k" && ok "回执含「${k}」" || bad "回执缺「${k}」"
done
printf '%s' "$C" | grep -qF "$HOME" && bad "回执泄露了本机家目录" || ok "回执不含本机家目录"
printf '%s' "$C" | grep -q "E3" && printf '%s' "$C" | grep -q "just verify 20" && bad "无 verify 时回执声称了 E3 验证" || ok "无 just verify 时不声称 E3"

# 门禁红 → 不推、blocked、评论贴错误末尾；去掉故障后放行
W="$(card 21 "[T-21] ci red" "src/**")"
commit_file "$W" src/r.txt
touch "${FAKE_GH}/ci_fail"
if DONE "$W" >"${TMP}/o21" 2>&1; then bad "门禁红时 done 仍成功"; else ok "门禁红 → done 退出码非 0"; fi
on_origin "fix/21-ci-red" && bad "门禁红仍推送了" || ok "门禁红时没有推送"
has_lbl 21 "status:blocked" && ok "门禁红时打 status:blocked" || bad "门禁红时没打 blocked"
comments_of 21 | grep -q "FAKE-CI-RED" && ok "评论贴了错误末尾（FAKE-CI-RED）" || bad "评论没贴错误末尾"
rm -f "${FAKE_GH}/ci_fail"
DONE "$W" >/dev/null 2>&1 && on_origin "fix/21-ci-red" && ok "反证：去掉故障后推送" || bad "去掉故障后仍失败"

# verify 存在且红 → blocked；绿 → 回执写 E3
touch "${FAKE_GH}/has_verify"
W="$(card 22 "[T-22] verify" "src/**")"
commit_file "$W" src/v.txt
touch "${FAKE_GH}/verify_fail"
if DONE "$W" >/dev/null 2>&1; then bad "verify 红时 done 仍成功"; else ok "just verify 红 → done 失败"; fi
on_origin "fix/22-verify" && bad "verify 红仍推送" || ok "verify 红时没有推送"
comments_of 22 | grep -q "FAKE-VERIFY-RED" && ok "评论贴了 verify 错误末尾" || bad "评论没贴 verify 错误"
rm -f "${FAKE_GH}/verify_fail"
DONE "$W" >/dev/null 2>&1 && on_origin "fix/22-verify" && ok "反证：verify 绿后推送" || bad "verify 绿后仍失败"
comments_of 22 | grep -q "E3" && comments_of 22 | grep -q "FAKE-VERIFY-GREEN" && ok "有 verify 时回执写 E3 并贴输出" || bad "回执缺 E3 / verify 输出"
rm -f "${FAKE_GH}/has_verify"

# 纯文档走 ci-docs
W="$(card 23 "[T-23] docs only" "docs/**")"
commit_file "$W" docs/n.md
DONE "$W" >/dev/null 2>&1
comments_of 23 | grep -q "just ci-docs" && ok "纯文档改动跑 just ci-docs" || bad "纯文档没走 ci-docs"
comments_of 20 | grep -q "just ci-docs" && bad "代码改动误走 ci-docs" || ok "反证：代码改动走 just ci"

# 门禁按改动路径挑（#1361）：只改安卓文案 → android-test + mobile-static-check，不跑全量 just ci
W="$(card 125 "[T-125] android copy" "apps/android/**")"
mkdir -p "$W/apps/android/app/src/main/res/values"
printf '<resources/>\n' >"$W/apps/android/app/src/main/res/values/strings.xml"
git -C "$W" add -A && git -C "$W" commit -q -s -m "android copy"
DONE "$W" >"${TMP}/o125" 2>&1
C25="$(comments_of 125)"
printf '%s' "$C25" | grep -qF "just android-test + just mobile-static-check" && ok "只改安卓文案 → 门禁是 android-test + mobile-static-check" || bad "安卓文案门禁不对：$(tail -4 "${TMP}/o125")"
printf '%s' "$C25" | grep -qF '`just ci`' && bad "只改安卓文案仍跑了全量 just ci" || ok "反证：没有全量 just ci"
# Rust crate → 对应 crate 的测试
W="$(card 126 "[T-126] rust crate" "crates/**")"
mkdir -p "$W/crates/foo"
printf '[package]\nname = "foo-pkg"\nversion = "0.1.0"\n' >"$W/crates/foo/Cargo.toml"
git -C "$W" add -A && git -C "$W" commit -q -s -m "crate"
DONE "$W" >/dev/null 2>&1
comments_of 126 | grep -qF "cargo nextest run -p foo-pkg" && ok "改 Rust crate → 跑该 crate 的测试" || bad "Rust crate 门禁不对"
# 有一个挑不出来的文件 → 退回全量
W="$(card 127 "[T-127] mixed" "apps/android/** tools/**")"
mkdir -p "$W/apps/android" "$W/tools"
printf 'a\n' >"$W/apps/android/a.kt"
printf 'b\n' >"$W/tools/b.sh"
git -C "$W" add -A && git -C "$W" commit -q -s -m "mixed"
DONE "$W" >/dev/null 2>&1
comments_of 127 | grep -qF '`just ci`' && ok "反证：夹带挑不出来的文件 → 退回全量 just ci" || bad "挑不出来时没退回全量"
# tools 脚本按引用挑测试（#1365）：只改被 test-ref.sh 引用的 ci-paths.sh → 只跑 test-ref.sh，不跑全量、不跑无关测试
W="$(card 129 "[T-129] tools referenced" "tools/**")"
printf '# touched\n' >>"$W/tools/ci-paths.sh"
git -C "$W" add -A && git -C "$W" commit -q -s -m "touch ci-paths"
DONE "$W" >"${TMP}/o129" 2>&1
C29="$(comments_of 129)"
printf '%s' "$C29" | grep -qF "bash tools/test-ref.sh" && ok "改被引用的 tools 脚本 → 跑引用它的测试" || bad "没跑引用它的测试：$(tail -4 "${TMP}/o129")"
printf '%s' "$C29" | grep -qF '`just ci`' && bad "tools 脚本有引用测试却退回了全量 just ci" || ok "反证：没有全量 just ci"
printf '%s' "$C29" | grep -qF "test-other.sh" && bad "跑了不相关的测试" || ok "没引用的测试不跑"
# 改动里本身就是 tools/test-*.sh → 跑它自己
W="$(card 130 "[T-130] tools test itself" "tools/**")"
printf '# touched\n' >>"$W/tools/test-other.sh"
git -C "$W" add -A && git -C "$W" commit -q -s -m "touch test"
DONE "$W" >/dev/null 2>&1
comments_of 130 | grep -qF "bash tools/test-other.sh" && ok "改 tools/test-*.sh → 跑它自己" || bad "没跑改动的测试"
# tools/ios/test-*.sh 是构建辅助脚本的测试，不是 App 代码：跑脚本自身，不拉模拟器（#1425）
W="$(card 132 "[T-132] ios tool test" "tools/**")"
mkdir -p "$W/tools/ios"
printf '#!/usr/bin/env bash
exit 0
' >"$W/tools/ios/test-stamp-version.sh"
chmod +x "$W/tools/ios/test-stamp-version.sh"
git -C "$W" add -A && git -C "$W" commit -q -s -m "ios tool test"
DONE "$W" >"${TMP}/o132" 2>&1
C32="$(comments_of 132)"
printf '%s' "$C32" | grep -qF "bash tools/ios/test-stamp-version.sh" && ok "改 tools/ios/test-*.sh → 跑该脚本自身" || bad "tools/ios 测试门禁不对：$(tail -4 "${TMP}/o132")"
printf '%s' "$C32" | grep -qF "just ios-test" && bad "tools/ios 测试仍拉了 just ios-test" || ok "反证：没有拉模拟器 lane"
# 挑出来的测试红 → blocked，不推
W="$(card 131 "[T-131] tools test red" "tools/**")"
printf '# touched2\n' >>"$W/tools/ci-paths.sh"
git -C "$W" add -A && git -C "$W" commit -q -s -m "touch ci-paths red"
touch "${FAKE_GH}/tool_fail"
DONE "$W" >/dev/null 2>&1 && bad "引用测试红时 done 仍成功" || ok "引用的测试红 → done 失败"
has_lbl 131 "status:blocked" && ok "tools 测试红 → status:blocked" || bad "tools 测试红没打 blocked"
rm -f "${FAKE_GH}/tool_fail"
# 门禁中任一项红 → blocked，不推
W="$(card 128 "[T-128] android red" "apps/android/**")"
mkdir -p "$W/apps/android"
printf 'a\n' >"$W/apps/android/r.kt"
git -C "$W" add -A && git -C "$W" commit -q -s -m "red"
touch "${FAKE_GH}/ci_fail"
DONE "$W" >/dev/null 2>&1 && bad "android-test 红时 done 仍成功" || ok "android-test 红 → done 失败"
has_lbl 128 "status:blocked" && ok "挑选后的门禁红 → status:blocked" || bad "没打 blocked"
rm -f "${FAKE_GH}/ci_fail"

# 核心改动无 core 标签 → blocked；
W="$(card 24 "[T-24] core hit" "core/** src/**")"
commit_file "$W" core/x.txt
if DONE "$W" >/dev/null 2>&1; then bad "无 core 标签却放行了核心改动"; else ok "核心改动且无 core 标签 → 拒绝"; fi
has_lbl 24 "status:blocked" && ok "核心命中时打 status:blocked" || bad "核心命中没打 blocked"
printf 'status:blocked,core' >"${FAKE_GH}/24.labels"
DONE "$W" >/dev/null 2>&1 && ok "反证：带 core 标签放行" || bad "带 core 标签仍被拒"

# 分支落后 main → 拒绝但不打 blocked
W="$(card 25 "[T-25] behind" "src/**")"
commit_file "$W" src/b.txt
(cd "$M" && echo z >src/z.txt && git add -A && git commit -q -m "main moves" && git push -q origin HEAD:refs/heads/main)
if DONE "$W" >"${TMP}/o25" 2>&1; then bad "落后 main 仍放行"; else ok "落后 origin/main → 拒绝"; fi
has_lbl 25 "status:blocked" && bad "落后被当成红打了 blocked" || ok "落后只提示 rebase，不打 blocked"
grep -q "rebase" "${TMP}/o25" && ok "提示了 git rebase origin/main" || bad "没提示 rebase"
git -C "$W" rebase -q origin/main
DONE "$W" >/dev/null 2>&1 && on_origin "fix/25-behind" && ok "反证：rebase 后放行" || bad "rebase 后仍失败"

# 主仓工作区、未提交改动
if (cd "$M" && bash tools/flow/worker-done.sh) >/dev/null 2>&1; then bad "在主仓工作区 done 也成功"; else ok "done 拒绝在主仓工作区运行"; fi
W="$(card 26 "[T-26] dirty" "src/**")"
commit_file "$W" src/d.txt
echo dirty >>"$W/src/d.txt"
if DONE "$W" >/dev/null 2>&1; then bad "工作区不干净仍放行"; else ok "done 拒绝未提交改动"; fi
git -C "$W" checkout -q -- src/d.txt
DONE "$W" >/dev/null 2>&1 && ok "反证：干净后放行" || bad "干净后仍失败"

# ── just stuck ────────────────────────────────────────────────────────
echo "== just stuck =="
issue 30 "status:doing" "[T-30] stuck" "src/**"
if STUCK 30 "" >/dev/null 2>&1; then bad "stuck 接受了空原因"; else ok "stuck 拒绝空原因"; fi
has_lbl 30 "status:blocked" && bad "空原因也打了 blocked" || ok "空原因不改标签"
STUCK 30 "命中核心：根因在配对握手；修法 A / 修法 B" >/dev/null 2>&1 && ok "stuck 带原因成功" || bad "stuck 带原因失败"
has_lbl 30 "status:blocked" && ! has_lbl 30 "status:doing" && ok "stuck 打 status:blocked 并去掉 doing" || bad "stuck 标签不对"
comments_of 30 | grep -q "命中核心：根因在配对握手" && ok "stuck 评论含原因" || bad "stuck 评论缺原因"

# 协作者模式遇到要写私仓的活：doctor 不通过（拦截解开）时 just stuck 仍必须可用——它是停下的出口
issue 31 "status:doing" "[T-31] collaborator" "src/**"
git -C "$M" config --unset core.hooksPath || true
if STUCK 31 "需要写私仓，本机是协作者模式" >/dev/null 2>&1; then ok "doctor 不通过时 just stuck 仍可用（协作者模式 → stuck）"; else bad "doctor 不通过时 stuck 也失败了"; fi
comments_of 31 | grep -q "本机是协作者模式" && ok "stuck 评论写明协作者模式" || bad "stuck 评论缺协作者模式"
(cd "$M" && bash tools/hooks/install.sh >/dev/null 2>&1)

# ── 多卡一条功能分支（#1376）────────────────────────────────────────────
echo "== 多卡分支 =="
issue 51 "status:ready" "[T-51] multi a" "src/**" "Bug"
issue 52 "status:ready" "[T-52] multi b" "docs/**" "Feature"
issue 53 "status:inbox" "[T-53] not ready" "core/**" "Bug"
if START 51 53 >"${TMP}/o51x" 2>&1; then bad "多卡里有一张不是 ready 也领了"; else ok "多卡：有一张不合格整批不领"; fi
has_lbl 51 "status:ready" && [ ! -d "${PPASS_WT_ROOT}/51-multi-a" ] && ok "  整批不领时第一张卡没被改、没建目录" || bad "整批不领却留了半截"
OUT="$(START 51 52 --name "Onboarding Gate" 2>&1)" || bad "多卡领卡失败：$OUT"
MW="${PPASS_WT_ROOT}/51-onboarding-gate"
[ "$(git -C "$MW" symbolic-ref --short HEAD 2>/dev/null)" = "feat/51-onboarding-gate" ] &&
  ok "多卡：一条分支，号取第一张、名取 --name、有 Feature 就 feat/" || bad "多卡分支名不对：$(git -C "$MW" symbolic-ref --short HEAD 2>&1)"
[ "$(git -C "$MW" config --get branch.feat/51-onboarding-gate.ppasscards)" = "51 52" ] &&
  ok "多卡：分支配置记下了两张卡" || bad "分支配置没记卡号"
has_lbl 51 "status:doing" && has_lbl 52 "status:doing" && ok "多卡：两张卡都转 doing" || bad "多卡标签不对：$(labels_of 51) / $(labels_of 52)"
printf '%s' "$OUT" | grep -q 'src/\*\*' && printf '%s' "$OUT" | grep -q 'docs/\*\*' && ok "多卡：打印的范围是并集" || bad "多卡范围没取并集"
commit_file "$MW" src/m.txt
commit_file "$MW" docs/m.md
if DONE "$MW" >"${TMP}/o51" 2>&1; then ok "多卡：两张卡范围内的文件都放行"; else bad "多卡交卡失败：$(tail -5 "${TMP}/o51")"; fi
comments_of 51 | grep -q "worker 已交卡" && comments_of 52 | grep -q "worker 已交卡" && ok "多卡：回执贴到每张卡" || bad "回执没贴到每张卡"
has_lbl 51 "status:review" && has_lbl 52 "status:review" && ok "多卡：两张卡都转 review" || bad "多卡交卡后标签不对"
grep -qx 'closes #51' "${FAKE_GH}/pr.body" && grep -qx 'closes #52' "${FAKE_GH}/pr.body" &&
  ok "多卡：PR 正文 closes 两张卡" || bad "PR 正文没 closes 两张卡：$(cat "${FAKE_GH}/pr.body" 2>/dev/null | head -5)"
grep -q '不需要真机验收' "${FAKE_GH}/pr.body" && ok "用户看不到的改动：PR 写明不需要真机验收" || bad "PR 没写验收说明"
# 反证：同样的改动，分支只记一张卡 → 第二张卡范围内的文件算越界
issue 54 "status:ready" "[T-54] single" "src/**" "Bug"
SW="$(START 54 >/dev/null 2>&1; ls -d "${PPASS_WT_ROOT}/54-"*)"
commit_file "$SW" src/m.txt
commit_file "$SW" docs/m.md
if DONE "$SW" >"${TMP}/o54" 2>&1; then bad "单卡分支放行了别的卡范围里的文件"; else ok "反证：只认一张卡时 docs/ 越界被拒"; fi

# 用户看得到的改动：没给验收时间 → 只推分支、不开 PR；给了 → PR 写「产品负责人 <时间> 真机验收通过」
issue 55 "status:ready" "[T-55] visible" "apps/**" "Bug"
VW="$(START 55 >/dev/null 2>&1; ls -d "${PPASS_WT_ROOT}/55-"*)"
mkdir -p "$VW/apps/x"
commit_file "$VW" apps/x/ui.txt
rm -f "${FAKE_GH}/pr.body" "${FAKE_GH}/pr.created"
DONE "$VW" >"${TMP}/o55" 2>&1 || bad "可见改动交卡失败：$(tail -5 "${TMP}/o55")"
on_origin "fix/55-visible" && ok "可见改动：分支已推送" || bad "可见改动没推分支"
[ ! -e "${FAKE_GH}/pr.created" ] && ok "可见改动没给验收时间：不开 PR" || bad "没验收就开了 PR"
grep -q 'just done --accepted' "${TMP}/o55" && ok "  提示先验收再 --accepted" || bad "没提示先验收"
DONE "$VW" --accepted "2026-11-04 15:30" >"${TMP}/o55b" 2>&1 || bad "带验收时间交卡失败：$(tail -5 "${TMP}/o55b")"
grep -qF '产品负责人 2026-11-04 15:30 真机验收通过' "${FAKE_GH}/pr.body" 2>/dev/null &&
  ok "反证：给了验收时间 → 开 PR，正文写明验收" || bad "给了验收时间仍没开 PR 或正文缺验收行"

# ── #1375 共享编译缓存：just start 建主副本旁的 .env.ppass-dev ────────────────
# 卡目录在主副本旁（<主副本>-wt 之类）时靠 just 往上找到它，不拷；不在旁边时拷进卡目录根。
cache_norm() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
cache_want="$(cd -P "$TMP" && pwd)/P-Pass-cache/cargo-target"
cache_got="$(sed -n 's/^CARGO_TARGET_DIR=//p' "${TMP}/.env.ppass-dev" 2>/dev/null | tail -1)"
[ -n "$cache_got" ] && [ "$(cache_norm "$cache_got")" = "$(cache_norm "$cache_want")" ] &&
  ok "start 在主副本旁建了共享编译缓存配置" || bad "start 没建共享编译缓存配置"
[ ! -e "${PPASS_WT_ROOT}/13-fix-the-thing/.env.ppass-dev" ] &&
  ok "卡目录在主副本旁：不拷配置（just 往上找得到）" || bad "卡目录在主副本旁却拷了配置"
issue 41 "status:ready" "[T-41] cache elsewhere" "src/**" "Bug"
FAR="$(mktemp -d)"
OUT="$(PPASS_WT_ROOT="${FAR}/wt" START 41 2>&1)" || bad "start 41 失败：$OUT"
grep -q '^CARGO_TARGET_DIR=' "${FAR}/wt/41-cache-elsewhere/.env.ppass-dev" 2>/dev/null &&
  ok "卡目录不在主副本旁：配置拷进卡目录根" || bad "卡目录不在主副本旁却没拷配置"
printf '%s' "$OUT" | grep -q '编译缓存：共享' && ok "start 打印了共享编译缓存" || bad "start 没打印编译缓存：$OUT"
git -C "$M" worktree remove --force "${FAR}/wt/41-cache-elsewhere" >/dev/null 2>&1
rm -rf "$FAR"
# ── #1378 iOS 文案改动：交卡时 iOS 单测中英各跑一次 ─────────────────────────
echo "== iOS 文案中英两语 =="
issue 61 "status:ready" "[T-61] ios copy" "apps/ios/**" "Bug"
LW="$(START 61 >/dev/null 2>&1; ls -d "${PPASS_WT_ROOT}/61-"*)"
mkdir -p "$LW/apps/ios/PPass/Resources/en.lproj"
commit_file "$LW" apps/ios/PPass/Resources/en.lproj/Localizable.strings '"k" = "v";'
DONE "$LW" >"${TMP}/o61" 2>&1 || bad "iOS 文案交卡失败：$(tail -5 "${TMP}/o61")"
C61="$(comments_of 61)"
printf '%s' "$C61" | grep -qF "just ios-test --lang en" && printf '%s' "$C61" | grep -qF "just ios-test --lang zh" &&
  ok "改 iOS 文案 → 门禁含 just ios-test --lang en 与 --lang zh" || bad "改 iOS 文案没有中英两轮：$(printf '%s' "$C61" | grep -m1 门禁)"
issue 62 "status:ready" "[T-62] ios code" "apps/ios/**" "Bug"
LW2="$(START 62 >/dev/null 2>&1; ls -d "${PPASS_WT_ROOT}/62-"*)"
mkdir -p "$LW2/apps/ios/PPass"
commit_file "$LW2" apps/ios/PPass/A.swift 'let a = 1'
DONE "$LW2" >"${TMP}/o62" 2>&1 || bad "iOS 代码交卡失败：$(tail -5 "${TMP}/o62")"
comments_of 62 | grep -qF -- "--lang" && bad "只改 iOS 代码也跑了中英两轮" || ok "反证：只改 iOS 代码不加中英两轮"
# 回放 #1342：测试写死中文原文，只在英文下红 → 本地交卡就被拦下（英文那一轮去掉时这条变红）
issue 63 "status:ready" "[T-63] zh hardcoded" "assets/i18n/**" "Bug"
LW3="$(START 63 >/dev/null 2>&1; ls -d "${PPASS_WT_ROOT}/63-"*)"
mkdir -p "$LW3/assets/i18n"
commit_file "$LW3" assets/i18n/zh.json '{}'
touch "${FAKE_GH}/zh_hardcoded"
if DONE "$LW3" >"${TMP}/o63" 2>&1; then bad "写死中文的测试在本地没被发现（英文那一轮没跑）"; else ok "回放 #1342：英文那一轮在本地就红，没推送"; fi
has_lbl 63 "status:blocked" && comments_of 63 | grep -qF "just ios-test --lang en" && ok "  停在 just ios-test --lang en，打了 blocked" || bad "停的位置不对：$(comments_of 63 | head -3)"
rm -f "${FAKE_GH}/zh_hardcoded"

echo
echo "通过 ${PASS}，失败 ${FAIL}"
[ "$FAIL" -eq 0 ]
