#!/usr/bin/env bash
# 按版本验收（tools/flow/release-scope.sh，#1471）的判据测试：每条红都配一条去掉触发条件的绿作反证。
# 临时 git 仓库里造 squash 风格的提交「... (#N)」（每个提交真改文件，classify 看文件）、一个正式 tag 和两个 test 包 tag；
# gh 是 PATH 注入的桩，读写 $FAKE 目录：
#   $FAKE/pr/<N>.body        PR 正文；$FAKE/pr/<N>.fail 存在 → gh pr view 失败
#   $FAKE/issue/<M>.body     卡 / 台账正文（gh issue edit --body-file 写回这里）；$FAKE/issue/<M>.fail → 读失败
#   $FAKE/releases.json      GitHub Releases 列表（供 gh release list）；$FAKE/releases.fail → 查询失败
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
for f in release-scope.sh release-acceptance.sh acceptance-gate.sh repo-lib.sh decision-lib.sh; do
  cp "${SRC}/tools/flow/${f}" "${R}/tools/flow/"
done
cp "${SRC}/tools/ci-paths.sh" "${R}/tools/"
printf '+ core/**\n' >"${R}/.github/core-paths.txt"

cat >"${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -u
kind="$1"; sub="$2"
case "${kind} ${sub}" in
  "pr view")
    num="$3"
    [ -e "${FAKE}/pr/${num}.fail" ] && { echo "HTTP 502: stub failure" >&2; exit 1; }
    [ -f "${FAKE}/pr/${num}.body" ] || { echo "no pull request #${num}" >&2; exit 1; }
    cat "${FAKE}/pr/${num}.body"
    ;;
  "issue view")
    num="$3"
    [ -e "${FAKE}/issue/${num}.fail" ] && { echo "HTTP 502: stub failure" >&2; exit 1; }
    [ -f "${FAKE}/issue/${num}.body" ] || { echo "no issue #${num}" >&2; exit 1; }
    cat "${FAKE}/issue/${num}.body"
    ;;
  "issue edit")
    num="$3"
    shift 3
    while [ "$#" -gt 0 ]; do
      case "$1" in --body-file) cp "$2" "${FAKE}/issue/${num}.body"; shift 2 ;; *) shift ;; esac
    done
    ;;
  "release list")
    [ -e "${FAKE}/releases.fail" ] && { echo "HTTP 502: stub release list failure" >&2; exit 1; }
    python3 - "${FAKE}/releases.json" "$@" <<'PY'
import json, sys
path, argv = sys.argv[1], sys.argv[2:]
rows = json.load(open(path, encoding="utf-8"))
excl_draft = "--exclude-drafts" in argv
excl_pre = "--exclude-pre-releases" in argv
out = []
for r in rows:
    if excl_draft and r.get("isDraft"):
        continue
    if excl_pre and r.get("isPrerelease"):
        continue
    out.append(r)
print(json.dumps(out))
PY
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
  git init --template= -q -b main
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
  # 之后（只给「列范围」的边界用例）：没有 PR 号、只改文档 → test.3 → 早年普通合并「Merge pull request #29」改界面 → test.4
  # → 没有 PR 号、直接推的界面改动
  mkdir -p docs && echo 1 >docs/y.md && c "docs: 直接推的文档"
  git tag v1.1.0-test.3
  git switch -q -c side && echo 1 >apps/desktop/src/M.svelte && c "feat: 合并分支上的界面"
  git switch -q main && git -c core.hooksPath=/dev/null merge -q --no-ff --no-verify -m "Merge pull request #29 from o/side" side
  git tag v1.1.0-test.4
  echo 1 >apps/desktop/src/D.svelte && c "fix: 直接推的界面改动"
  git update-ref refs/remotes/origin/main HEAD
) || { echo "造临时仓库失败"; exit 1; }

reset_fake() {
  rm -f "${FAKE}"/pr/* "${FAKE}"/issue/* "${FAKE}/releases.fail"
  cat >"${FAKE}/releases.json" <<'JSON'
[
  {"tagName": "v1.0.0", "isDraft": false, "isPrerelease": false, "publishedAt": "2026-10-01T00:00:00Z"},
  {"tagName": "v1.1.0-test.1", "isDraft": true, "isPrerelease": false, "publishedAt": ""},
  {"tagName": "v1.1.0-test.2", "isDraft": true, "isPrerelease": false, "publishedAt": ""}
]
JSON
  for n in 21 22 23 24 26 27 28 29; do printf 'closes #%s\n' "$((n + 100))" >"${FAKE}/pr/${n}.body"; done
  printf '改了设置页，没关联卡\n' >"${FAKE}/pr/25.body"
  for n in 121 122 123 124 126 127 128 129; do printf '卡 %s\n\n**范围**：\n```\nx\n```\n\n**验收场景**：\nE3 场景%s 第一行\n第二行 a|b\n\n**是否核心**：否\n' "$n" "$n" >"${FAKE}/issue/${n}.body"; done
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
run 0 "没有 PR 号、只改文档的提交 → 不算 PR，放过" --since v1.1.0-test.2 --to v1.1.0-test.3
has "1 个 PR 里 1 个用户看得见" && ok "  只数到 #28" || bad "  计数不对：$(head -1 "${TMP}/out")"
run 0 "早年普通合并「Merge pull request #29 from …」→ 认出 PR 号" --since v1.1.0-test.3 --to v1.1.0-test.4
has "- #29 ui | 场景：#129：" && ok "  #29 进范围（文件对第一父提交取，合并分支上的界面改动算进来）" || bad "  #29 没认出：$(cat "${TMP}/out")"
run 1 "没有 PR 号、改了界面的提交 → 进不了台账，红（fail-closed）" --since v1.1.0-test.4 --to origin/main
has "没有 PR 号、改了用户看得见的文件" && ok "  点名这个提交" || bad "  没点名：$(cat "${TMP}/out")"
run 1 "起点不是候选版的祖先 → 红" --since v1.1.0-test.2 --to v1.1.0-test.1
has "不是 v1.1.0-test.1 的祖先" && ok "  说明起点不在候选版这条线上" || bad "  没说明：$(cat "${TMP}/out")"

echo "── 第一个 test 包：建台账"
reset_fake
run 0 "--dry-run 只打印" --ledger 500 --pkg v1.1.0-test.1 --dry-run
lhas "release-ledger" && bad "  --dry-run 改了台账" || ok "  --dry-run 不改台账"
run 0 "--ledger 500 --pkg v1.1.0-test.1 → 写台账" --ledger 500 --pkg v1.1.0-test.1
lhas "<!-- release-ledger:begin since=v1.0.0 -->" && ok "  记下起点 since=v1.0.0" || bad "  没记起点：$(cat "$L")"
lhas "人写的说明保留" && ok "  台账块外的正文保留" || bad "  正文被冲掉了"
SHA1="$(git -C "$R" rev-parse v1.1.0-test.1)"
SHA2="$(git -C "$R" rev-parse v1.1.0-test.2)"
lhas "- [ ] #21 ui | 待验 @v1.1.0-test.1（${SHA1:0:12}） | 场景：#121：E3 场景121" && ok "  #21 待验 @test.1（记下包的提交），带场景" || bad "  #21 不对：$(cat "$L")"
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
lhas "- [ ] #21 ui | 待重验 @v1.1.0-test.2（${SHA2:0:12}，上次验过 @v1.1.0-test.1，又改了 apps/desktop/src/App.svelte）" &&
  ok "已验的 #21，文件被 #26 改过 → 待重验" || bad "#21 没判待重验：$(cat "$L")"
lhas "| 结论：首页 OK" && ok "  结论保留" || bad "  结论丢了"
lhas "- [x] #25 ui | 已验 @v1.1.0-test.1（${SHA1:0:12}）" && ok "反证：已验的 #25，文件没被改 → 沿用（去掉重验判断，两条里必有一条红）" || bad "#25 没沿用：$(cat "$L")"
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
# #1486：旧 test tag 会被 cleanup-test-channel.sh 连同草稿删掉；台账记了包的提交，tag 删了也按提交判。
cp "$L" "${TMP}/ledger.keep"
check_test2() { (cd "$R" && PATH="${TMP}/bin:${PATH}" FAKE="$FAKE" PPASS_HOOK_REPO=o/r bash tools/flow/release-acceptance.sh 500 v1.1.0-test.2) >"${TMP}/out" 2>&1; }
git -C "$R" tag -d v1.1.0-test.1 >/dev/null
check_test2
[ $? = 0 ] && ok "验过的包 tag 已删、提交还在、文件没再改 → 沿用（绿）" || bad "tag 删了就误红：$(cat "${TMP}/out")"
sed -i.bak -E 's/@v1\.1\.0-test\.1（[0-9a-f]+）/@v1.1.0-test.1/' "$L" && rm -f "${L}.bak"
check_test2
[ $? = 1 ] && has "#25（ui）待重验：判不了" && ok "  反证：去掉提交号（旧格式只有 tag）、tag 已删 → 待重验" || bad "  没提交号也放行了：$(cat "${TMP}/out")"
git -C "$R" tag v1.1.0-test.1 "$SHA1"
check_test2
[ $? = 0 ] && ok "  旧格式只有 tag、tag 在 → 照旧按 tag 判（绿）" || bad "  旧格式误红：$(cat "${TMP}/out")"
cp "${TMP}/ledger.keep" "$L"
sed -i.bak -E 's/^- \[x\] #26 ui \| (已|待)验 @v1\.1\.0-test\.2（[0-9a-f]+）/- [x] #26 ui | \1验 @v9.9.9-test.1/' "$L" && rm -f "${L}.bak"
check_test2
[ $? = 1 ] && has "#26（ui）待重验：判不了" && ok "勾了但验过的包 tag 不存在、没有提交号 → 待重验（fail-closed）" || bad "包号不存在却放行：$(cat "${TMP}/out")"
cp "${TMP}/ledger.keep" "$L"
sed -i.bak -E 's/^- \[x\] #26 ui \| (已|待)验 @v1\.1\.0-test\.2（[0-9a-f]+）/- [x] #26 ui | \1验 @v9.9.9-test.1（deadbeef0000）/' "$L" && rm -f "${L}.bak"
check_test2
[ $? = 1 ] && has "#26（ui）待重验：判不了" && ok "  提交号解析不到、tag 也不存在 → 待重验（fail-closed）" || bad "  假提交号放行了：$(cat "${TMP}/out")"

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

echo "── #1636 只认已 Publish 的正式 Release（跳过草稿 / Prerelease，起止不一致告警，gh 失败 fail-closed）"
# 造一个隔离仓库：v1.0.0（已 Publish）→ #201 → v1.0.5（Prerelease 无后缀）→ #202 → v1.1.0（git tag 存在但 Release 是 Draft）→ #203 → v1.1.1-rc.1（Prerelease 有后缀）→ #204 → v1.2.0-test.1（-test.）
R2="${TMP}/repo2"
mkdir -p "${R2}/tools/flow" "${R2}/.github"
for f in release-scope.sh release-acceptance.sh acceptance-gate.sh repo-lib.sh decision-lib.sh; do
  cp "${SRC}/tools/flow/${f}" "${R2}/tools/flow/"
done
cp "${SRC}/tools/ci-paths.sh" "${R2}/tools/"
printf '+ core/**\n' >"${R2}/.github/core-paths.txt"
(
  cd "$R2" || exit 1
  export GIT_TEMPLATE_DIR="${TMP}/tpl"
  git init --template= -q -b main
  git config user.email t@t
  git config user.name t
  mkdir -p apps/desktop/src
  c() { git add -A && git -c core.hooksPath=/dev/null commit -q --no-verify -m "$1"; }
  echo 0 >apps/desktop/src/A.svelte && c "init" && git tag v1.0.0
  echo 1 >apps/desktop/src/B.svelte && c "feat: B (#201)" && git tag v1.0.5
  echo 1 >apps/desktop/src/C.svelte && c "feat: C (#202)" && git tag v1.1.0
  echo 1 >apps/desktop/src/D.svelte && c "feat: D (#203)" && git tag v1.1.1-rc.1
  echo 1 >apps/desktop/src/E.svelte && c "feat: E (#204)" && git tag v1.2.0-test.1
  git update-ref refs/remotes/origin/main HEAD
) || { echo "造 R2 失败"; exit 1; }
reset_fake
for n in 201 202 203 204; do printf 'closes #%s\n' "$((n + 100))" >"${FAKE}/pr/${n}.body"; done
for n in 301 302 303 304; do printf '**验收场景**：\n场景%s\n' "$n" >"${FAKE}/issue/${n}.body"; done
cat >"${FAKE}/releases.json" <<'JSON'
[
  {"tagName": "v1.2.0-test.1", "isDraft": true, "isPrerelease": false, "publishedAt": ""},
  {"tagName": "v1.1.1-rc.1", "isDraft": false, "isPrerelease": true, "publishedAt": "2026-11-08T00:00:00Z"},
  {"tagName": "v1.1.0", "isDraft": true, "isPrerelease": false, "publishedAt": ""},
  {"tagName": "v1.0.5", "isDraft": false, "isPrerelease": true, "publishedAt": "2026-11-01T00:00:00Z"},
  {"tagName": "v1.0.0", "isDraft": false, "isPrerelease": false, "publishedAt": "2026-10-28T00:00:00Z"}
]
JSON
run_r2() {
  local want="$1" desc="$2" script="${3}" rc
  shift 3
  (cd "$R2" && PATH="${TMP}/bin:${PATH}" FAKE="$FAKE" PPASS_HOOK_REPO=o/r \
    bash "$script" "$@") >"${TMP}/out" 2>&1
  rc=$?
  if [ "$rc" = "$want" ]; then ok "$desc"; else bad "${desc}（期望 ${want}，实际 ${rc}：$(tr '\n' ' ' <"${TMP}/out")）"; fi
}
run_r2 0 "跳过草稿 v1.1.0 与 Prerelease（v1.0.5 / v1.1.1-rc.1），取已 Publish 的 v1.0.0 为起点" "tools/flow/release-scope.sh" --to v1.2.0-test.1
has "验收范围 v1.0.0..v1.2.0-test.1" && ok "  起点是 v1.0.0" || bad "  起点不对：$(cat "${TMP}/out")"
has "- #201 ui" && has "- #202 ui" && has "- #203 ui" && has "- #204 ui" && ok "  #201..#204 全部进范围（未因草稿 v1.1.0 截断）" || bad "  范围漏项：$(cat "${TMP}/out")"

# 反证：退回旧逻辑（只按 git describe 取 tag，不过滤草稿）→ 误取 v1.1.0，漏掉 #201/#202
cp "${R2}/tools/flow/release-scope.sh" "${R2}/tools/flow/release-scope-old.sh"
python3 - "${R2}/tools/flow/release-scope-old.sh" <<'PY'
import re, sys
p = sys.argv[1]
txt = open(p, encoding="utf-8").read()
old = re.sub(
    r"last_formal\(\) \{.*?\n\}",
    "last_formal() { git describe --tags --abbrev=0 --match 'v*' --exclude '*-*' \"$1\" 2>/dev/null; }",
    txt, count=1, flags=re.S,
)
assert old != txt
open(p, "w", encoding="utf-8").write(old)
PY
run_r2 0 "反证：旧逻辑只按 git tag 取到草稿 v1.1.0" "tools/flow/release-scope-old.sh" --to v1.2.0-test.1
has "验收范围 v1.1.0..v1.2.0-test.1" && ! has "#201" && ok "  旧逻辑确实误取 v1.1.0 并漏掉 #201（证明新逻辑有效）" || bad "  反证没复现：$(cat "${TMP}/out")"

# 已有台账 since= 与最新已 Publish 版不一致：保留原 since= 不自动改写，并输出警告
printf '[验收] v1.2.0\n\n<!-- release-ledger:begin since=v1.1.0 -->\n<!-- release-ledger:end -->\n' >"${FAKE}/issue/600.body"
run_r2 0 "已有台账 since=v1.1.0 与最新已 Publish 版 v1.0.0 不一致 → 仍退出 0 更新" "tools/flow/release-scope.sh" --ledger 600 --pkg v1.2.0-test.1
has "与当前最新已发布的正式版（v1.0.0）不一致" && ok "  输出起点不一致警告" || bad "  缺少不一致警告：$(cat "${TMP}/out")"
grep -qF "<!-- release-ledger:begin since=v1.1.0 -->" "${FAKE}/issue/600.body" && ok "  保留原 since=v1.1.0 不自动改写" || bad "  since= 被篡改：$(cat "${FAKE}/issue/600.body")"

# gh 查询失败 → fail-closed 退出 1，不回退到 git describe
touch "${FAKE}/releases.fail"
run_r2 1 "gh release list 失败 → fail-closed 退出 1" "tools/flow/release-scope.sh" --to v1.2.0-test.1
has "fail-closed" && ! has "v1.1.0.." && ok "  失败时明确报错且不回退 git describe" || bad "  输出不对：$(cat "${TMP}/out")"
rm -f "${FAKE}/releases.fail"

echo
echo "通过 ${PASS}，失败 ${FAIL}"
[ "$FAIL" = 0 ]
