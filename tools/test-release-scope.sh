#!/usr/bin/env bash
# 按版本验收（tools/flow/release-scope.sh，#1471）的判据测试：每条红都配一条去掉触发条件的绿作反证。
# 临时 git 仓库里造 squash 风格的提交「... (#N)」（每个提交真改文件，classify 看文件）、一个正式 tag 和两个 test 包 tag；
# gh 是 PATH 注入的桩，读写 $FAKE 目录：
#   $FAKE/pr/<N>.body        PR 正文；$FAKE/pr/<N>.fail 存在 → gh pr view 失败
#   $FAKE/issue/<M>.body     卡 / 台账正文（gh issue edit --body-file 写回这里）；$FAKE/issue/<M>.fail → 读失败
# 级别判定用真实的 acceptance-gate.sh classify（拷进临时仓库）。
# 用法: tools/test-release-scope.sh    退出码: 0 全过 / 1 有失败
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok() { printf '  ✅ %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL + 1)); }

R="${TMP}/repo"
FAKE="${TMP}/fake"
mkdir -p "${R}/tools/flow" "${R}/.github" "${TMP}/bin" "${FAKE}/pr" "${FAKE}/issue" "${TMP}/tpl"
for f in release-scope.sh release-acceptance.sh acceptance-gate.sh owner-triage.sh worker-lib.sh decision-lib.sh; do
  cp "${SRC}/tools/flow/${f}" "${R}/tools/flow/"
done
cp "${SRC}/tools/ci-paths.sh" "${R}/tools/"
printf '+ core/**\n' >"${R}/.github/core-paths.txt"

cat >"${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -u
kind="$1"; sub="$2"; num="$3"
case "${kind} ${sub}" in
  "pr view")
    [ -e "${FAKE}/pr/${num}.fail" ] && { echo "HTTP 502: stub failure" >&2; exit 1; }
    [ -f "${FAKE}/pr/${num}.body" ] || { echo "no pull request #${num}" >&2; exit 1; }
    cat "${FAKE}/pr/${num}.body"
    ;;
  "issue view")
    [ -e "${FAKE}/issue/${num}.fail" ] && { echo "HTTP 502: stub failure" >&2; exit 1; }
    [ -f "${FAKE}/issue/${num}.body" ] || { echo "no issue #${num}" >&2; exit 1; }
    cat "${FAKE}/issue/${num}.body"
    ;;
  "issue edit")
    shift 3
    while [ "$#" -gt 0 ]; do
      case "$1" in --body-file) cp "$2" "${FAKE}/issue/${num}.body"; shift 2 ;; *) shift ;; esac
    done
    ;;
  *) echo "stub gh: unsupported $*" >&2; exit 2 ;;
esac
STUB
chmod +x "${TMP}/bin/gh"

# ── 临时仓库 ─────────────────────────────────────────────────────────────
#   v1.0.0（正式）→ #21 界面 App.svelte、#22 只改 tools、#23 看不见的核心 + 测试、#24 更新说明、#25 界面 Other.svelte
#   → v1.1.0-test.1 → #26 又改 App.svelte（#21 的文件）、#27 只改 tools → v1.1.0-test.2
#   → #28 新界面 Late.svelte 且又改 Other.svelte（#25 的文件），之后没出 test 包
(
  cd "$R" || exit 1
  export GIT_TEMPLATE_DIR="${TMP}/tpl"
  git init -q -b main
  git config user.email t@t
  git config user.name t
  mkdir -p apps/desktop/src core release/notes/android
  echo 0 >apps/desktop/src/App.svelte
  echo 0 >apps/desktop/src/Other.svelte
  echo 0 >tools/a.sh
  echo 0 >core/c.rs
  echo 0 >release/notes/android/1.zh.txt
  git add -A
  # 夹具提交是测试数据，不受本机提交钩子（身份白名单等）影响。
  c() { git add -A && git -c core.hooksPath=/dev/null commit -q --no-verify -m "$1"; }
  c "init"
  git tag v1.0.0
  echo 1 >apps/desktop/src/App.svelte && c "feat: 首页 (#21)"
  echo 1 >tools/a.sh && c "chore: 工具 (#22)"
  echo 1 >core/c.rs && echo t >tools/test-c.sh && c "fix(core): 发布链 (#23)"
  echo 1 >release/notes/android/1.zh.txt && c "docs(release): 更新说明 (#24)"
  echo 1 >apps/desktop/src/Other.svelte && c "feat: 设置页（#99） (#25)"
  git tag v1.1.0-test.1
  echo 2 >apps/desktop/src/App.svelte && c "fix: 首页又改 (#26)"
  echo 2 >tools/a.sh && c "chore: 工具二 (#27)"
  git tag v1.1.0-test.2
  echo 1 >apps/desktop/src/Late.svelte && echo 3 >apps/desktop/src/Other.svelte && c "feat: 晚到的界面 (#28)"
  git update-ref refs/remotes/origin/main HEAD
) || { echo "造临时仓库失败"; exit 1; }

reset_fake() {
  rm -f "${FAKE}"/pr/* "${FAKE}"/issue/*
  for n in 21 22 23 24 26 27 28; do printf 'closes #%s\n' "$((n + 100))" >"${FAKE}/pr/${n}.body"; done
  printf '改了设置页，没关联卡\n' >"${FAKE}/pr/25.body"
  for n in 121 122 123 124 126 127 128; do printf '卡 %s\n\n**范围**：\n```\nx\n```\n\n**验收场景**：\nE3 场景%s 第一行\n第二行 a|b\n\n**是否核心**：否\n' "$n" "$n" >"${FAKE}/issue/${n}.body"; done
  printf '[验收] v1.1.0 台账\n\n人写的说明保留\n' >"${FAKE}/issue/500.body"
}

# run <期望退出码> <描述> [参数...]：在临时仓库里跑 release-scope.sh，输出留在 $TMP/out
run() {
  local want="$1" desc="$2" rc
  shift 2
  (cd "$R" && PATH="${TMP}/bin:${PATH}" FAKE="$FAKE" PPASS_HOOK_REPO=o/r \
    bash tools/flow/release-scope.sh "$@") >"${TMP}/out" 2>&1
  rc=$?
  if [ "$rc" = "$want" ]; then ok "$desc"; else bad "${desc}（期望 ${want}，实际 ${rc}：$(tr '\n' ' ' <"${TMP}/out")）"; fi
}
has() { grep -qF -- "$1" "${TMP}/out"; }
L="${FAKE}/issue/500.body"
lhas() { grep -qF -- "$1" "$L"; }
tick() { sed -i.bak -E "s/^- \[ \] #${1} /- [x] #${1} /" "$L" && rm -f "${L}.bak"; }

echo "── 列范围"
reset_fake
run 0 "v1.0.0..v1.1.0-test.1 列范围 → 退出 0" --since v1.0.0 --to v1.1.0-test.1
has "5 个 PR 里 3 个用户看得见" && ok "  5 个 PR 里 3 个进范围" || bad "  计数不对：$(cat "${TMP}/out")"
has "- #21 ui" && ok "  改界面的 #21 进范围" || bad "  #21 没进范围"
has "#22" && bad "  只改 tools 的 #22 进了范围" || ok "  反证：只改 tools/ 的 #22 不进范围"
has "#23" && bad "  看不见的核心 #23 进了范围（合入时已靠方案 + 测试把关）" || ok "  看不见的核心 #23 不进范围"
has "- #24 notes" && ok "  只改更新说明的 #24 进范围（发版前做文案确认）" || bad "  #24 没进范围"
has "#121：E3 场景121 第一行 第二行 a｜b" && ok "  带关联卡的验收场景（压成一行，| 换全角）" || bad "  场景不对：$(cat "${TMP}/out")"
has "- #25 ui | 场景：（PR 没关联卡" && ok "  标题里的（#99）不当 PR 号，正文没关联卡写明按改动验" || bad "  #25 不对：$(cat "${TMP}/out")"
run 0 "默认起点 = 往前最近的正式 tag（跳过 test 包 tag）" --to v1.1.0-test.2
has "验收范围 v1.0.0..v1.1.0-test.2" && ok "  起点是 v1.0.0" || bad "  起点不对：$(head -1 "${TMP}/out")"
has "#26 ui" && ok "  #26 进范围" || bad "  #26 没进"
run 0 "--since 给上一个 test 包：数自上个 test 包以来的用户可见 PR" --since v1.1.0-test.1 --to v1.1.0-test.2
has "2 个 PR 里 1 个用户看得见" && ok "  test.1..test.2 只有 #26" || bad "  计数不对：$(head -1 "${TMP}/out")"
touch "${FAKE}/pr/21.fail"
run 1 "gh 读 PR #21 失败 → 红（范围可能不全，fail-closed）" --since v1.0.0 --to v1.1.0-test.1
has "读不到 PR #21" && ok "  说明读不到哪个 PR" || bad "  没说明：$(cat "${TMP}/out")"
rm -f "${FAKE}/pr/21.fail"
run 2 "ref 不存在 → 退出 2" --to no-such-ref

echo "── 第一个 test 包：建台账"
reset_fake
run 0 "--dry-run 只打印" --ledger 500 --pkg v1.1.0-test.1 --dry-run
lhas "release-ledger" && bad "  --dry-run 改了台账" || ok "  --dry-run 不改台账"
run 0 "--ledger 500 --pkg v1.1.0-test.1 → 写台账" --ledger 500 --pkg v1.1.0-test.1
lhas "<!-- release-ledger:begin since=v1.0.0 -->" && ok "  记下起点 since=v1.0.0" || bad "  没记起点：$(cat "$L")"
lhas "人写的说明保留" && ok "  台账块外的正文保留" || bad "  正文被冲掉了"
lhas "- [ ] #21 ui | 待验 @v1.1.0-test.1 | 场景：#121：E3 场景121" && ok "  #21 待验 @test.1，带场景" || bad "  #21 不对：$(cat "$L")"
lhas "- [ ] #24 notes | 待验 @v1.1.0-test.1" && ok "  #24 待验" || bad "  #24 不对"
lhas "#22 " && bad "  只改 tools 的 #22 进了台账" || ok "  #22 不进台账"
has "新增 3，待重验 0" && ok "  打印新增 3 项" || bad "  汇总不对：$(cat "${TMP}/out")"

echo "── 发版前检查（同一个包）"
(cd "$R" && PATH="${TMP}/bin:${PATH}" FAKE="$FAKE" PPASS_HOOK_REPO=o/r bash tools/flow/release-acceptance.sh 500 v1.1.0-test.1) >"${TMP}/out" 2>&1
[ $? = 1 ] && ok "台账有待验项 → 发版检查红" || bad "有待验项却放行：$(cat "${TMP}/out")"
has "#21（ui）待验 @v1.1.0-test.1" && ok "  点名待验项" || bad "  没点名：$(cat "${TMP}/out")"
tick 21; tick 24; tick 25
sed -i.bak -E 's/^(- \[x\] #21 .*)$/\1 | 结论：首页 OK/' "$L" && rm -f "${L}.bak"
(cd "$R" && PATH="${TMP}/bin:${PATH}" FAKE="$FAKE" PPASS_HOOK_REPO=o/r bash tools/flow/release-acceptance.sh 500 v1.1.0-test.1) >"${TMP}/out" 2>&1
[ $? = 0 ] && ok "反证：三项都勾上 → 发版检查绿" || bad "都勾了仍红：$(cat "${TMP}/out")"
has "3 项用户可见改动都已验" && ok "  打印清零" || bad "  输出不对：$(cat "${TMP}/out")"

echo "── 第二个 test 包：只列新增与需重验"
run 0 "--ledger 500 --pkg v1.1.0-test.2" --ledger 500 --pkg v1.1.0-test.2
lhas "- [ ] #21 ui | 待重验 @v1.1.0-test.2（上次验过 @v1.1.0-test.1，又改了 apps/desktop/src/App.svelte）" &&
  ok "已验的 #21，文件被 #26 改过 → 待重验" || bad "#21 没判待重验：$(cat "$L")"
lhas "| 结论：首页 OK" && ok "  结论保留" || bad "  结论丢了"
lhas "- [x] #25 ui | 已验 @v1.1.0-test.1" && ok "反证：已验的 #25，文件没被改 → 沿用（去掉重验判断，两条里必有一条红）" || bad "#25 没沿用：$(cat "$L")"
lhas "- [x] #24 notes | 已验 @v1.1.0-test.1" && ok "  #24 沿用" || bad "  #24 不对"
lhas "- [ ] #26 ui | 待验 @v1.1.0-test.2" && ok "  新合入的 #26 → 待验" || bad "  #26 不对"
has "新增 1，待重验 1，仍待验 0，沿用 2" && ok "  汇总：新增 1、待重验 1、沿用 2" || bad "  汇总不对：$(cat "${TMP}/out")"
has "新增  #26" && has "待重验 #21" && ok "  只打印新增与需重验" || bad "  打印不对：$(cat "${TMP}/out")"
has "#25" && bad "  沿用的 #25 也打印了" || ok "  沿用项不打印"
run 0 "同一个包重跑：台账不变（幂等）" --ledger 500 --pkg v1.1.0-test.2
has "新增 0，待重验 0，仍待验 2，沿用 2" && ok "  待验项仍待验，不重复新增" || bad "  重跑不幂等：$(cat "${TMP}/out")"
[ "$(grep -c '#21 ' "$L")" = 1 ] && ok "  #21 只有一行" || bad "  #21 重复了"
run 2 "--since 和台账记的起点不一致 → 退出 2" --ledger 500 --pkg v1.1.0-test.2 --since v1.1.0-test.1

echo "── 发版前检查（候选版）"
tick 21; tick 26
(cd "$R" && PATH="${TMP}/bin:${PATH}" FAKE="$FAKE" PPASS_HOOK_REPO=o/r bash tools/flow/release-acceptance.sh 500 v1.1.0-test.2) >"${TMP}/out" 2>&1
[ $? = 0 ] && ok "候选版 = 最后一个 test 包、全勾 → 绿" || bad "全勾仍红：$(cat "${TMP}/out")"
(cd "$R" && PATH="${TMP}/bin:${PATH}" FAKE="$FAKE" PPASS_HOOK_REPO=o/r bash tools/flow/release-acceptance.sh 500) >"${TMP}/out" 2>&1
[ $? = 1 ] && ok "候选版 = origin/main（最后一个包之后又合了 #28）→ 红" || bad "包之后合入的界面改动放行了：$(cat "${TMP}/out")"
has "#28（ui）待验：不在台账里" && ok "  #28 不在台账里 → 待验" || bad "  没点名 #28：$(cat "${TMP}/out")"
has "#25（ui）待重验：验过 @v1.1.0-test.1 之后又改了 apps/desktop/src/Other.svelte" && ok "  已验的 #25 文件在候选版里又被改 → 待重验" || bad "  没判 #25 重验：$(cat "${TMP}/out")"
has "#21（" && bad "  文件没再改的 #21 也被点名" || ok "  反证：#21 验过之后文件没再改 → 不点名"
sed -i.bak -E 's/^- \[x\] #26 ui \| 已验 @v1\.1\.0-test\.2/- [x] #26 ui | 已验 @v9.9.9-test.1/; s/^- \[x\] #26 ui \| 待验 @v1\.1\.0-test\.2/- [x] #26 ui | 待验 @v9.9.9-test.1/' "$L" && rm -f "${L}.bak"
(cd "$R" && PATH="${TMP}/bin:${PATH}" FAKE="$FAKE" PPASS_HOOK_REPO=o/r bash tools/flow/release-acceptance.sh 500 v1.1.0-test.2) >"${TMP}/out" 2>&1
[ $? = 1 ] && has "#26（ui）待重验：判不了" && ok "勾了但验过的包 tag 不存在 → 待重验（fail-closed）" || bad "包号不存在却放行：$(cat "${TMP}/out")"

echo "── 读失败 fail-closed"
reset_fake
touch "${FAKE}/issue/121.fail"
run 1 "建台账时读不到卡 #121 → 红" --ledger 500 --pkg v1.1.0-test.1
lhas "release-ledger" && bad "  读失败仍写了台账" || ok "  台账没改"
rm -f "${FAKE}/issue/121.fail"
touch "${FAKE}/issue/500.fail"
(cd "$R" && PATH="${TMP}/bin:${PATH}" FAKE="$FAKE" PPASS_HOOK_REPO=o/r bash tools/flow/release-acceptance.sh 500 v1.1.0-test.1) >"${TMP}/out" 2>&1
[ $? = 1 ] && has "读不到台账 #500" && ok "发版检查读不到台账 → 红" || bad "读不到台账却没红：$(cat "${TMP}/out")"
rm -f "${FAKE}/issue/500.fail"
(cd "$R" && PATH="${TMP}/bin:${PATH}" FAKE="$FAKE" PPASS_HOOK_REPO=o/r bash tools/flow/release-acceptance.sh 500 v1.1.0-test.1) >"${TMP}/out" 2>&1
[ $? = 1 ] && has "没有台账块" && ok "台账还没建（没有台账块）→ 红" || bad "没建台账却没红：$(cat "${TMP}/out")"

echo "── 用法"
(cd "$R" && bash tools/flow/release-acceptance.sh) >/dev/null 2>&1; [ $? = 2 ] && ok "release-acceptance 没给台账号 → 退出 2" || bad "没给台账号退出码不对"
(cd "$R" && bash tools/flow/release-acceptance.sh v1.0.0) >/dev/null 2>&1; [ $? = 2 ] && ok "  给的是 tag 不是台账号（旧用法）→ 退出 2" || bad "旧用法退出码不对"
run 2 "--ledger 不给 --pkg → 退出 2" --ledger 500
run 2 "--pkg 的 tag 不存在 → 退出 2" --ledger 500 --pkg v9.9.9-test.1

echo
echo "通过 ${PASS}，失败 ${FAIL}"
[ "$FAIL" = 0 ]
