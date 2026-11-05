#!/usr/bin/env bash
# 发版前验收门禁（tools/flow/release-acceptance.sh）的判据测试：每条红都配一条去掉触发条件的绿作反证。
# 临时 git 仓库里造 squash 风格的提交「... (#N)」与一个 tag；gh 是 PATH 注入的桩，读 $FAKE 目录：
#   $FAKE/pr/<N>.body          PR 正文；$FAKE/pr/<N>.fail 存在 → gh pr view 失败
#   $FAKE/issue/<M>.body       模块卡正文；$FAKE/issue/<M>.c<k> 各条评论；$FAKE/issue/<M>.fail 存在 → 读失败
# 验收行判定用真实的 acceptance-gate.sh record（拷进临时仓库，同 tools/test-acceptance-gate.sh）。
# 用法: tools/test-release-acceptance.sh    退出码: 0 全过 / 1 有失败
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
mkdir -p "${R}/tools/flow" "${R}/.github" "${TMP}/bin" "${FAKE}/pr" "${FAKE}/issue"
for f in release-acceptance.sh acceptance-gate.sh owner-triage.sh worker-lib.sh decision-lib.sh; do
  cp "${SRC}/tools/flow/${f}" "${R}/tools/flow/"
done
cp "${SRC}/tools/ci-paths.sh" "${R}/tools/"
printf '+ core/**\n' >"${R}/.github/core-paths.txt"

# ── 假 gh ─────────────────────────────────────────────────────────────
cat >"${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -u
kind="$1"; sub="$2"; num="$3"
case "${kind} ${sub}" in
  "pr view")
    [ -e "${FAKE}/pr/${num}.fail" ] && { echo "HTTP 502: stub failure" >&2; exit 1; }
    [ -f "${FAKE}/pr/${num}.body" ] || { echo "no pull request #${num}" >&2; exit 1; }
    case " $* " in
      *" files "*) if [ -f "${FAKE}/pr/${num}.files" ]; then cat "${FAKE}/pr/${num}.files"; else echo apps/desktop/src/App.svelte; fi ;;
      *) cat "${FAKE}/pr/${num}.body" ;;
    esac
    ;;
  "issue view")
    [ -e "${FAKE}/issue/${num}.fail" ] && { echo "HTTP 502: stub failure" >&2; exit 1; }
    [ -f "${FAKE}/issue/${num}.body" ] || { echo "no issue #${num}" >&2; exit 1; }
    cat "${FAKE}/issue/${num}.body"
    for c in "${FAKE}/issue/${num}".c*; do [ -f "$c" ] && cat "$c"; done
    exit 0
    ;;
  *) echo "stub gh: unsupported $*" >&2; exit 2 ;;
esac
STUB
chmod +x "${TMP}/bin/gh"

# ── 临时仓库：tag 之前 1 个 PR，之后 4 个 PR + 1 条不带 PR 号的提交 ──────────
(
  cd "$R" || exit 1
  git init -q -b main
  git config user.email t@t
  git config user.name t
  # 夹具提交是测试数据，不受本机提交钩子（身份白名单等）影响。
  c() { git -c core.hooksPath=/dev/null commit -q --no-verify --allow-empty -m "$1"; }
  c "init"
  c "feat: 旧功能 (#10)"
  git tag v1.0.0
  c "feat: 首页改版第一块 (#21)"
  c "feat: 首页改版第二块（#99） (#22)"
  c "chore: 没有 PR 号的提交"
  c "docs: 文档 (#23)"
  c "fix: 别的 (#24)"
  git update-ref refs/remotes/origin/main HEAD
) || { echo "造临时仓库失败"; exit 1; }

body() { printf '%s\n' "$2" >"${FAKE}/pr/$1.body"; }
LINE='产品负责人 2026-11-05 15:30 真机验收通过'
reset_fake() {
  rm -f "${FAKE}"/pr/* "${FAKE}"/issue/*
  body 10 'closes #1'
  body 21 'closes #2'
  body 22 'closes #3'
  body 23 'closes #4'
  body 24 'closes #5'
  printf '首页改版模块卡\n' >"${FAKE}/issue/100.body"
  printf '首页另一模块卡\n' >"${FAKE}/issue/101.body"
}

# run <期望退出码> <描述> [参数...]：在临时仓库里跑，输出留在 $TMP/out
run() {
  local want="$1" desc="$2" rc
  shift 2
  (cd "$R" && PATH="${TMP}/bin:${PATH}" FAKE="$FAKE" PPASS_HOOK_REPO=o/r \
    bash tools/flow/release-acceptance.sh "$@") >"${TMP}/out" 2>&1
  rc=$?
  if [ "$rc" = "$want" ]; then ok "$desc"; else bad "${desc}（期望 ${want}，实际 ${rc}：$(tr '\n' ' ' <"${TMP}/out")）"; fi
}
has() { grep -qF -- "$1" "${TMP}/out"; }

echo "── 没有随模块验收的 PR"
reset_fake
run 0 "范围内没有随模块验收的 PR → 绿" v1.0.0
has "通过" && ok "  打印通过" || bad "  没打印通过：$(cat "${TMP}/out")"

echo "── 标了随模块验收、模块卡无验收记录"
reset_fake
body 21 $'closes #2\n随模块验收 #100'
body 22 $'closes #3\n- **随模块验收 #100**'
run 1 "模块卡 #100 没有验收记录 → 红" v1.0.0
has "#100 没有验收记录（来自 PR #21、#22）" && ok "  点名 #100 与来源 PR #21、#22（去重成一行）" || bad "  输出没点名：$(cat "${TMP}/out")"
[ "$(grep -c '#100 没有验收记录' "${TMP}/out")" = 1 ] && ok "  同一模块卡只报一行" || bad "  #100 报了多行：$(cat "${TMP}/out")"
printf '看过了，有问题再说\n' >"${FAKE}/issue/100.c1"
run 1 "  评论里没有验收行（只是普通评论）→ 仍红" v1.0.0
printf '%s\n' "$LINE" >"${FAKE}/issue/100.c2"
run 0 "反证：#100 的评论里补一条验收行 → 绿" v1.0.0
run 0 "  显式给 head-ref（main）同样绿" v1.0.0 main
rm -f "${FAKE}/issue/100.c2"
printf '备注：%s\n' "$LINE" >"${FAKE}/issue/100.c2"
run 1 "  验收行嵌在评论句子中间 → 红" v1.0.0
rm -f "${FAKE}/issue/100.c1" "${FAKE}/issue/100.c2"
printf '首页改版模块卡\n\n- %s\n' "$LINE" >"${FAKE}/issue/100.body"
run 0 "  验收行写在模块卡正文里也认 → 绿" v1.0.0

echo "── 两张模块卡，一张有一张没有"
reset_fake
body 21 $'随模块验收 #100'
body 24 $'> 随模块验收 #101'
printf '%s\n' "$LINE" >"${FAKE}/issue/100.c1"
run 1 "#101 缺、#100 有 → 红" v1.0.0
has "#101 没有验收记录（来自 PR #24）" && ok "  只点名 #101" || bad "  输出不对：$(cat "${TMP}/out")"
has "#100 没有验收记录" && bad "  有记录的 #100 也被点名了" || ok "  有记录的 #100 不报"

echo "── tag 之前合入的 PR 不检查"
reset_fake
body 10 $'closes #1\n随模块验收 #100'
run 0 "tag 之前的 PR #10 标了随模块验收、#100 无记录 → 不检查，绿" v1.0.0
body 21 $'closes #2\n随模块验收 #100'
run 1 "反证：同样的标记放进 tag 之后的 PR #21 → 红" v1.0.0

echo "── 标记必须单独成行"
reset_fake
body 21 $'closes #2\n这次改动以后会随模块验收 #100 一起看'
run 0 "「随模块验收 #100」嵌在句子中间 → 不算标记，绿" v1.0.0
body 21 $'closes #2\n随模块验收 #100'
run 1 "反证：同样内容单独成行 → 红" v1.0.0

echo "── 文案确认行只对更新说明的模块算数（CodeRabbit #1456）"
COPY='产品负责人 2026-11-05 15:30 文案确认通过'
reset_fake
body 21 $'随模块验收 #100'
printf '%s\n' "$COPY" >"${FAKE}/issue/100.c1"
run 1 "界面改动的模块卡上只有文案确认行 → 红（不算验收）" v1.0.0
has "#100 没有验收记录" && ok "  点名 #100" || bad "  输出不对：$(cat "${TMP}/out")"
printf 'release/notes/android/0.12.0.zh.txt\nCHANGELOG.md\n' >"${FAKE}/pr/21.files"
run 0 "反证：来源 PR 只改更新说明 → 文案确认行算数，绿" v1.0.0
body 22 $'随模块验收 #100'
run 1 "  同一模块卡另有界面改动的来源 PR → 文案确认不够，红" v1.0.0
printf '%s\n' "$LINE" >"${FAKE}/issue/100.c2"
run 0 "  补真机 / SOP 验收行 → 绿" v1.0.0

echo "── gh 读失败 fail-closed"
reset_fake
touch "${FAKE}/pr/23.fail"
run 1 "gh 读 PR #23 失败 → 红（不当通过）" v1.0.0
has "读不到 PR #23" && ok "  说明读不到哪个 PR" || bad "  没说明读不到哪个：$(cat "${TMP}/out")"
rm -f "${FAKE}/pr/23.fail"
run 0 "反证：PR #23 能读 → 绿" v1.0.0
body 21 $'随模块验收 #100'
touch "${FAKE}/issue/100.fail"
run 1 "gh 读模块卡 #100 失败 → 红" v1.0.0
has "读不到模块卡 #100" && ok "  说明读不到哪张卡" || bad "  没说明读不到哪张卡：$(cat "${TMP}/out")"

echo "── 用法"
reset_fake
run 2 "tag 不存在 → 退出 2" v9.9.9
has "v9.9.9 不存在" && ok "  说明 tag 不存在" || bad "  没说明：$(cat "${TMP}/out")"
run 2 "没给 tag → 退出 2"
run 2 "head-ref 不存在 → 退出 2" v1.0.0 no-such-ref

echo
echo "通过 ${PASS}，失败 ${FAIL}"
[ "$FAIL" = 0 ]
