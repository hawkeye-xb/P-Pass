# 【E3-4a】ADR「验收标准 E3」第 4 条前半：Blackmagic 实拍摄素材经目录来源完成真实备份。
# 授权必须走真系统目录选择器（安全作用域书签只能由创建它的进程解析；App 本期无目录 UI——ADR 明确）：
# App 的 DEBUG 钩子（PPASS_BGTEST_FOLDER_PICK）在启动时弹选择器，UI 测试（PPassUITests/FolderPickerDrive）
# 像用户一样点「我的 iPhone → Blackmagic Cam → Media → 打开」，授权回调内经真实 FolderRegistry.addFolder 登记。
# 之后全部走正式备份链：配对沙盒桌面 → 相册范围清空 → folder: 项全部备份 → 桌面逐个落地；
# 同一份素材同时经相册（seedRun 种入测试相册的拷贝）与目录出现 → 桌面只有一份（E3-4 后半同轮覆盖）。
# 手机侧只读：登记与取样都是读操作，不动用户素材（测试不删用户素材，ADR E3）。
# shellcheck source=ios-lib.bashlib
source "$(dirname "${BASH_SOURCE[0]}")/ios-lib.bashlib"
RUN="e3-$(date +%s)"
TARGET="${PPASS_E3_FOLDER_TARGET:-Blackmagic Cam/Media}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ppass-e3-ios.XXXXXX")
DESK="$WORK/A"

DESC="Blackmagic 实拍摄素材经真系统目录选择器授权后由目录来源完成真实备份，同素材经相册只留一份"
COUNTER=off

setup() {
  ios_require_tools
  ios_resolve_device
  # 两种模式都构建安装当前代码的 App 并记录 commit/installed：人工/外部驱动模式不许拿设备上的旧包当当前包
  # （跳过构建只能走既有 PPASS_SKIP_BUILD=1 口径，由操作者自证已是当前 Debug 包）。
  ios_ensure_installed "$EV"
  ios_reset "$EV"
  ios_desk_start "$DESK"
  ios_pair_allow_start "$EV" "$DESK"
  # UI 测试（点选择器）要先 build-for-testing；人工/外部驱动分支直接点真选择器，用不上 UI 测试，跳过
  if [ "${PPASS_E3_PICK_MANUAL:-0}" != 1 ]; then
    local ios="$REPO_ROOT/apps/ios"
    [ -d "$ios/TransportFFITests/Generated/TransportFFI.xcframework" ] \
      || "$REPO_ROOT/tools/build-ios-transport-xcframework.sh" "$ios/TransportFFITests/Generated" >>"$EV/build.log" 2>&1
    (cd "$ios" && xcodegen generate --quiet) >>"$EV/build.log" 2>&1
    xcodebuild build-for-testing -project "$ios/PPass.xcodeproj" -scheme PPassUI -configuration Debug \
      -destination "id=$IOS_HW_UDID" -allowProvisioningUpdates \
      -derivedDataPath "$ios/build/derived-device" >>"$EV/build.log" 2>&1 \
      || { tail -20 "$EV/build.log" >&2; die "UI 测试构建失败（$EV/build.log）"; }
  fi
}

act() {
  # 1) 授权登记：启动 App（PPASS_BGTEST_FOLDER_PICK=1 弹选择器）→ 默认走 UI 测试点「我的 iPhone →
  #    <target> → 打开」（默认 Blackmagic Cam/Media）。XCUITest 点不进真选择器时，设 PPASS_E3_PICK_MANUAL=1
  #    走人工/外部驱动分支：直接 devicectl 弹真选择器，等 folder_picked 后接续原步骤 2–4 与原 judge
  #    （分支合拢后两种模式共用 status-picked.json）。
  if [ "${PPASS_E3_PICK_MANUAL:-0}" = 1 ]; then
    # 启动参数与 FolderPickerDrive 写进 App 的逐项一致（DIR/RUN + PICK + STAGE，同一个 RUN）。
    ios_launch "$OUT" pick "{\"PPASS_E2E_DIR\":\"container\",\"PPASS_E2E_RUN\":\"$RUN\",\"PPASS_BGTEST_FOLDER_PICK\":\"1\",\"PPASS_BGTEST_FOLDER_STAGE\":\"1\"}" \
      || { echo "pick 启动失败" >&2; return 1; }
    ios_wait_status "$OUT/pick" "$RUN" 900 true >/dev/null \
      || { echo "等 folder_picked 超时或失败（真选择器点完了吗）：$(jq -r '.error // .step // ""' "$OUT/pick.status.json" 2>/dev/null)" >&2; return 1; }
    cp "$OUT/pick.status.json" "$OUT/status-picked.json" || return 1
  else
    # TEST_RUNNER_* 必须作为 xcodebuild 的**环境变量**传入（去掉前缀后进测试进程）；写成命令末尾的参数
    # 只是 build setting，不会进测试进程（真机实测：UIREG_HOME_WAIT 没传进去，按 Home 提前到 12s）。
    # 真机上 test-without-building 启动被测 App 常报「process identifier could not be determined」，
    # 同一份 xctestrun 换 test 就能起来（tools/ios/ui-regress.sh 2026-11-11 实测）：这里用 test。
    TEST_RUNNER_UIREG_RUN="$RUN" TEST_RUNNER_UIREG_TARGET="$TARGET" TEST_RUNNER_UIREG_STAGE=1 \
      xcodebuild test -project "$REPO_ROOT/apps/ios/PPass.xcodeproj" -scheme PPassUI -configuration Debug \
      -destination "id=$IOS_HW_UDID" -only-testing:PPassUITests/FolderPickerDrive/testPickFolder \
      -derivedDataPath "$REPO_ROOT/apps/ios/build/derived-device" \
      >"$OUT/pick-test.log" 2>&1 || { tail -20 "$OUT/pick-test.log" >&2; return 1; }
    ios_copy_from Documents/e2e/status.json "$OUT/status-picked.json" || { echo "状态没拉到（选择器没点成？）" >&2; return 1; }
  fi
  jq -r '.step // ""' "$OUT/status-picked.json" | grep -q '^folder_picked$' \
    || { echo "App 侧登记没完成：$(jq -r '.error // .step' "$OUT/status-picked.json")" >&2; return 1; }
  # 同内容双来源的那份：pick 钩子暂存进 Documents/e2e/seed/ 的最小媒体拷贝（目录素材的字节相同拷贝）。
  # seedRun 只清它导入的素材，这份文件保留到下面拉回做 BLAKE3。
  local staged_name
  staged_name=$(jq -r '.staged.name // ""' "$OUT/status-picked.json")
  [ -n "$staged_name" ] \
    || { echo "pick 钩子没有暂存同内容素材（所选目录里没有可导入媒体），同内容去重没法验" >&2; return 1; }
  # 大小护栏：沙盒桌面要接下整个源目录的拷贝；超过上限就停（磁盘红线），报告里写清楚数字。
  # 取不到大小必须停：jget 对缺失文件输出空串，按 0 处理等于把「未知大小」放进护栏。
  local run="guard-$(date +%s)" total
  ios_launch "$OUT" list "{\"PPASS_E2E_DIR\":\"container\",\"PPASS_E2E_RUN\":\"$run\",\"PPASS_BGTEST_FOLDER_LIST\":\"1\"}" \
    || { echo "源目录清单启动失败，无法估算占盘" >&2; return 1; }
  ios_wait_status "$OUT/list" "$run" 30 true >/dev/null \
    || { echo "源目录清单轮询失败，无法估算占盘" >&2; return 1; }
  cp "$OUT/list.status.json" "$OUT/folder-list-guard.json" \
    || { echo "源目录清单拷贝失败，无法估算占盘" >&2; return 1; }
  total=$(jget "$OUT/folder-list-guard.json" 'j["sources"][0]["total_bytes"]')
  [[ "$total" =~ ^[0-9]+$ ]] || { echo "源目录大小读不到或不是非负整数：'$total'，拒绝继续备份" >&2; return 1; }
  [ "$total" -le $(( ${PPASS_E3_FOLDER_MAX_MB:-4000} * 1000000 )) ] \
    || { echo "源目录媒体共 $total 字节，超过沙盒桌面护栏 $(( ${PPASS_E3_FOLDER_MAX_MB:-4000} ))MB；请清设备素材或调 PPASS_E3_FOLDER_MAX_MB" >&2; return 1; }
  # 2) 相册侧：seedRun 把暂存的同内容素材种进测试相册（同一份素材的第二条来源）。
  #    先推 go 信号：seedRun 有界等 Documents/e2e/seed/go，不推它种子步骤只会等到超时。
  desk_qr "$DESK" # 一次性配对串：desk_qr 设 PAIR_QR，不回显
  printf 'go\n' >"$WORK/go" && ios_push "$WORK/go" "Documents/e2e/seed/go" \
    || { echo "推 go 信号失败" >&2; return 1; }
  ios_launch "$OUT" seed "$(jq -cn --arg l "$PAIR_QR" --arg r "$RUN-seed" \
    '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_E2E_PAIR_LINK:$l,PPASS_BGTEST:"1"}')" || return 1
  ios_wait_status "$OUT/seed" "$RUN-seed" 180 true >/dev/null || { ios_copy_from Documents/e2e/status.json "$OUT/seed.status.json"; return 1; }
  ios_copy_from Documents/e2e/status.json "$OUT/status-seeded.json"
  jq -r '.step // ""' "$OUT/status-seeded.json" | grep -q '^seeded$' \
    || { echo "种子没写进相册：$(jq -r '.error // .step' "$OUT/status-seeded.json")" >&2; return 1; }
  # 3) 正式备份链收场：目录来源全部媒体项 + 相册 1 项
  ios_launch "$OUT" run "$(jq -cn --arg r "$RUN-run" '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_BGTEST_FOLDER_RUN:"1"}')" || return 1
  ios_wait_status "$OUT/run" "$RUN-run" 3600 true >/dev/null || { ios_copy_from Documents/e2e/status.json "$OUT/run.status.json"; return 1; }
  cp "$OUT/run.status.json" "$OUT/status-run.json"
  # 4) 证据
  ios_collect_common "$OUT"
  # 日志只留本轮段（ios-lib 说明）：真选择器登记出的 source_id 唯一，切段找不到 = 证据不全。
  ios_trim_log_to_run "$OUT/ppass.log" "$(jget "$OUT/status-picked.json" 'j["source_id"]')" || return 1
  ios_orders_dump "$OUT" orders.txt
  desk_ipc "$DESK" status >"$OUT/desk-status.json"
  ios_desktop_files "$OUT" desktop-files.txt -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \
    -o -iname '*.heic' -o -iname '*.mov' -o -iname '*.mp4' -o -iname '*.m4v'
  # 同内容双来源的那份：按 pick 状态里的暂存名拉回（seedRun 只清已导入素材，这份还在 seed 里）
  ios_copy_from "Documents/e2e/seed/$staged_name" "$OUT/dedup-copy" \
    || { echo "拉回暂存素材失败：Documents/e2e/seed/$staged_name" >&2; return 1; }
  local b3; b3="$(ios_b3)"
  "$b3" "$OUT/dedup-copy" | awk '{print $1}' >"$OUT/phone-dedup.b3"
  : >"$OUT/desktop.b3"
  while IFS= read -r f; do "$b3" "$f" >>"$OUT/desktop.b3"; done <"$OUT/desktop-files.txt"
  { echo "== phone-dedup =="; cat "$OUT/phone-dedup.b3"; echo "== desktop =="; cat "$OUT/desktop.b3"; } >"$OUT/hashes.txt"
}

judge() {
  local d="$1" items confirmed
  # 数值在 judge 顶层算好再拼进 bash -c 的字面量（子壳拿不到外层变量，原样传下去只会拿空串比较）。
  items=$(jget "$d/folder-list.json" 'j["sources"][0]["items"]')
  confirmed=$(jget "$d/status-run.json" 'j["confirmed"]')
  check "系统选择器授权成功（folder_picked，display=$TARGET 来源）" has_line "$d/status-picked.json" '"step" *: *"folder_picked"'
  check "登记清单：来源 registered 且映射项数=${items:-缺失}（Blackmagic 目录里的媒体文件数）" bash -c "[ '${items:-x}' -ge 1 ]"
  # folderRun 的 confirmed 只数 folder: 订单，不含相册订单：目录里只有一个视频时它就是 1，
  # 拿它跟「相册+目录」的总数比会误判。目录侧与相册侧分开判。
  check "正式备份链收场：目录订单 confirmed=${confirmed:-缺失} = 目录映射项数 ${items:-缺失}" \
    bash -c "[ -n '${confirmed:-}' ] && [ '${confirmed:-x}' = '${items:-y}' ]"
  check "相册侧同内容素材也已确认（非 folder: 订单有 CONFIRMED）" \
    bash -c "[ \"\$(sqlite3 -readonly \"$d/db/backup-orders.db\" \"SELECT COUNT(*) FROM orders WHERE media_id NOT LIKE 'folder:%' AND state='CONFIRMED'\")\" -ge 1 ]"
  check "目录来源媒体全部确认（folder: 订单 CONFIRMED 数 = ${items:-缺失}）" \
    bash -c "[ \"\$(sqlite3 -readonly \"$d/db/backup-orders.db\" \"SELECT COUNT(*) FROM orders WHERE media_id LIKE 'folder:%' AND state='CONFIRMED'\")\" = '${items:-x}' ]"
  check "手机源暂存素材哈希齐备（1 条 64 位 hex；拷贝/哈希失败留空在这里判红，不许拿空哈希撞桌面清单）" \
    b3_list_ok "$d/phone-dedup.b3" 1
  check "桌面哈希清单齐备（≥1 条）" b3_list_ok "$d/desktop.b3" 1
  check "同素材双来源桌面只一份（该内容哈希在桌面库出现次数 = 1，按完整哈希字段数）" \
    bash -c "h=\$(awk 'NR==1{print \$1}' \"$d/phone-dedup.b3\"); [ \"\$(awk -v h=\"\$h\" '\$1==h' \"$d/desktop.b3\" | wc -l | tr -d ' ')\" = 1 ]"
  check "同素材 BLAKE3：手机拷贝 = 桌面落地文件（按完整哈希字段比较）" \
    bash -c "h=\$(awk 'NR==1{print \$1}' \"$d/phone-dedup.b3\"); awk -v h=\"\$h\" '\$1==h{f=1} END{exit f?0:1}' \"$d/desktop.b3\""
  check "实拍素材按引用导入（≥1MB 的项日志 ref=yes）" has_line "$d/ppass.log" 'folder .*: imported bytes=[0-9]{7,} hash=.* ref=yes'
  check "桌面沙盒日志无 panic" no_line "$d/daemon.err" 'panicked|PANIC'
  verdict
}

teardown() {
  # 相册里的测试资源与测试相册：系统会弹确认框，这步留给人在场时用 tools/ios/delete-test-assets.sh；
  # 目录登记记录与测试目录（foldere3-*）这里清（Blackmagic 素材不动）；收掉沙盒桌面
  ios_pair_allow_stop
  ios_launch "$EV" cleanup "$(jq -cn --arg s '{}' --arg r "$RUN-cleanup" \
    '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_BGTEST_FOLDER_CLEANUP:$s}')" >/dev/null 2>&1 || true
  desk_stop "$DESK" 2>/dev/null || true
  rm -rf "$WORK" 2>/dev/null || true
}
