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

# PATH 只放白名单命令的假命令（不含 gh），桩放最前面。不能「剔掉带 gh 的目录」：
# Linux 上 gh 常在 /usr/bin，一剔连 git / sed 都没了。测试与 hook 用到新命令要加进这里。
NOGH_PATH="${TMP}/nogh"
mkdir -p "$NOGH_PATH"
for c in git bash env sh sed awk tar mktemp cat tr head grep rm cp chmod touch sort cmp \
  basename dirname mkdir mv; do
  fake_cmd "$NOGH_PATH" "$c" || {
    echo "找不到命令 ${c}，无法搭测试环境"
    exit 1
  }
done
# Git Bash 上原生 git.exe 需要真实的 sh.exe 与 git-receive-pack：把 MSYS 的真实目录放在假 PATH 末尾。
# 实测去掉它们，git 起不了 hook（cannot spawn … pre-commit），本地推拉也找不到 git-receive-pack。
case "$(uname -s 2>/dev/null)" in
  MINGW* | MSYS* | CYGWIN*) EXTRA_PATH=":/usr/bin:/mingw64/bin" ;;
  *) EXTRA_PATH="" ;;
esac
export EXTRA_PATH
# 「PATH 里没有 gh」用例的前提：假 PATH 末尾的真实目录里也没有 gh（#1418 评审指出）。
# 真目录里有 gh 时没法为了排除它去掉 sh.exe / git-receive-pack，该用例跳过并打印原因；
# 当前机器与 CI 的 Git for Windows 不自带 gh，照常执行。
NO_GH_CASE=1
if ( PATH="${NOGH_PATH}${EXTRA_PATH}"; command -v gh >/dev/null 2>&1 ); then NO_GH_CASE=0; fi
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
export PATH="${TMP}/bin:${NOGH_PATH}${EXTRA_PATH}"

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
mkdir -p tools/hooks .github docs/a docs/b crates/storage/src apps/desktop/src-tauri
cp "${SRC}/tools/hooks/"* tools/hooks/
cp "${SRC}/tools/ci-paths.sh" tools/
# 规则用几条代表性夹具，不搬真实名单（同 test-flow-worker / test-release-acceptance）：
# hooks-test 测的是拦截逻辑，规则内容由 tools/test-ci-paths.sh 对着真名单测。
# 真名单 70+ 条，ci-paths 编译每条要起 3 个 sed，hook 每次提交跑两遍 core；Windows Git Bash
# 上每次进程启动约 30ms，50 条用例累计十几分钟，看起来就是「提交不返回」（#1418）。
printf '+ .github/core-paths.txt\n+ crates/storage/**\n+ apps/desktop/src-tauri/tauri.conf.json\n' >.github/core-paths.txt
echo a >docs/a/x.md
echo b >docs/b/y.md
echo s >crates/storage/src/a.rs
TC=apps/desktop/src-tauri/tauri.conf.json
printf '{\n  "productName": "P-Pass",\n  "version": "0.10.1",\n  "plugins": {\n    "updater": {\n      "endpoints": ["https://a.example/latest.json"]\n    }\n  }\n}\n' >"$TC"
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
# origin 的 URL 仍是 SSH 别名（测仓库名解析），实际取推都落到同一个裸仓库。
git config --global url."${TMP}/up.git".insteadOf git@github-personal:hawkeye-xb/P-Pass.git
# 卡分支只许在 linked worktree 里提交：主仓放到 detached HEAD，用例都在 worktree W 里跑。
git checkout -q --detach
W="${TMP}/wt"
git worktree add -q "$W" main
cd "$W" || exit 1

# try <期望 pass|deny> <说明> <分支> <动作（在该分支上执行的 shell）> [输出必须包含的文字]
# 每条都从 main 的干净状态开始。
LAST_OUT=""
try() {
  git checkout -q -f main && git clean -qfdx
  git checkout -q -B "$3" main
  eval "$4"
  commit_is "$1" "$2" "${5:-}"
}

# commit_is <期望 pass|deny> <说明> [输出必须包含的文字]：对当前暂存区提交并断言。
commit_is() {
  local want="$1" label="$2" needle="${3:-}" rc got
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

# advance <n> [文件]...：在远端 main 上叠 n 个提交；给了文件时第一个提交把它们改成新内容。
advance() {
  local n="$1" base tree c f blob
  shift
  git fetch -q up main
  base="$(git rev-parse FETCH_HEAD)"
  tree="$(git rev-parse "${base}^{tree}")"
  if [ "$#" -gt 0 ]; then
    GIT_INDEX_FILE="${TMP}/idx" git read-tree "$tree"
    for f in "$@"; do
      blob="$(printf 'main changed %s\n' "$f" | git hash-object -w --stdin)"
      GIT_INDEX_FILE="${TMP}/idx" git update-index --add --cacheinfo "100644,${blob},${f}"
    done
    tree="$(GIT_INDEX_FILE="${TMP}/idx" git write-tree)"
    rm -f "${TMP}/idx"
  fi
  c="$base"
  while [ "$n" -gt 0 ]; do
    c="$(git commit-tree -p "$c" -m "main +${n}" "$tree")"
    n=$((n - 1))
  done
  git push -q -f up "${c}:refs/heads/main"
}
reset_main() { git push -q -f up "$(git rev-parse refs/heads/main):refs/heads/main"; }

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
issue 106 "status:doing" "$(scope_body 'apps/desktop/src-tauri/tauri.conf.json')"

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
# #1451：只改版本号行（tools/bump-version.sh 的写法）不算核心；同一文件再改别的行仍是核心。
BUMP='sed -i.bak "s/\"version\": \"0.10.1\"/\"version\": \"0.11.0\"/" "$TC"'
ENDPOINT='sed -i.bak "s#a\.example#evil.example#" "$TC"'
try pass "卡无 core 标签，tauri.conf.json 只改 version 行 → 放行（#1451）" fix/106-bump \
  "${BUMP}; rm -f \"\$TC\".bak; git add \"\$TC\""
try deny "  反证：同一提交再改 updater endpoint → 核心" fix/106-endpoint \
  "${BUMP}; ${ENDPOINT}; rm -f \"\$TC\".bak; git add \"\$TC\"" "这是核心改动"
try deny "暂存核心规则文件本身" fix/105-rules 'echo "# x" >>.github/core-paths.txt; git add -A' "越界：.github/core-paths.txt"

echo "==> 3b. 多卡分支（just start <号> <号>…，卡号记在 branch.<分支>.ppasscards）：范围取并集"
issue 106 "status:doing" "$(scope_body 'docs/b/**')"
cards() { git config "branch.$(git symbolic-ref --short HEAD).ppasscards" "$1"; }
try pass "两张卡：分别改两张卡范围内的文件" fix/101-multi \
  'cards "101 106"; echo 1 >>docs/a/x.md; echo 1 >>docs/b/y.md; git add -A'
try deny "  反证：同样改动，分支没记第二张卡 → 第二张卡的文件越界" fix/101-single \
  'echo 1 >>docs/a/x.md; echo 1 >>docs/b/y.md; git add -A' "越界：docs/b/y.md"
try deny "两张卡：并集之外的文件仍越界" fix/101-multi-out \
  'cards "101 106"; echo n >docs/new.md; echo 1 >>docs/b/y.md; git add -A' "越界：docs/new.md"
try deny "两张卡：其中一张没有范围" fix/101-multi-noscope \
  'cards "101 103"; echo 1 >>docs/a/x.md; git add -A' "#103 没有可读的「范围」"
try pass "两张卡：核心改动，第二张卡带 core 标签 → 放行" fix/101-multi-core \
  'cards "101 105"; echo 1 >>crates/storage/src/a.rs; git add -A'
try deny "  反证：两张卡都没 core 标签 → 拒绝" fix/101-multi-nocore \
  'cards "101 106"; echo 1 >>crates/storage/src/a.rs; git add -A' "这是核心改动"
try deny "分支记录的卡号不是数字" fix/101-multi-bad \
  'cards "101 abc"; echo 1 >>docs/a/x.md; git add -A' "卡号「abc」不对"
try pass "  分支记录里重复写了主卡也照常" fix/101-multi-dup \
  'cards "106 101"; echo 1 >>docs/b/y.md; git add -A'

echo "==> 4. batch 分支"
try pass "batch/* 上核心 + 越界都不拦（且不查 gh）" batch/2026-11-02-x \
  'touch "$FAKE_GH/fail"; echo 1 >>crates/storage/src/a.rs; echo 1 >>docs/b/y.md; git add -A'
rm -f "${FAKE_GH}/fail"

echo "==> 5. gh 不可用"
if [ "$NO_GH_CASE" = 1 ]; then
  try deny "PATH 里没有 gh" fix/101-nogh 'PATH="${NOGH_PATH}${EXTRA_PATH}"; echo 1 >>docs/a/x.md; git add -A' "找不到 gh"
else
  echo "  ⏭ 跳过「PATH 里没有 gh」：真实 PATH 目录里有 gh，排除它就去掉了 git 需要的 sh.exe / git-receive-pack"
fi
PATH="${TMP}/bin:${NOGH_PATH}${EXTRA_PATH}"
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

echo "==> 8. 提交时落后 main"
advance 21
try deny "落后 origin/main 21 个提交" fix/101-stale 'echo 1 >>docs/a/x.md; git add -A' "落后 origin/main 21 个提交"
reset_main
advance 20
try pass "  反证：落后 20 个 → 放行" fix/101-stale 'echo 1 >>docs/a/x.md; git add -A'
reset_main
advance 1 docs/a/x.md
try deny "main 上已有新提交改过范围内文件" fix/101-scope 'echo z >docs/a/z.md; git add -A' "main 上改过：docs/a/x.md"
reset_main
advance 1 docs/b/y.md
try pass "  反证：main 上新提交只改范围外文件 → 放行" fix/101-scope 'echo z >docs/a/z.md; git add -A'
reset_main
advance 21 docs/a/x.md
mv "${TMP}/up.git" "${TMP}/up.off"
try pass "离线取不到 origin/main：只告警不拒" fix/101-off2 'echo 1 >>docs/a/x.md; git add -A' "取不到 origin/main"
mv "${TMP}/up.off" "${TMP}/up.git"
reset_main

echo "==> 9. 合并 origin/main 解冲突"
git checkout -q -f main && git clean -qfdx
git checkout -q -B fix/101-merge main
echo card >>docs/a/x.md
git add -A
git commit -s -q -m "card work"
CARD="$(git rev-parse HEAD)"
# main 上：改了与卡冲突的 docs/a/x.md、核心文件、范围外文件。
advance 1 docs/a/x.md crates/storage/src/a.rs docs/b/y.md
git fetch -q origin
merge_main() { # 从卡的提交重新合并 origin/main，解冲突
  git checkout -q -f -B "$1" "$CARD" && git clean -qfdx
  git merge -q --no-edit origin/main >/dev/null 2>&1
  echo resolved >docs/a/x.md
  git add -A
}
merge_main fix/101-merge1
commit_is pass "合并 origin/main：带进来的核心与范围外文件不算本卡改动"
merge_main fix/101-merge2
echo mine >>docs/b/y.md
git add -A
commit_is deny "  反证：合并时顺手改了范围外文件 → 拒绝" "越界：docs/b/y.md"
merge_main fix/101-merge3
echo mine >>crates/storage/src/a.rs
git add -A
commit_is deny "  反证：合并时顺手改了核心文件 → 拒绝" "这是核心改动"
side="$(git commit-tree -p main -m "side" "$(git rev-parse "origin/main^{tree}")")"
git checkout -q -f -B fix/101-merge4 "$CARD"
git merge -q --no-commit --no-ff "$side" >/dev/null 2>&1
echo resolved >docs/a/x.md
git add -A
commit_is deny "  反证：合并的不是 main 而是别的分支 → 按全部改动判" "这是核心改动"
git merge --abort 2>/dev/null
reset_main

echo "==> 10. 主仓工作区"
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

echo "==> 11. 推送：落后 main 只提示，有冲突才拒（#1423）"
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
# main 在远端前进一个不冲突的提交（另起一个文件；直接造对象推上去，不经过任何分支）。
blob="$(printf 'other\n' | git hash-object -w --stdin)"
adv_tree="$(git ls-tree main | { cat; printf '100644 blob %s\tmain-moved.txt\n' "$blob"; } | git mktree)"
adv="$(git commit-tree -p main -m "main moved" "$adv_tree")"
git push -q up "${adv}:refs/heads/main"
# 原有 pre-push 会读光 stdin：证明转发器给两边各喂了一份。
printf '#!/bin/sh\ncat >/dev/null\nexit 0\n' >"${COMMON}/hooks/pre-push"
chmod +x "${COMMON}/hooks/pre-push"
git checkout -q fix/101-push
echo q >>docs/a/x.md
git add -A
git commit -s -q -m "test: more"
pushed pass "main 前进、没有冲突的落后卡分支照推并提示（原有 pre-push 先读光了 stdin）" fix/101-push "落后 up/main 1 个提交，没有冲突"
# main 再前进一个改同一行的提交：与卡分支冲突。
git show "${adv}:docs/a/x.md" >"${TMP}/x.main" 2>/dev/null || : >"${TMP}/x.main"
echo conflict >>"${TMP}/x.main"
cblob="$(git hash-object -w "${TMP}/x.main")"
ctree="$(GIT_INDEX_FILE="${TMP}/idx" git read-tree "$adv" &&
  GIT_INDEX_FILE="${TMP}/idx" git update-index --add --cacheinfo "100644,${cblob},docs/a/x.md" &&
  GIT_INDEX_FILE="${TMP}/idx" git write-tree)"
cadv="$(git commit-tree -p "$adv" -m "main conflicts" "$ctree")"
git push -q up "${cadv}:refs/heads/main"
# 推送内容不变时 git 不调 pre-push：卡分支再加一个提交（pre-commit 会因 main 改过范围内文件拦，这里只测推送，跳过它）。
echo s >>docs/a/y.md
git add -A
git commit --no-verify -s -q -m "test: after conflict"
pushed deny "  与 main 有冲突的卡分支 → 拒" fix/101-push "有冲突"
# just done 用 HEAD:refs/heads/<分支> 推送：本地引用是 HEAD，要按远端目标引用认出卡分支
out="$(git push -q -f up "HEAD:refs/heads/fix/101-push" 2>&1)" && bad "  HEAD:refs/heads/<卡分支> 推送冲突分支 → 期望 deny，实得 pass" ||
  { printf '%s' "$out" | grep -qF "有冲突" && ok "  HEAD:refs/heads/<卡分支>（just done 的推法）推冲突分支 → 拒" || bad "  HEAD 推送拒绝理由不对：${out}"; }
git checkout -q -B batch/2026-11-02-push fix/101-push
pushed pass "  落后且冲突的 batch/* 不拦" batch/2026-11-02-push
git checkout -q fix/101-push
git fetch -q up main
git reset -q --hard up/main
echo r >>docs/a/x.md
git add -A
git commit -s -q -m "test: rebased"
pushed pass "  反证：跟上 up/main 后 → 放行" fix/101-push
rm -f "${COMMON}/hooks/pre-push"
git fetch -q up main:main 2>/dev/null || git update-ref refs/heads/main "$cadv"

echo "==> 12. 安装自检"
git checkout -q -f main
bash tools/hooks/install.sh --check >"${TMP}/check.out" 2>&1 && ok "已安装 → --check 通过" || bad "已安装却 --check 失败：$(cat "${TMP}/check.out")"
# Windows Git Bash（#1364）：git.exe 把 /c/... 写成 C:/...，读回与 bash 的路径写法不同。
# 这里用假 cygpath 模拟：假 git 写法是 WIN:<路径>，cygpath -u 去掉前缀还原。
WINPATH="$(git config --get core.hooksPath)"
# Windows 上 git 读回的是 C:/... 写法（#1364），不是 bash 的 /tmp/...：先用本机真 cygpath 换回来，
# 再模拟「git 写了另一种写法」。Linux/macOS 没有 cygpath，读回的就是同一写法。
if command -v cygpath >/dev/null 2>&1; then
  WINPATH="$(cygpath -u "$WINPATH" 2>/dev/null || printf '%s' "$WINPATH")"
fi
mkdir -p "${TMP}/cyg"
printf '#!/usr/bin/env bash\n[ "$1" = "-u" ] || exit 2\nprintf "%%s\\n" "${2#WIN:}"\n' >"${TMP}/cyg/cygpath"
chmod +x "${TMP}/cyg/cygpath"
git config core.hooksPath "WIN:${WINPATH}"
PATH="${TMP}/cyg:${PATH}" bash tools/hooks/install.sh --check >"${TMP}/check.out" 2>&1 && ok "Windows 写法（有 cygpath）→ --check 通过" || bad "Windows 写法 --check 失败：$(cat "${TMP}/check.out")"
bash tools/hooks/install.sh --check >/dev/null 2>&1 && bad "没有 cygpath 时 Windows 写法仍通过（归一化没有只在有 cygpath 时走）" || ok "  反证：没有 cygpath → 字面比较，Windows 写法不等 → --check 失败"
PATH="${TMP}/cyg:${PATH}" bash tools/hooks/install.sh >/dev/null 2>&1 && ok "Windows 写法下重复安装 → 认得是自己的，不拒绝" || bad "Windows 写法下重复安装被拒"
git config core.hooksPath "WIN:${WINPATH}-other"
PATH="${TMP}/cyg:${PATH}" bash tools/hooks/install.sh --check >/dev/null 2>&1 && bad "指向别处的 Windows 写法却通过" || ok "  反证：Windows 写法但指向别处 → --check 失败"
git config --unset core.hooksPath
bash tools/hooks/install.sh --check >/dev/null 2>&1 && bad "未安装 → --check 却通过" || ok "  反证：未安装 → --check 失败"
git checkout -q -B fix/101-uninst main
echo 1 >>crates/storage/src/a.rs
git add -A
git commit -s -q -m "test: uninstalled" 2>/dev/null && ok "  （未安装时不拦，证明上面的拒绝来自 hook）" || bad "未安装时也被拒，拒绝不是来自 hook"

echo
echo "local-hooks: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
