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
cp "${SRC}/tools/flow/acceptance-gate.sh" "${SRC}/tools/flow/decision-lib.sh" "${TMP}/repo/tools/flow/"
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
gate 0 "正例：引用已采纳方案 + test-*.py 测试 → 绿" "core/x.rs tools/test-x.py" $'closes #1\n方案：'"$ADR"
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
# UI_GLOBS 清空时 → 宁严勿松（按用户看得见处理）
cp "$G" "${TMP}/gate.uibak"
sed 's/^UI_GLOBS=.*/UI_GLOBS=""/' "${TMP}/gate.uibak" >"$G"
printf '%s\n' docs/a.md | bash "$G" classify --repo "${TMP}/repo" | grep -qx ui && ok "界面清单为空时 → 按用户看得见处理（进验收范围）" || bad "清单缺失时放行了"
cp "${TMP}/gate.uibak" "$G"
# 用法错误
bash "$G" check >/dev/null 2>&1; [ $? = 2 ] && ok "缺参数 → 退出码 2" || bad "缺参数退出码不对"

# 反假考卷门禁：彻底拒绝任何新增/留存的 exam_* 一次性考卷及多语言读取源码字符串假测试；物理删除存量 exam_*（HEAD 中已不存在）放行
mkdir -p "${TMP}/repo/crates/daemon/tests/v3" "${TMP}/repo/tests" \
  "${TMP}/repo/apps/android/app/src/test/java/com/hawkeyexb/ppass" \
  "${TMP}/repo/apps/ios/PPassTests" "${TMP}/repo/apps/desktop/src"
printf 'x = 1\n' >"${TMP}/repo/crates/daemon/tests/v3/exam_1927.py"
printf 'echo 1\n' >"${TMP}/repo/exam_foo.sh"
EXT_RS=rs
EXT_KT=kt
EXT_SWIFT=swift
EXT_SVELTE=svelte
printf 's = (ROOT / "crates/platform/src/lib.%s").read_text()\nassert "fn foo" in s\n' "$EXT_RS" >"${TMP}/repo/tests/fake_check.py"
printf 'val s = File("src/main/java/MainActivity.%s").readText()\n' "$EXT_KT" >"${TMP}/repo/apps/android/app/src/test/java/com/hawkeyexb/ppass/FakeKtTest.kt"
printf 'String s = Files.readString(Paths.get(dir, "Main.%s"));\n' "$EXT_KT" >"${TMP}/repo/apps/android/app/src/test/java/com/hawkeyexb/ppass/FakeJavaTest.java"
printf 'let s = try String(contentsOf: root.appendingPathComponent("Home.%s"), encoding: .utf8)\n' "$EXT_SWIFT" >"${TMP}/repo/apps/ios/PPassTests/FakeSwiftTests.swift"
printf 'const s = readFileSync(new URL("./App.%s", import.meta.url), "utf8");\n' "$EXT_SVELTE" >"${TMP}/repo/apps/desktop/src/fakeJs.test.js"
printf 'const s = await fs.promises.readFile("src/App.%s", "utf8");\n' "$EXT_SVELTE" >"${TMP}/repo/apps/desktop/src/fakeTs.test.ts"
printf 'let s = include_str!("../src/lib.%s");\n' "$EXT_RS" >"${TMP}/repo/crates/daemon/tests/fake_rust.rs"
gate 1 "反假考卷：PR 含新增/留存的 exam_1927.py 一次性考卷 → acceptance gate 判红拒绝" "crates/daemon/tests/v3/exam_1927.py" "closes #1"
gate 1 "反假考卷：PR 含顶层 exam_foo.sh 考卷 → acceptance gate 判红拒绝" "exam_foo.sh" "closes #1"
gate 1 "反假考卷：PR 含读取业务源码字符串充当断言的 tests/fake_check.py → acceptance gate 判红拒绝" "tests/fake_check.py" "closes #1"
gate 1 "反假考卷：Kotlin 测试读取 .kt 源码 → acceptance gate 判红拒绝" "apps/android/app/src/test/java/com/hawkeyexb/ppass/FakeKtTest.kt" "closes #1"
gate 1 "反假考卷：Java 测试读取 .kt 源码 → acceptance gate 判红拒绝" "apps/android/app/src/test/java/com/hawkeyexb/ppass/FakeJavaTest.java" "closes #1"
gate 1 "反假考卷：Swift 测试读取 .swift 源码 → acceptance gate 判红拒绝" "apps/ios/PPassTests/FakeSwiftTests.swift" "closes #1"
gate 1 "反假考卷：JS 测试读取 .svelte 源码 → acceptance gate 判红拒绝" "apps/desktop/src/fakeJs.test.js" "closes #1"
gate 1 "反假考卷：TS 测试读取 .svelte 源码 → acceptance gate 判红拒绝" "apps/desktop/src/fakeTs.test.ts" "closes #1"
gate 1 "反假考卷：Rust 测试 include_str! 业务源码 → acceptance gate 判红拒绝" "crates/daemon/tests/fake_rust.rs" "closes #1"

# 反证（门禁有效性）：若撤回多语言扩展恢复 and f.endswith(".py")，上述多语言假测试将漏放变绿
cp "$G" "${TMP}/gate.pyonly"
sed 's/elif test_re.search(f) and target.is_file():/elif test_re.search(f) and f.endswith(".py") and target.is_file():/' "${TMP}/gate.pyonly" >"$G"
gate 0 "反证：撤销多语言扩展恢复仅限 .py 时，Kotlin 假测试漏放变绿（证明扩展真实生效）" "apps/android/app/src/test/java/com/hawkeyexb/ppass/FakeKtTest.kt" "closes #1"
cp "${TMP}/gate.pyonly" "$G"

rm -f "${TMP}/repo/crates/daemon/tests/v3/exam_1927.py" "${TMP}/repo/exam_foo.sh" "${TMP}/repo/tests/fake_check.py" \
  "${TMP}/repo/apps/android/app/src/test/java/com/hawkeyexb/ppass/FakeKtTest.kt" \
  "${TMP}/repo/apps/android/app/src/test/java/com/hawkeyexb/ppass/FakeJavaTest.java" \
  "${TMP}/repo/apps/ios/PPassTests/FakeSwiftTests.swift" \
  "${TMP}/repo/apps/desktop/src/fakeJs.test.js" \
  "${TMP}/repo/apps/desktop/src/fakeTs.test.ts" \
  "${TMP}/repo/crates/daemon/tests/fake_rust.rs"

# 正例：合法资源读取、跨端常量同步（flow_health.rs）、非 UTF-8 字节容错、基线存量修改零误报
printf 'val xml = File("src/main/res/values/strings.xml").readText()\n' >"${TMP}/repo/apps/android/app/src/test/java/com/hawkeyexb/ppass/RealStringsTest.kt"
printf 'const cfg = readFileSync("assets/i18n/en.json", "utf8");\n' >"${TMP}/repo/apps/desktop/src/realJson.test.ts"
printf 'from pathlib import Path\nDATA = Path("assets/i18n/en.json").read_text()\n' >"${TMP}/repo/tools/test-real.py"
printf 'from pathlib import Path\nSRC = Path("crates/platform/src/lib.%s").read_text()\n' "$EXT_RS" >"${TMP}/repo/tools/test-fake.py"
printf 'let s1 = std::fs::read_to_string(root.join("apps/android/FlowContract.%s")).unwrap();\nlet s2 = std::fs::read_to_string(root.join("apps/ios/FlowTypes.%s")).unwrap();\n' "$EXT_KT" "$EXT_SWIFT" >"${TMP}/repo/crates/daemon/tests/flow_health.rs"
python3 -B -I -c 'import pathlib; pathlib.Path(r"'"${TMP}"'/repo/apps/ios/PPassTests/BinaryCommentTests.swift").write_bytes(b"// \xff\xfe non-utf8\nlet x = 1\n")'
gate 0 "反证：物理 git rm 删除旧 exam_1927.py（工作区已不存在）→ 合法放行" "crates/daemon/tests/v3/exam_1927.py" "closes #1"
gate 0 "反证：正式测试目录 crates/daemon/tests/reparse_test.rs → 绿" "crates/daemon/tests/reparse_test.rs" "closes #1"
gate 0 "正例：Kotlin 读取 strings.xml 与 TS 读取 en.json → 合法放行" "apps/android/app/src/test/java/com/hawkeyexb/ppass/RealStringsTest.kt apps/desktop/src/realJson.test.ts" "closes #1"
gate 0 "正例：tools/test-real.py 读取 JSON 资源 → 合法放行" "tools/test-real.py" "closes #1"
gate 1 "反假考卷：tools/test-fake.py 偷读业务源码 → 判红拦截" "tools/test-fake.py" "closes #1"
cp "$G" "${TMP}/gate.oldtestre"
sed 's/|((^|\/)test-\[\^\/\]\*\\\.(sh|py)\$)//' "${TMP}/gate.oldtestre" >"$G"
gate 0 "反证：去掉 test-*.py TEST_RE 后，tools/test-fake.py 假测试漏放变绿" "tools/test-fake.py" "closes #1"
gate 1 "反证：去掉 test-*.py TEST_RE 后，core/x.rs + tools/test-x.py 被当成无测试红掉" "core/x.rs tools/test-x.py" $'closes #1\n方案：'"$ADR"
cp "${TMP}/gate.oldtestre" "$G"
rm -f "${TMP}/repo/tools/test-real.py" "${TMP}/repo/tools/test-fake.py"
gate 0 "正例：crates/daemon/tests/flow_health.rs 跨端常量同步读取 FlowContract/FlowTypes → 合法放行" "crates/daemon/tests/flow_health.rs" "closes #1"
gate 0 "正例：含非 UTF-8 字节的合法测试不崩溃 → 绿" "apps/ios/PPassTests/BinaryCommentTests.swift" "closes #1"

# 反证：flow_health.rs 若读取非白名单 UI 文件仍判红拦截
printf 'let s = include_str!("../../../apps/desktop/src/App.%s");\n' "$EXT_SVELTE" >"${TMP}/repo/crates/daemon/tests/flow_health.rs"
gate 1 "反证：flow_health.rs 偷读非白名单 UI 源码 → 判红拦截" "crates/daemon/tests/flow_health.rs" "closes #1"
rm -f "${TMP}/repo/crates/daemon/tests/flow_health.rs"

# 基线存量文件棘轮：存量已有 readText 的测试只补真实断言放行，新增 readText 拦截
printf 'val old = File("Old.%s").readText()\n' "$EXT_KT" >"${TMP}/repo/apps/android/app/src/test/java/com/hawkeyexb/ppass/LegacyTest.kt"
(
  cd "${TMP}/repo" || exit 1
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  git add apps/android/app/src/test/java/com/hawkeyexb/ppass/LegacyTest.kt &&
    git -c user.name=t -c user.email=t@example.invalid commit -q -m legacy &&
    git update-ref refs/remotes/origin/main HEAD
) || bad "（准备）写入存量测试失败"
printf 'val old = File("Old.%s").readText()\nassertEquals(2, 1 + 1)\n' "$EXT_KT" >"${TMP}/repo/apps/android/app/src/test/java/com/hawkeyexb/ppass/LegacyTest.kt"
gate 0 "正例：修改存量测试仅补真实行为断言（未新增源码读取）→ 合法放行" "apps/android/app/src/test/java/com/hawkeyexb/ppass/LegacyTest.kt" "closes #1"
printf 'val old = File("Old.%s").readText()\nval added = File("Added.%s").readText()\n' "$EXT_KT" "$EXT_KT" >"${TMP}/repo/apps/android/app/src/test/java/com/hawkeyexb/ppass/LegacyTest.kt"
gate 1 "反证：修改存量测试同时新增源码读取 → 判红拦截" "apps/android/app/src/test/java/com/hawkeyexb/ppass/LegacyTest.kt" "closes #1"

echo
echo "通过 ${PASS}，失败 ${FAIL}"
[ "$FAIL" -eq 0 ]
