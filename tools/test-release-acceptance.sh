#!/usr/bin/env bash
# 发版前验收门禁（tools/flow/release-acceptance.sh，#1471 按版本验收）的判据测试：每条红都配一条去掉触发条件的绿作反证。
# release-acceptance.sh 只是 release-scope.sh --check 的入口；台账更新、重验判定的细节测试在 tools/test-release-scope.sh，
# 这里只测发版视角：台账清零才绿、最后一个 test 包之后合入的界面改动要拦、旧用法（传 tag）报用法错误。
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
mkdir -p "${R}/tools/flow" "${R}/.github" "${TMP}/bin" "${FAKE}" "${TMP}/tpl"
for f in release-scope.sh release-acceptance.sh acceptance-gate.sh owner-triage.sh worker-lib.sh decision-lib.sh; do
  cp "${SRC}/tools/flow/${f}" "${R}/tools/flow/"
done
cp "${SRC}/tools/ci-paths.sh" "${R}/tools/"
printf '+ core/**\n' >"${R}/.github/core-paths.txt"

# 假 gh：只读台账正文 $FAKE/ledger（--check 不读 PR 与卡）；$FAKE/ledger.fail 存在 → 读失败。
cat >"${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "issue view")
    [ -e "${FAKE}/ledger.fail" ] && { echo "HTTP 502: stub failure" >&2; exit 1; }
    cat "${FAKE}/ledger" ;;
  *) echo "stub gh: unsupported $*" >&2; exit 2 ;;
esac
STUB
chmod +x "${TMP}/bin/gh"

# v1.0.0（正式）→ #31 界面、#32 只改文档 → v1.1.0-test.1 → #33 界面 → v1.1.0-test.2 → #34 / #35 把 #31 的文件改了又改回
(
  cd "$R" || exit 1
  export GIT_TEMPLATE_DIR="${TMP}/tpl"
  git init -q -b main
  git config user.email t@t
  git config user.name t
  mkdir -p apps/desktop/src docs
  echo 0 >apps/desktop/src/A.svelte
  c() { git add -A && git -c core.hooksPath=/dev/null commit -q --no-verify -m "$1"; }
  c "init"
  git tag v1.0.0
  echo 1 >apps/desktop/src/A.svelte && c "feat: A (#31)"
  echo 1 >docs/x.md && c "docs: x (#32)"
  git tag v1.1.0-test.1
  echo 1 >apps/desktop/src/B.svelte && c "feat: B (#33)"
  git tag v1.1.0-test.2
  # #34 改了 #31 的文件、#35 又改回：两头内容一样，但中间被改动过
  echo 9 >apps/desktop/src/A.svelte && c "feat: A 改版 (#34)"
  echo 1 >apps/desktop/src/A.svelte && c "revert: A 改回 (#35)"
  git update-ref refs/remotes/origin/main HEAD
) || { echo "造临时仓库失败"; exit 1; }

ledger() { # ledger <#31 的勾选：x 或空格>
  printf '[验收] v1.1.0\n\n<!-- release-ledger:begin since=v1.0.0 -->\n- [%s] #31 ui | 待验 @v1.1.0-test.1 | 场景：#131：A\n<!-- release-ledger:end -->\n' "$1" >"${FAKE}/ledger"
}
run() { # run <期望退出码> <描述> [参数...]
  local want="$1" desc="$2" rc
  shift 2
  (cd "$R" && PATH="${TMP}/bin:${PATH}" FAKE="$FAKE" PPASS_HOOK_REPO=o/r bash tools/flow/release-acceptance.sh "$@") >"${TMP}/out" 2>&1
  rc=$?
  if [ "$rc" = "$want" ]; then ok "$desc"; else bad "${desc}（期望 ${want}，实际 ${rc}：$(tr '\n' ' ' <"${TMP}/out")）"; fi
}
has() { grep -qF -- "$1" "${TMP}/out"; }

ledger ' '
run 1 "台账里 #31 没勾 → 红" 500 v1.1.0-test.1
has "#31（ui）待验 @v1.1.0-test.1" && ok "  点名 #31" || bad "  没点名：$(cat "${TMP}/out")"
ledger x
run 0 "反证：#31 勾上 → 绿" 500 v1.1.0-test.1
has "#32" && bad "  只改文档的 #32 被点名" || ok "  只改文档的 #32 不在范围"
run 1 "候选版默认 origin/main：最后一个 test 包之后合入的 #33 不在台账 → 红" 500
has "#33（ui）待验：不在台账里" && ok "  点名 #33" || bad "  没点名 #33：$(cat "${TMP}/out")"
has "#31（ui）待重验：验过 @v1.1.0-test.1 之后又改了 apps/desktop/src/A.svelte" &&
  ok "  #31 的文件在验过之后被改了又改回（两头内容一样）→ 仍待重验" || bad "  改了又改回没判待重验：$(cat "${TMP}/out")"
run 1 "  反证：候选版停在改动之前（test.2，只多了 #33）→ 只因 #33 红" 500 v1.1.0-test.2
has "#31（" && bad "  文件没被碰过的 #31 也被点名：$(cat "${TMP}/out")" || ok "  #31 不点名"
touch "${FAKE}/ledger.fail"
run 1 "读不到台账 → 红（fail-closed）" 500 v1.1.0-test.1
rm -f "${FAKE}/ledger.fail"
run 2 "旧用法（传上一个正式 tag）→ 用法错误 2" v1.0.0
run 2 "没给台账号 → 2"
run 2 "候选 ref 不存在 → 2" 500 no-such-ref
run 2 "多余参数 → 2" 500 main extra

echo
echo "通过 ${PASS}，失败 ${FAIL}"
[ "$FAIL" = 0 ]
