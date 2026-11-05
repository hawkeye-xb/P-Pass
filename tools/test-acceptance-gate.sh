#!/usr/bin/env bash
# acceptance gate（tools/flow/acceptance-gate.sh）的判据测试：每条红都配一条去掉触发条件的绿作反证。
# 用法: tools/test-acceptance-gate.sh    退出码: 0 全过 / 1 有失败
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok() { printf '  ✅ %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL + 1)); }

mkdir -p "${TMP}/repo/tools/flow" "${TMP}/repo/.github"
cp "${SRC}/tools/flow/acceptance-gate.sh" "${SRC}/tools/flow/owner-triage.sh" "${TMP}/repo/tools/flow/"
cp "${SRC}/tools/ci-paths.sh" "${TMP}/repo/tools/"
printf '+ core/**\n' >"${TMP}/repo/.github/core-paths.txt"
G="${TMP}/repo/tools/flow/acceptance-gate.sh"

# gate <期望 0|1> <描述> <改动文件，空格分隔> <PR 正文>
gate() {
  local want="$1" desc="$2" files="$3" body="$4" rc
  printf '%s\n' $files >"${TMP}/files"
  printf '%s\n' "$body" >"${TMP}/body"
  bash "$G" check --repo "${TMP}/repo" --files "${TMP}/files" --body "${TMP}/body" >"${TMP}/out" 2>&1
  rc=$?
  if [ "$rc" = "$want" ]; then ok "${desc}"; else bad "${desc}（期望 ${want}，实际 ${rc}：$(tr '\n' ' ' <"${TMP}/out")）"; fi
}

UI=apps/ios/PPass/Home.swift
LINE='产品负责人 2026-11-05 15:30 真机验收通过'

gate 1 "碰界面、正文没有验收行 → 红" "$UI" $'closes #1\n- 真机验收：待产品负责人真机验收'
gate 0 "反证：补上验收行 → 绿" "$UI" $'closes #1\n'"$LINE"
gate 0 "  验收行带列表符与加粗也认" "$UI" $'closes #1\n- **'"$LINE"'**'
gate 1 "「未真机验收通过」→ 红" "$UI" $'closes #1\n产品负责人 2026-11-05 15:30 未真机验收通过'
gate 1 "  验收行嵌在别的句子中间 → 红" "$UI" $'closes #1\n备注：'"$LINE"
gate 1 "  日期不是具体日期 → 红" "$UI" $'closes #1\n产品负责人 <时间> 真机验收通过'
gate 1 "碰核心路径、没有验收行 → 红" "core/x.rs" "closes #1"
gate 0 "反证：核心路径补行 → 绿" "core/x.rs" $'closes #1\n'"$LINE"
gate 0 "纯文档（自动级）→ 绿" "docs/a.md" "closes #1"
gate 0 "反证口径：没有验收行但不碰界面，同样绿" "tools/x.sh docs/a.md" "closes #1"
gate 1 "多文件里只要一个碰界面 → 红" "docs/a.md $UI" "closes #1"
gate 1 "文案路径 assets/i18n 也算界面 → 红" "assets/i18n/zh.json" "closes #1"

# classify
printf '%s\n' "$UI" | bash "$G" classify --repo "${TMP}/repo" | grep -qx ui && ok "classify：界面 → ui" || bad "classify 界面"
printf '%s\n' core/x.rs | bash "$G" classify --repo "${TMP}/repo" | grep -qx core && ok "classify：核心 → core" || bad "classify 核心"
printf '%s\n' docs/a.md | bash "$G" classify --repo "${TMP}/repo" | grep -qx none && ok "classify：文档 → none" || bad "classify 文档"
# 界面清单读不到 → 宁严勿松
rm "${TMP}/repo/tools/flow/owner-triage.sh"
printf '%s\n' docs/a.md | bash "$G" classify --repo "${TMP}/repo" | grep -qx ui && ok "界面清单读不到 → 按需要验收处理" || bad "清单缺失时放行了"
# 用法错误
bash "$G" check >/dev/null 2>&1; [ $? = 2 ] && ok "缺参数 → 退出码 2" || bad "缺参数退出码不对"

echo
echo "通过 ${PASS}，失败 ${FAIL}"
[ "$FAIL" -eq 0 ]
