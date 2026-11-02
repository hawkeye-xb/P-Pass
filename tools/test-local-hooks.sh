#!/usr/bin/env bash
# 本地提交拦截（tools/hooks/）的判据测试。
#
# 在临时仓库里走真实路径：tools/hooks/install.sh 安装 → git commit 触发转发器 → 从 HEAD 取
# hook 判定。gh 用 PATH 注入的桩（读 $FAKE_GH 目录里的 <issue号>.labels / <issue号>.body；
# 存在 $FAKE_GH/fail 时退出 1）。每条拒绝都配一条只去掉触发条件的放行用例作反证。
#
# 用法: tools/test-local-hooks.sh
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

# 与本机配置隔离：不读全局 / 系统 git 配置（本机可能有私有 hook 与身份白名单）。
export HOME="${TMP}/home"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
mkdir -p "$HOME"
git config --global user.name "Hook Test"
git config --global user.email "hook-test@example.invalid"
git config --global init.defaultBranch main
unset PPASS_HOOK_BYPASS PPASS_HOOK_BYPASS_REASON PPASS_HOOK_REPO PPASS_HOOK_ROOT

# PATH 只放白名单命令的软链（不含 gh），桩放最前面。不能「剔掉带 gh 的目录」：
# Linux 上 gh 常在 /usr/bin，一剔连 git / sed 都没了。测试与 hook 用到新命令要加进这里。
NOGH_PATH="${TMP}/nogh"
mkdir -p "$NOGH_PATH"
for c in git bash env sh sed awk tar mktemp cat tr head grep rm cp chmod touch sort cmp \
  basename dirname mkdir; do
  p="$(command -v "$c")" && [ "${p#/}" != "$p" ] || {
    echo "找不到命令 ${c}，无法搭测试环境"
    exit 1
  }
  ln -s "$p" "${NOGH_PATH}/${c}"
done
mkdir -p "${TMP}/bin"
cat >"${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
# 假 gh：只认 `gh issue view <N> -R <repo> --json labels,body --jq ...`，按 hook 的 --jq 格式输出。
[ -e "$FAKE_GH/fail" ] && { echo "error connecting to api.github.com" >&2; exit 1; }
[ "$1 $2" = "issue view" ] || { echo "stub: unsupported $*" >&2; exit 2; }
n="$3"
[ -f "$FAKE_GH/$n.body" ] || { echo "GraphQL: Could not resolve to an issue ($n)" >&2; exit 1; }
printf 'labels:%s\n' "$(cat "$FAKE_GH/$n.labels" 2>/dev/null)"
cat "$FAKE_GH/$n.body"
STUB
chmod +x "${TMP}/bin/gh"
export FAKE_GH="${TMP}/gh"
mkdir -p "$FAKE_GH"
export PATH="${TMP}/bin:${NOGH_PATH}"

issue() { # issue <号> <标签,逗号分隔> <正文>
  printf '%s' "$2" >"${FAKE_GH}/$1.labels"
  printf '%s\n' "$3" >"${FAKE_GH}/$1.body"
}
scope_body() { # scope_body <glob>...：按任务卡模板的形状造正文（CRLF，模拟网页编辑过的 issue）
  printf '## ⬜ 可接段\r\n\r\n**范围（只许动这些）**：\r\n<!-- 一行一个路径或 glob -->\r\n```\r\n'
  printf '%s\r\n' "$@"
  printf '```\r\n\r\n**验收场景**：\r\n略\r\n'
}

# ── 临时仓库：带上被测的 hook、核心判定脚本与规则 ─────────────────────
R="${TMP}/repo"
git init -q --template= "$R"
cd "$R" || exit 1
git remote add origin git@github-personal:hawkeye-xb/P-Pass.git
mkdir -p tools/hooks .github docs/a docs/b crates/storage/src
cp "${SRC}/tools/hooks/"* tools/hooks/
cp "${SRC}/tools/ci-paths.sh" tools/
cp "${SRC}/.github/core-paths.txt" .github/
echo a >docs/a/x.md
echo b >docs/b/y.md
echo s >crates/storage/src/a.rs
git add -A
git commit -q -m init
bash tools/hooks/install.sh >/dev/null || {
  echo "安装失败"
  exit 1
}
COMMON="${R}/.git"
# 推送目标：本地裸仓库，remote 名 up（origin 保留 SSH 别名 URL，测仓库名解析）。
git init -q --bare --template= "${TMP}/up.git"
git remote add up "${TMP}/up.git"
git push -q up main
# 卡分支只许在 linked worktree 里提交：主仓放到 detached HEAD，用例都在 worktree W 里跑。
git checkout -q --detach
W="${TMP}/wt"
git worktree add -q "$W" main
cd "$W" || exit 1

# try <期望 pass|deny> <说明> <分支> <动作（在该分支上执行的 shell）> [输出必须包含的文字]
# 每条都从 main 的干净状态开始。
LAST_OUT=""
try() {
  local want="$1" label="$2" branch="$3" action="$4" needle="${5:-}" rc got
  git checkout -q -f main && git clean -qfdx
  git checkout -q -B "$branch" main
  eval "$action"
  LAST_OUT="$(git commit -s -q -m "test: ${label}" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then got=pass; else got=deny; fi
  if [ "$got" != "$want" ]; then
    bad "${label} → 期望 ${want}，实得 ${got}"
    printf '%s\n' "$LAST_OUT" | sed 's/^/        /'
    return
  fi
  if [ -n "$needle" ] && ! printf '%s' "$LAST_OUT" | grep -qF -- "$needle"; then
    bad "${label} → ${got}，但输出里没有「${needle}」"
    printf '%s\n' "$LAST_OUT" | sed 's/^/        /'
    return
  fi
  ok "${label} → ${got}"
}

issue 101 "status:doing" "$(scope_body 'docs/a/**' 'crates/storage/')"
issue 102 "status:doing" "## ⬜ 可接段

**范围（只许动这些）**：
- 删除 \`docs/a/{x,y}.md\`
- 顺带看看 docs/b

**验收场景**：略"
issue 103 "status:doing" "## 现象
只有挂号段，还没写范围"
issue 104 "status:doing" "$(scope_body)"
issue 105 "status:doing,core" "$(scope_body 'docs/a/**' 'crates/storage/')"

echo "==> 1. 范围"
try pass "普通卡，只改范围内文件" fix/101-ok 'echo 1 >>docs/a/x.md; git add docs/a/x.md'
try deny "普通卡，夹带范围外文件" fix/101-out 'echo 1 >>docs/a/x.md; echo 1 >>docs/b/y.md; git add -A' "越界：docs/b/y.md"
try pass "  反证：去掉越界文件 → 放行" fix/101-out 'echo 1 >>docs/a/x.md; git add -A'
try deny "范围外新增文件" fix/101-new 'echo n >docs/new.md; git add -A' "越界：docs/new.md"
try deny "删除范围外文件也算越界" fix/101-rm 'git rm -q docs/b/y.md' "越界：docs/b/y.md"
try deny "issue 没有范围段" fix/103-x 'echo 1 >>docs/a/x.md; git add -A' "没有可读的「范围」"
try deny "范围是列表不是代码块（旧卡写法）" fix/102-x 'echo 1 >>docs/a/x.md; git add -A' "没有可读的「范围」"
try deny "范围是模板默认的空代码块" fix/104-x 'echo 1 >>docs/a/x.md; git add -A' "没有可读的「范围」"
try pass "  反证：同样改动，issue 有范围代码块 → 放行" fix/101-x 'echo 1 >>docs/a/x.md; git add -A'

echo "==> 2. 分支名"
try deny "非卡分支（feat/local-hooks）" feat/local-hooks 'echo 1 >>docs/a/x.md; git add -A' "不是卡分支"
try deny "直接在 main 上提交" main 'echo 1 >>docs/a/x.md; git add -A' "不是卡分支"
try pass "  反证：同样改动在 fix/101-* 上 → 放行" fix/101-y 'echo 1 >>docs/a/x.md; git add -A'

echo "==> 3. 核心"
try deny "命中核心，issue 无 core 标签" fix/101-core 'echo 1 >>crates/storage/src/a.rs; git add -A' "这是核心改动"
try pass "  反证：同样改动，issue 带 core 标签 → 放行" fix/105-core 'echo 1 >>crates/storage/src/a.rs; git add -A'
try deny "git mv 把核心文件搬进范围内目录" fix/101-mv 'git mv crates/storage/src/a.rs docs/a/a.rs' "这是核心改动"
try deny "工作区改掉核心规则再提交核心文件（规则取自 HEAD）" fix/101-tamper \
  'sed -i.bak "/crates\/storage/d" .github/core-paths.txt; rm -f .github/core-paths.txt.bak; echo 1 >>crates/storage/src/a.rs; git add crates/storage' "这是核心改动"
try deny "工作区改掉 hook 本身再提交（hook 取自 HEAD）" fix/101-hook \
  'printf "#!/bin/sh\nexit 0\n" >tools/hooks/pre-commit; echo 1 >>crates/storage/src/a.rs; git add crates/storage' "这是核心改动"
try deny "暂存核心规则文件本身" fix/105-rules 'echo "# x" >>.github/core-paths.txt; git add -A' "越界：.github/core-paths.txt"

echo "==> 4. batch 分支"
try pass "batch/* 上核心 + 越界都不拦（且不查 gh）" batch/2026-11-02-x \
  'touch "$FAKE_GH/fail"; echo 1 >>crates/storage/src/a.rs; echo 1 >>docs/b/y.md; git add -A'
rm -f "${FAKE_GH}/fail"

echo "==> 5. gh 不可用"
try deny "PATH 里没有 gh" fix/101-nogh 'PATH="$NOGH_PATH"; echo 1 >>docs/a/x.md; git add -A' "找不到 gh"
PATH="${TMP}/bin:${NOGH_PATH}"
try deny "gh 报错（离线 / 没登录）" fix/101-off 'touch "$FAKE_GH/fail"; echo 1 >>docs/a/x.md; git add -A' "按拒绝处理"
rm -f "${FAKE_GH}/fail"
try deny "issue 不存在" fix/999-x 'echo 1 >>docs/a/x.md; git add -A' "按拒绝处理"
try pass "  反证：gh 可用、issue 存在 → 放行" fix/101-on 'echo 1 >>docs/a/x.md; git add -A'

echo "==> 6. 紧急逃生"
try pass "PPASS_HOOK_BYPASS=1 带原因，核心改动放行" fix/101-bp \
  'export PPASS_HOOK_BYPASS=1 PPASS_HOOK_BYPASS_REASON="线上止血 #101"; echo 1 >>crates/storage/src/a.rs; git add -A'
msg="$(git log -1 --format=%B)"
printf '%s' "$msg" | grep -qx 'Hook-Bypass: 线上止血 #101' && ok "  提交说明末尾有 Hook-Bypass 尾行" || bad "  缺 Hook-Bypass 尾行：${msg}"
printf '%s' "$msg" | grep -q '^Signed-off-by: Hook Test' && ok "  Signed-off-by 仍在" || bad "  Signed-off-by 丢了：${msg}"
try deny "PPASS_HOOK_BYPASS=1 原因为空" fix/101-bp2 \
  'export PPASS_HOOK_BYPASS=1 PPASS_HOOK_BYPASS_REASON="  "; echo 1 >>crates/storage/src/a.rs; git add -A' "必须同时给出原因"
unset PPASS_HOOK_BYPASS PPASS_HOOK_BYPASS_REASON
try pass "不 bypass 的普通提交不带 Hook-Bypass 尾行" fix/101-nb 'echo 1 >>docs/a/x.md; git add -A'
git log -1 --format=%B | grep -q '^Hook-Bypass:' && bad "  多出了 Hook-Bypass 尾行" || ok "  无 Hook-Bypass 尾行"

echo "==> 7. 转发原有 hook 与其它"
mkdir -p "${COMMON}/hooks"
printf '#!/bin/sh\necho "legacy hook says no" >&2\nexit 1\n' >"${COMMON}/hooks/pre-commit"
chmod +x "${COMMON}/hooks/pre-commit"
try deny "原 .git/hooks/pre-commit 拒绝时仍拒绝" batch/2026-11-02-y 'echo 1 >>docs/a/x.md; git add -A' "legacy hook says no"
rm -f "${COMMON}/hooks/pre-commit"
try pass "  反证：去掉原 hook → 放行" batch/2026-11-02-y 'echo 1 >>docs/a/x.md; git add -A'
git checkout -q -f -B fix/101-empty main
git commit -s -q --allow-empty -m "test: empty" 2>/dev/null && ok "卡分支上的空提交放行" || bad "卡分支上的空提交被拒"

echo "==> 8. 主仓工作区"
git -C "$R" checkout -q -f -B fix/101-main main
echo 1 >>"${R}/docs/a/x.md"
git -C "$R" add -A
out="$(git -C "$R" commit -s -q -m "test: main worktree" 2>&1)" && bad "主仓工作区里的卡分支提交 → 期望 deny，实得 pass" ||
  { printf '%s' "$out" | grep -qF "在主仓工作区里" && ok "主仓工作区里的卡分支提交 → deny" || bad "主仓工作区拒绝提示不对：${out}"; }
git -C "$R" checkout -q -f -B batch/2026-11-02-main main
echo 1 >>"${R}/docs/a/x.md"
git -C "$R" add -A
git -C "$R" commit -s -q -m "test: batch in main worktree" 2>/dev/null && ok "  主仓工作区里的 batch/* 不拦" || bad "主仓工作区里的 batch/* 被拒"
git -C "$R" checkout -q --detach
# 同样改动在 worktree 里放行，见第 1 节「普通卡，只改范围内文件」。

echo "==> 9. 推送：卡分支必须包含最新 main"
pushed() { # pushed <期望 pass|deny> <说明> <分支> [输出必须包含的文字]
  local out rc got
  out="$(git push -q -f up "$3" 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then got=pass; else got=deny; fi
  if [ "$got" != "$1" ]; then
    bad "$2 → 期望 $1，实得 ${got}"
    printf '%s\n' "$out" | sed 's/^/        /'
  elif [ -n "${4:-}" ] && ! printf '%s' "$out" | grep -qF -- "$4"; then
    bad "$2 → ${got}，但输出里没有「$4」：${out}"
  else
    ok "$2 → ${got}"
  fi
}
try pass "（准备）卡分支提交" fix/101-push 'echo p >>docs/a/x.md; git add -A'
pushed pass "基于最新 main 的卡分支" fix/101-push
# main 在远端前进一个提交（直接造对象推上去，不经过任何分支）。
adv="$(git commit-tree -p main -m "main moved" "main^{tree}")"
git push -q up "${adv}:refs/heads/main"
# 原有 pre-push 会读光 stdin：证明转发器给两边各喂了一份。
printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' >"${COMMON}/hooks/pre-push"
chmod +x "${COMMON}/hooks/pre-push"
git checkout -q fix/101-push
echo q >>docs/a/x.md
git add -A
git commit -s -q -m "test: more"
pushed deny "main 前进后推送落后的卡分支（原有 pre-push 先读光了 stdin）" fix/101-push "落后 up/main 1 个提交"
git checkout -q -B batch/2026-11-02-push fix/101-push
pushed pass "  落后的 batch/* 不拦" batch/2026-11-02-push
git checkout -q fix/101-push
git rebase -q up/main
pushed pass "  反证：rebase 到 up/main 后 → 放行" fix/101-push
rm -f "${COMMON}/hooks/pre-push"
git fetch -q up main:main 2>/dev/null || git update-ref refs/heads/main "$adv"

echo "==> 10. 安装自检"
git checkout -q -f main
bash tools/hooks/install.sh --check >"${TMP}/check.out" 2>&1 && ok "已安装 → --check 通过" || bad "已安装却 --check 失败：$(cat "${TMP}/check.out")"
git config --unset core.hooksPath
bash tools/hooks/install.sh --check >/dev/null 2>&1 && bad "未安装 → --check 却通过" || ok "  反证：未安装 → --check 失败"
git checkout -q -B fix/101-uninst main
echo 1 >>crates/storage/src/a.rs
git add -A
git commit -s -q -m "test: uninstalled" 2>/dev/null && ok "  （未安装时不拦，证明上面的拒绝来自 hook）" || bad "未安装时也被拒，拒绝不是来自 hook"

echo
echo "local-hooks: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
