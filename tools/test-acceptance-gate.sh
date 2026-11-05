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
  git init -q && git add -A && git -c user.name=t -c user.email=t@example.invalid commit -q -m init &&
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

gate 1 "碰界面、正文没有验收行 → 红" "$UI" $'closes #1\n- 真机验收：待产品负责人真机验收'
gate 0 "反证：补上验收行 → 绿" "$UI" $'closes #1\n'"$LINE"
gate 0 "  验收行带列表符与加粗也认" "$UI" $'closes #1\n- **'"$LINE"'**'
gate 1 "「未真机验收通过」→ 红" "$UI" $'closes #1\n产品负责人 2026-11-05 15:30 未真机验收通过'
gate 1 "  验收行嵌在别的句子中间 → 红" "$UI" $'closes #1\n备注：'"$LINE"
gate 1 "  日期不是具体日期 → 红" "$UI" $'closes #1\n产品负责人 <时间> 真机验收通过'
ADR=docs/decisions/2026-11-01-adopted.md
# 看不见的核心（#1448）：不要验收行，要已采纳方案 + 测试
gate 1 "核心、看不见：没有方案引用、没有测试 → 红" "core/x.rs" "closes #1"
gate 1 "  只有验收行也不行（看不见的核心要的是方案与测试）" "core/x.rs" $'closes #1\n'"$LINE"
gate 1 "  引用已采纳方案但没带测试 → 红" "core/x.rs" $'closes #1\n方案：'"$ADR"
gate 1 "  带测试但没引用方案 → 红" "core/x.rs tools/test-x.sh" "closes #1"
gate 0 "反证：引用已采纳方案 + 带测试 → 绿（不要验收行）" "core/x.rs tools/test-x.sh" $'closes #1\n方案：'"$ADR"
gate 1 "  引用的是草稿方案 → 红" "core/x.rs tools/test-x.sh" $'closes #1\n方案：docs/decisions/2026-11-02-draft.md'
# PR 自己带进来、写着「已采纳」但还没进 origin/main 的方案：工作区里有这份文件，只读 origin/main 才判得红
printf '# 方案\n\n- 状态：已采纳\n' >"${TMP}/repo/docs/decisions/2026-11-03-new.md"
gate 1 "  引用的方案只在工作区（PR 自己加的，写着已采纳）、不在 origin/main 上 → 红" "core/x.rs tools/test-x.sh" $'closes #1\n方案：docs/decisions/2026-11-03-new.md'
(
  cd "${TMP}/repo" || exit 1
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  git add docs/decisions/2026-11-03-new.md && git -c user.name=t -c user.email=t@example.invalid commit -q -m adopt &&
    git update-ref refs/remotes/origin/main HEAD
) || bad "（准备）把方案合进 origin/main 失败"
gate 0 "  反证：同一份方案合进 origin/main 后 → 绿" "core/x.rs tools/test-x.sh" $'closes #1\n方案：docs/decisions/2026-11-03-new.md'
# 看得见的核心：仍要验收记录
CV=apps/android/core/Pair.kt
gate 1 "核心、看得见：没有验收行 → 红" "$CV" $'closes #1\n方案：'"$ADR"
gate 0 "反证：核心看得见补验收行 → 绿" "$CV" $'closes #1\n'"$LINE"
gate 1 "  看不见的核心夹带界面文件 → 按看得见判，缺验收行 → 红" "core/x.rs tools/test-x.sh $UI" $'closes #1\n方案：'"$ADR"
gate 0 "纯文档（自动级）→ 绿" "docs/a.md" "closes #1"
gate 0 "反证口径：没有验收行但不碰界面，同样绿" "tools/x.sh docs/a.md" "closes #1"
gate 1 "多文件里只要一个碰界面 → 红" "docs/a.md $UI" "closes #1"
gate 1 "文案路径 assets/i18n 也算界面 → 红" "assets/i18n/zh.json" "closes #1"

# 非界面路径的 App 行为（安卓备份等）也要验收；测试文件除外
BK=apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/BackupWorker.kt
gate 1 "改 backup/BackupWorker.kt、没有验收行 → 红" "$BK" "closes #1"
gate 0 "反证：补验收行 → 绿" "$BK" $'closes #1\n'"$LINE"
gate 1 "apps/android/.../backup/flow/** 也红" "apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/flow/X.kt" "closes #1"
gate 0 "反证：只改 apps 下的测试文件 → 绿" "apps/android/app/src/test/java/com/hawkeyexb/ppass/backup/BackupWorkerTest.kt apps/desktop/x/a.test.ts" "closes #1"
gate 0 "反证：不碰 apps → 绿" "tools/x.sh" "closes #1"

gate 0 "反证：apps/desktop/src/ 下只改测试文件 → 绿" "apps/desktop/src/foo.test.ts apps/desktop/src/test/x.js" "closes #1"
gate 1 "  apps/desktop/src/ 下改非测试文件 → 红" "apps/desktop/src/foo.ts apps/desktop/src/foo.test.ts" "closes #1"

gate 1 "SpeedTest.svelte（名字以 Test 结尾的正式组件）单独改 → 红" "apps/desktop/src/SpeedTest.svelte" "closes #1"
gate 1 "  Kotlin 正式文件 PairingTest.kt 放在 main 下 → 红" "apps/android/app/src/main/java/com/hawkeyexb/ppass/PairingTest.kt" "closes #1"
gate 1 "  Swift 正式文件 SpeedTests.swift 在非测试目录 → 红" "apps/ios/PPass/Views/SpeedTests.swift" "closes #1"
gate 0 "反证：同名文件在测试目录下 → 绿" "apps/android/app/src/androidTest/java/com/hawkeyexb/ppass/NetProbeTest.kt apps/ios/PPassTests/XTests.swift apps/ios/Packages/PPassCore/Tests/PPassCoreTests/Flow/A.swift apps/desktop/src/a.spec.ts apps/desktop/src/__tests__/b.js apps/desktop/src-tauri/tests/c.rs apps/android/app/src/sharedTest/java/com/hawkeyexb/ppass/transport/PairingQrAddr.kt apps/ios/TransportFFITests/Tests/TransportFFITests/TransportFFITests.swift" "closes #1"

gate 1 "  iOS TransportFFITests/Package.swift 是 App 依赖的包清单，不算测试 → 红" "apps/ios/TransportFFITests/Package.swift" "closes #1"

# 更新说明（#1448）：只改 release/notes/**（可带 CHANGELOG.md）→ 文案确认行；混改界面仍要真机验收行
NOTE=release/notes/android/0.11.0.zh.txt
COPY='产品负责人 2026-11-05 15:30 文案确认通过'
gate 1 "只改更新说明、没有确认行 → 红" "$NOTE" "closes #1"
gate 0 "反证：补「文案确认通过」行 → 绿" "$NOTE" $'closes #1\n'"$COPY"
gate 0 "  更新说明 + CHANGELOG.md、有确认行 → 绿" "$NOTE CHANGELOG.md" $'closes #1\n- **'"$COPY"'**'
gate 0 "  已有真机验收行也算确认 → 绿" "$NOTE" $'closes #1\n'"$LINE"
gate 1 "  确认行嵌在句子中间 → 红" "$NOTE" $'closes #1\n备注：'"$COPY"
gate 1 "  确认行日期不是具体日期 → 红" "$NOTE" $'closes #1\n产品负责人 <时间> 文案确认通过'
gate 1 "更新说明 + 界面、只有文案确认行 → 红" "$NOTE $UI" $'closes #1\n'"$COPY"
gate 0 "反证：更新说明 + 界面补真机验收行 → 绿" "$NOTE $UI" $'closes #1\n'"$LINE"
gate 1 "界面改动只有文案确认行 → 红（文案确认顶不了真机验收）" "$UI" $'closes #1\n'"$COPY"
gate 0 "只改 CHANGELOG.md → 自动级，绿" "CHANGELOG.md" "closes #1"
# #1446 的真实文件清单（v0.11.0 三端更新说明）+ 带确认行的正文 → 绿
gate 0 "#1446 的文件清单 + 文案确认行 → 绿" "release/notes/android/0.11.0.en.txt release/notes/android/0.11.0.zh.txt release/notes/macos/0.11.0.en.txt release/notes/macos/0.11.0.zh.txt release/notes/windows/0.11.0.en.txt release/notes/windows/0.11.0.zh.txt" $'closes #1444\n'"$COPY"
gate 1 "  反证：同一清单没有确认行 → 红" "release/notes/android/0.11.0.en.txt release/notes/macos/0.11.0.zh.txt" "closes #1444"

# 按 SOP 验收的新格式（#1452），旧格式继续认
SOP='产品负责人 2026-11-05 15:30 按 SOP https://github.com/o/r/issues/9#issuecomment-1 操作，owner 判日志通过'
gate 0 "SOP 格式验收行 → 绿" "$UI" $'closes #1\n'"$SOP"
gate 0 "  SOP 行带列表符与加粗也认" "$UI" $'closes #1\n- **'"$SOP"'**'
gate 1 "  SOP 行缺「owner 判日志通过」→ 红" "$UI" $'closes #1\n产品负责人 2026-11-05 按 SOP https://x 操作'
gate 1 "  SOP 行嵌在句子中间 → 红" "$UI" $'closes #1\n备注：'"$SOP"
gate 1 "  SOP 行日期是占位 → 红" "$UI" $'closes #1\n产品负责人 <时间> 按 SOP <链接> 操作，owner 判日志通过'
gate 0 "  SOP 行对看得见的核心也算" "$CV" $'closes #1\n'"$SOP"
gate 0 "  SOP 行对更新说明也算" "$NOTE" $'closes #1\n'"$SOP"
# 整体模式「随模块验收 #N」（#1452）：只对用户可见的非核心改动有效
gate 0 "界面改动 + 随模块验收 #9 → 绿（可先合入）" "$UI" $'closes #1\n随模块验收 #9'
gate 0 "  更新说明 + 随模块验收 → 绿" "$NOTE" $'closes #1\n- 随模块验收 #9'
gate 1 "  「随模块验收」嵌在句子里 → 红" "$UI" $'closes #1\n这次随模块验收 #9 再看'
gate 1 "  「随模块验收」没写卡号 → 红" "$UI" $'closes #1\n随模块验收'
gate 1 "核心看得见 + 只有随模块验收 → 红" "$CV" $'closes #1\n随模块验收 #9'
gate 0 "反证：核心看得见 + 随模块验收 + 已采纳方案 → 绿" "$CV" $'closes #1\n随模块验收 #9\n方案：'"$ADR"
# record：发版前的模块验收检查用
rec() { printf '%s\n' "$2" >"${TMP}/rec"; bash "$G" record --body "${TMP}/rec" >/dev/null 2>&1; [ "$?" = "$1" ] && ok "record：$3" || bad "record：$3"; }
rec 0 "$SOP" "SOP 行 → 有记录"
rec 0 "$LINE" "旧格式真机行 → 有记录"
rec 1 "$COPY" "文案确认行默认不算（界面模块要真机 / SOP 记录）"
printf '%s\n' "$COPY" >"${TMP}/rec"
bash "$G" record --body "${TMP}/rec" --allow-copy >/dev/null 2>&1 && ok "record：反证：--allow-copy（来源全是更新说明）→ 文案确认行算记录" || bad "record --allow-copy 不认文案确认行"
rec 1 $'随模块验收 #9\n产品负责人 <时间> 真机验收通过' "反证：只有标记与占位行 → 没有记录"

# 只改版本号行（#1451）：tauri.conf.json 只改 version 行不算核心（仍在 apps/** 下，按界面级要验收或随模块验收）；
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
printf '%s\n' "$TC" >"${TMP}/files"; printf 'closes #1\n随模块验收 #9\n' >"${TMP}/body"
bash "$G" check --repo "${TMP}/repo" --files "${TMP}/files" --body "${TMP}/body" --diff "${TMP}/v.diff" >/dev/null 2>&1 &&
  ok "check：只改版本号 + 随模块验收 → 绿（不要已采纳方案）" || bad "只改版本号仍按核心要方案"
bash "$G" check --repo "${TMP}/repo" --files "${TMP}/files" --body "${TMP}/body" --diff "${TMP}/e.diff" >/dev/null 2>&1 &&
  bad "改了 endpoint 只靠随模块验收也过了" || ok "  反证：改了 endpoint + 只有随模块验收 → 红（核心要已采纳方案）"

# classify
printf '%s\n' "$UI" | bash "$G" classify --repo "${TMP}/repo" | grep -qx ui && ok "classify：界面 → ui" || bad "classify 界面"
printf '%s\n' core/x.rs | bash "$G" classify --repo "${TMP}/repo" | grep -qx core-hidden && ok "classify：看不见的核心 → core-hidden" || bad "classify 看不见的核心"
printf '%s\n' "$CV" | bash "$G" classify --repo "${TMP}/repo" | grep -qx core && ok "classify：看得见的核心 → core" || bad "classify 看得见的核心"
printf '%s\n' docs/a.md | bash "$G" classify --repo "${TMP}/repo" | grep -qx none && ok "classify：文档 → none" || bad "classify 文档"
printf '%s\n' "$NOTE" CHANGELOG.md | bash "$G" classify --repo "${TMP}/repo" | grep -qx notes && ok "classify：更新说明 → notes" || bad "classify 更新说明"
printf '%s\n' "$NOTE" "$UI" | bash "$G" classify --repo "${TMP}/repo" | grep -qx ui && ok "classify：更新说明 + 界面 → ui" || bad "classify 混改"
# 界面清单读不到 → 宁严勿松
rm "${TMP}/repo/tools/flow/owner-triage.sh"
printf '%s\n' docs/a.md | bash "$G" classify --repo "${TMP}/repo" | grep -qx ui && ok "界面清单读不到 → 按需要验收处理" || bad "清单缺失时放行了"
# 用法错误
bash "$G" check >/dev/null 2>&1; [ $? = 2 ] && ok "缺参数 → 退出码 2" || bad "缺参数退出码不对"

echo
echo "通过 ${PASS}，失败 ${FAIL}"
[ "$FAIL" -eq 0 ]
