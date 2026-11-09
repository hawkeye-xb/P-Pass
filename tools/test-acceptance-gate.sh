#!/usr/bin/env bash
# acceptance gate（tools/flow/acceptance-gate.sh）的判据测试：每条红都配一条去掉触发条件的绿作反证。
# #1471 起用户看得见的改动合入不要验收行（随版本验收），核心仍要已采纳方案。
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
cp "${SRC}/tools/flow/acceptance-gate.sh" "${SRC}/tools/flow/owner-triage.sh" "${SRC}/tools/flow/decision-lib.sh" "${TMP}/repo/tools/flow/"
cp "${SRC}/tools/ci-paths.sh" "${TMP}/repo/tools/"
# core/** 是用户看不见的核心（如发布链脚本）；apps/android/core/** 是用户看得见的核心（如配对界面背后的代码）。
printf '+ core/**\n+ apps/android/core/**\n+ apps/desktop/src-tauri/tauri.conf.json\n' >"${TMP}/repo/.github/core-paths.txt"
# 已采纳方案只认 origin/main 上的版本：临时仓库里放一份已采纳、一份草稿，记成 origin/main。
mkdir -p "${TMP}/repo/docs/decisions"
printf '# 方案\n\n- 状态：已采纳\n' >"${TMP}/repo/docs/decisions/2026-11-01-adopted.md"
printf '# 方案\n\n- 状态：草稿\n' >"${TMP}/repo/docs/decisions/2026-11-02-draft.md"
(
  cd "${TMP}/repo" || exit 1
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  git init --template= -q && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -q -m init &&
    git update-ref refs/remotes/origin/main HEAD
) || { echo "搭临时仓库失败"; exit 1; }
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
ADR=docs/decisions/2026-11-01-adopted.md

# 按版本验收（#1471）：用户看得见的改动合入时不要验收行，发版前由台账兜住（tools/test-release-scope.sh）
gate 0 "碰界面、正文没有验收行 → 绿（随版本验收）" "$UI" "closes #1"
gate 0 "  正文写着待验收也绿" "$UI" $'closes #1\n- 真机验收：待产品负责人真机验收'
gate 0 "  有旧验收行也绿（不再看这一行）" "$UI" $'closes #1\n'"$LINE"
grep -q '随版本验收' "${TMP}/out" && ok "  输出写明随版本验收" || bad "  输出没写随版本验收：$(cat "${TMP}/out")"
gate 0 "文案路径 assets/i18n 没有验收行 → 绿" "assets/i18n/zh.json" "closes #1"
gate 0 "apps 下的正式文件（备份行为）没有验收行 → 绿" "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt" "closes #1"
NOTE=release/notes/android/0.11.0.zh.txt
gate 0 "只改更新说明、没有文案确认行 → 绿（发版前在台账里确认）" "$NOTE CHANGELOG.md" "closes #1444"
gate 0 "纯文档（自动级）→ 绿" "docs/a.md" "closes #1"

# 看得见的核心：不要验收行，仍要已采纳方案
CV=apps/android/core/Pair.kt
gate 1 "核心、看得见：没有方案引用 → 红" "$CV" "closes #1"
gate 1 "  只有验收行也红（核心要的是方案）" "$CV" $'closes #1\n'"$LINE"
gate 0 "反证：核心看得见引用已采纳方案、没有验收行 → 绿" "$CV" $'closes #1\n方案：'"$ADR"
gate 1 "  引用的是草稿方案 → 红" "$CV" $'closes #1\n方案：docs/decisions/2026-11-02-draft.md'
gate 1 "  旧口径「随模块验收」不再算数，核心没方案仍红" "$CV" $'closes #1\n随模块验收 #9'

# 看不见的核心（#1448）：要已采纳方案 + 测试
gate 1 "核心、看不见：没有方案引用、没有测试 → 红" "core/x.rs" "closes #1"
gate 1 "  只有验收行也不行（看不见的核心要的是方案与测试）" "core/x.rs" $'closes #1\n'"$LINE"
gate 1 "  引用已采纳方案但没带测试 → 红" "core/x.rs" $'closes #1\n方案：'"$ADR"
gate 1 "  带测试但没引用方案 → 红" "core/x.rs tools/test-x.sh" "closes #1"
gate 0 "反证：引用已采纳方案 + 带测试 → 绿" "core/x.rs tools/test-x.sh" $'closes #1\n方案：'"$ADR"
gate 1 "  引用的是草稿方案 → 红" "core/x.rs tools/test-x.sh" $'closes #1\n方案：docs/decisions/2026-11-02-draft.md'
# PR 自己带进来、写着「已采纳」但还没进 origin/main 的方案：工作区里有这份文件，只读 origin/main 才判得红
printf '# 方案\n\n- 状态：已采纳\n' >"${TMP}/repo/docs/decisions/2026-11-03-new.md"
gate 1 "  引用的方案只在工作区（PR 自己加的，写着已采纳）、不在 origin/main 上 → 红" "core/x.rs tools/test-x.sh" $'closes #1\n方案：docs/decisions/2026-11-03-new.md'
gate 1 "  看得见的核心同理：方案只在工作区 → 红" "$CV" $'closes #1\n方案：docs/decisions/2026-11-03-new.md'
(
  cd "${TMP}/repo" || exit 1
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  git add docs/decisions/2026-11-03-new.md && git -c user.name=t -c user.email=t@example.invalid commit -q -m adopt &&
    git update-ref refs/remotes/origin/main HEAD
) || bad "（准备）把方案合进 origin/main 失败"
gate 0 "  反证：同一份方案合进 origin/main 后 → 绿" "core/x.rs tools/test-x.sh" $'closes #1\n方案：docs/decisions/2026-11-03-new.md'
gate 1 "  看不见的核心夹带界面文件 → 按看得见判，仍要方案（没有 → 红）" "core/x.rs tools/test-x.sh $UI" "closes #1"
gate 0 "  反证：同样的改动引用已采纳方案 → 绿" "core/x.rs tools/test-x.sh $UI" $'closes #1\n方案：'"$ADR"

# 只改版本号行（#1451）：tauri.conf.json 只改 version 行不算核心（仍在 apps/** 下，按 ui 级随版本验收）；
# 同时改了 updater endpoint 仍是核心
TC=apps/desktop/src-tauri/tauri.conf.json
mkdiff() { # mkdiff <输出> <额外改动行，空=只改版本号>
  {
    printf 'diff --git a/%s b/%s\nindex 1111111..2222222 100644\n--- a/%s\n+++ b/%s\n' "$TC" "$TC" "$TC" "$TC"
    if [ -z "$2" ]; then
      printf '@@ -4 +4 @@\n-  "version": "0.11.0",\n+  "version": "0.12.0",\n'
    else
      printf '@@ -4 +4 @@\n-  "version": "0.11.0",\n+  "version": "0.12.0",\n@@ -40 +40 @@\n-      "endpoints": ["https://a"],\n+      "endpoints": ["%s"],\n' "$2"
    fi
  } >"$1"
}
mkdiff "${TMP}/v.diff" ""
mkdiff "${TMP}/e.diff" "https://evil"
printf '%s\n' "$TC" | bash "$G" classify --repo "${TMP}/repo" --diff "${TMP}/v.diff" | grep -qx ui && ok "classify：tauri.conf.json 只改版本号 → 不算核心（ui）" || bad "只改版本号仍判核心"
printf '%s\n' "$TC" | bash "$G" classify --repo "${TMP}/repo" --diff "${TMP}/e.diff" | grep -qx core && ok "  反证：同时改了 updater endpoint → core" || bad "改了 endpoint 却没判核心"
printf '%s\n' "$TC" | bash "$G" classify --repo "${TMP}/repo" | grep -qx core && ok "  反证：不给 diff → 按文件判 core" || bad "不给 diff 时没判核心"
printf '%s\n' "$TC" >"${TMP}/files"; printf 'closes #1\n' >"${TMP}/body"
bash "$G" check --repo "${TMP}/repo" --files "${TMP}/files" --body "${TMP}/body" --diff "${TMP}/v.diff" >/dev/null 2>&1 &&
  ok "check：只改版本号、没有方案引用 → 绿（不要已采纳方案）" || bad "只改版本号仍按核心要方案"
bash "$G" check --repo "${TMP}/repo" --files "${TMP}/files" --body "${TMP}/body" --diff "${TMP}/e.diff" >/dev/null 2>&1 &&
  bad "改了 endpoint 没有方案也过了" || ok "  反证：改了 endpoint、没有方案引用 → 红（核心要已采纳方案）"

# classify
printf '%s\n' "$UI" | bash "$G" classify --repo "${TMP}/repo" | grep -qx ui && ok "classify：界面 → ui" || bad "classify 界面"
printf '%s\n' core/x.rs | bash "$G" classify --repo "${TMP}/repo" | grep -qx core-hidden && ok "classify：看不见的核心 → core-hidden" || bad "classify 看不见的核心"
printf '%s\n' "$CV" | bash "$G" classify --repo "${TMP}/repo" | grep -qx core && ok "classify：看得见的核心 → core" || bad "classify 看得见的核心"
printf '%s\n' docs/a.md | bash "$G" classify --repo "${TMP}/repo" | grep -qx none && ok "classify：文档 → none" || bad "classify 文档"
printf '%s\n' "$NOTE" CHANGELOG.md | bash "$G" classify --repo "${TMP}/repo" | grep -qx notes && ok "classify：更新说明 → notes" || bad "classify 更新说明"
printf '%s\n' "$NOTE" "$UI" | bash "$G" classify --repo "${TMP}/repo" | grep -qx ui && ok "classify：更新说明 + 界面 → ui" || bad "classify 混改"
# 测试位置与 Test 结尾的正式文件（release-scope.sh 靠 classify 判哪些 PR 进验收范围）
cls() { printf '%s\n' $2 | bash "$G" classify --repo "${TMP}/repo" | grep -qx "$1" && ok "classify：$3" || bad "classify：$3（实际 $(printf '%s\n' $2 | bash "$G" classify --repo "${TMP}/repo")）"; }
cls ui "apps/desktop/src/SpeedTest.svelte" "SpeedTest.svelte（名字以 Test 结尾的正式组件）→ ui"
cls ui "apps/android/app/src/main/java/com/hawkeyexb/ppass/PairingTest.kt" "  Kotlin 正式文件 PairingTest.kt 放在 main 下 → ui"
cls ui "apps/ios/PPass/Views/SpeedTests.swift" "  Swift 正式文件 SpeedTests.swift 在非测试目录 → ui"
cls none "apps/android/app/src/androidTest/java/com/hawkeyexb/ppass/NetProbeTest.kt apps/ios/PPassTests/XTests.swift apps/ios/Packages/PPassCore/Tests/PPassCoreTests/Flow/A.swift apps/desktop/src/a.spec.ts apps/desktop/src/__tests__/b.js apps/desktop/src-tauri/tests/c.rs apps/android/app/src/sharedTest/java/com/hawkeyexb/ppass/transport/PairingQrAddr.kt apps/ios/TransportFFITests/Tests/TransportFFITests/TransportFFITests.swift" "反证：同名文件在测试目录下 → none"
cls ui "apps/ios/TransportFFITests/Package.swift" "  iOS TransportFFITests/Package.swift 是 App 依赖的包清单，不算测试 → ui"
cls none "tools/x.sh docs/a.md" "工具与文档 → none"
cls ui "docs/a.md apps/desktop/src/foo.ts" "多文件里只要一个碰界面 → ui"
# 判不了级别 → check 不放行（fail-closed）：classify 换成输出未知值的桩
cp "$G" "${TMP}/gate.bak"
sed 's/KIND="$(classify <"$FILES_F")"/KIND=weird/' "${TMP}/gate.bak" >"$G"
printf '%s\n' "$UI" >"${TMP}/files"; printf 'closes #1\n' >"${TMP}/body"
bash "$G" check --repo "${TMP}/repo" --files "${TMP}/files" --body "${TMP}/body" >/dev/null 2>&1 && bad "判不了级别却放行了" || ok "判不了级别 → 红（不放行）"
cp "${TMP}/gate.bak" "$G"
# 界面清单读不到 → 宁严勿松
rm "${TMP}/repo/tools/flow/owner-triage.sh"
printf '%s\n' docs/a.md | bash "$G" classify --repo "${TMP}/repo" | grep -qx ui && ok "界面清单读不到 → 按用户看得见处理（进验收范围）" || bad "清单缺失时放行了"
# 用法错误
bash "$G" check >/dev/null 2>&1; [ $? = 2 ] && ok "缺参数 → 退出码 2" || bad "缺参数退出码不对"

echo
echo "通过 ${PASS}，失败 ${FAIL}"
[ "$FAIL" -eq 0 ]
