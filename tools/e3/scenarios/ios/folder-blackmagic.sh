# 【E3-4a】ADR「验收标准 E3」第 4 条前半：Blackmagic 实拍摄素材经目录来源完成真实备份。
# 授权必须走真系统目录选择器（安全作用域书签只能由创建它的进程解析；App 本期无目录 UI——ADR 明确）：
# App 的 DEBUG 钩子（PPASS_BGTEST_FOLDER_PICK）在启动时弹选择器，UI 测试（PPassUITests/FolderPickerDrive）
# 像用户一样点「我的 iPhone → Blackmagic Cam → 打开」，授权回调内经真实 FolderRegistry.addFolder 登记。
# 之后全部走正式备份链：配对沙盒桌面 → 相册范围清空 → folder: 项全部备份 → 桌面逐个落地；
# 同一份素材同时经相册（seedRun 种入测试相册的拷贝）与目录出现 → 桌面只有一份（E3-4 后半同轮覆盖）。
# 手机侧只读：登记与取样都是读操作，不动用户素材（测试不删用户素材，ADR E3）。
# shellcheck source=ios-lib.bashlib
source "$(dirname "${BASH_SOURCE[0]}")/ios-lib.bashlib"
RUN="e3-$(date +%s)"
TARGET="${PPASS_E3_FOLDER_TARGET:-Blackmagic Cam}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ppass-e3-ios.XXXXXX")
DESK="$WORK/A"

DESC="Blackmagic 实拍摄素材经真系统目录选择器授权后由目录来源完成真实备份，同素材经相册只留一份"
COUNTER=off

setup() {
  ios_require_tools
  ios_resolve_device
  ios_ensure_installed "$EV"
  ios_reset "$EV"
  ios_desk_start "$DESK"
  ios_pair_allow_start "$EV" "$DESK"
  # UI 测试（点选择器）要先 build-for-testing
  local ios="$REPO_ROOT/apps/ios"
  [ -d "$ios/TransportFFITests/Generated/TransportFFI.xcframework" ] \
    || "$REPO_ROOT/tools/build-ios-transport-xcframework.sh" "$ios/TransportFFITests/Generated" >>"$EV/build.log" 2>&1
  (cd "$ios" && xcodegen generate --quiet) >>"$EV/build.log" 2>&1
  xcodebuild build-for-testing -project "$ios/PPass.xcodeproj" -scheme PPassUI -configuration Debug \
    -destination "id=$IOS_HW_UDID" -allowProvisioningUpdates \
    -derivedDataPath "$ios/build/derived-device" >>"$EV/build.log" 2>&1 \
    || { tail -20 "$EV/build.log" >&2; die "UI 测试构建失败（$EV/build.log）"; }
}

act() {
  # 1) 授权登记：启动 App（PPASS_BGTEST_FOLDER_PICK=1 弹选择器）→ UI 测试点「我的 iPhone → <target> → 打开」
  xcodebuild test-without-building -project "$REPO_ROOT/apps/ios/PPass.xcodeproj" -scheme PPassUI \
    -destination "id=$IOS_HW_UDID" -only-testing:PPassUITests/FolderPickerDrive/testPickFolder \
    -derivedDataPath "$REPO_ROOT/apps/ios/build/derived-device" \
    TEST_RUNNER_UIREG_RUN="$RUN" TEST_RUNNER_UIREG_TARGET="$TARGET" TEST_RUNNER_UIREG_STAGE=1 \
    >"$OUT/pick-test.log" 2>&1 || { tail -20 "$OUT/pick-test.log" >&2; return 1; }
  ios_copy_from Documents/e2e/status.json "$OUT/status-picked.json" || { echo "状态没拉到（选择器没点成？）" >&2; return 1; }
  jq -r '.step // ""' "$OUT/status-picked.json" | grep -q '^folder_picked$' \
    || { echo "App 侧登记没完成：$(jq -r '.error // .step' "$OUT/status-picked.json")" >&2; return 1; }
  # 大小护栏：沙盒桌面要接下整个源目录的拷贝；超过上限就停（磁盘红线），报告里写清楚数字
  local run="guard-$(date +%s)" total
  ios_launch "$OUT" list "{\"PPASS_E2E_DIR\":\"container\",\"PPASS_E2E_RUN\":\"$run\",\"PPASS_BGTEST_FOLDER_LIST\":\"1\"}"
  ios_wait_status "$OUT/list" "$run" 30 true >/dev/null && cp "$OUT/list.status.json" "$OUT/folder-list-guard.json"
  total=$(jget "$OUT/folder-list-guard.json" 'j["sources"][0]["total_bytes"]')
  [ "${total:-0}" -le $(( ${PPASS_E3_FOLDER_MAX_MB:-4000} * 1000000 )) ] \
    || { echo "源目录媒体共 $total 字节，超过沙盒桌面护栏 $(( ${PPASS_E3_FOLDER_MAX_MB:-4000} ))MB；请清设备素材或调 PPASS_E3_FOLDER_MAX_MB" >&2; return 1; }
  # 2) 相册侧：seedRun 把 pick 钩子取出的最小媒体文件拷贝种进测试相册（同一份素材的第二条来源）
  desk_qr "$DESK" # 一次性配对串：desk_qr 设 PAIR_QR，不回显
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
  ios_orders_dump "$OUT" orders.txt
  desk_ipc "$DESK" status >"$OUT/desk-status.json"
  find "$DESK/home" "$(cat "$DESK/sandbox")" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.mov' -o -iname '*.mp4' \) \
    ! -path '*/thumbs/*' ! -path '*/tmp/*' 2>/dev/null | sort >"$OUT/desktop-files.txt"
  # 同内容双来源的那份：pick 钩子拷进 seed 的最小媒体文件（目录素材的拷贝，字节相同）
  ios_copy_from Documents/e2e/seed/foldere3-dedup.mp4 "$OUT/dedup-copy.mp4" || \
    ios_copy_from Documents/e2e/seed/foldere3-dedup.jpg "$OUT/dedup-copy.jpg" || true
  local b3; b3="$(ios_b3)"
  local phone_hash=""
  for f in "$OUT/dedup-copy.mp4" "$OUT/dedup-copy.jpg"; do
    [ -s "$f" ] || continue
    phone_hash=$("$b3" "$f" | awk '{print $1}')
    break
  done
  [ -n "$phone_hash" ] && echo "$phone_hash" >"$OUT/phone-dedup.b3" || : >"$OUT/phone-dedup.b3"
  : >"$OUT/desktop.b3"
  while IFS= read -r f; do "$b3" "$f" >>"$OUT/desktop.b3"; done <"$OUT/desktop-files.txt"
  { echo "== phone-dedup =="; cat "$OUT/phone-dedup.b3"; echo "== desktop =="; cat "$OUT/desktop.b3"; } >"$OUT/hashes.txt"
}

judge() {
  local d="$1" items confirmed
  items=$(jget "$d/folder-list.json" 'j["sources"][0]["items"]')
  confirmed=$(jget "$d/status-run.json" 'j["confirmed"]')
  check "系统选择器授权成功（folder_picked，display=$TARGET 来源）" has_line "$d/status-picked.json" '"step" *: *"folder_picked"'
  check "登记清单：来源 registered 且映射项数=$items (Blackmagic 目录里的媒体文件数）" bash -c "[ \"\$items\" -ge 1 ]"
  check "正式备份链收场 confirmed=$confirmed (相册 1 + 目录 $items)" bash -c "[ \"\$confirmed\" -ge 2 ]"
  check "目录来源媒体全部确认（folder: 订单 CONFIRMED 数 = $items)" bash -c "[ \"\$(sqlite3 -readonly \"$d/db/backup-orders.db\" \"SELECT COUNT(*) FROM orders WHERE media_id LIKE 'folder:%' AND state='CONFIRMED'\")\" = \"$items\" ]"
  check "同素材双来源桌面只一份（该内容哈希在桌面库出现次数 = 1）" bash -c "h=\$(awk 'NR==1{print \$1}' \"$d/phone-dedup.b3\"); [ \"\$(grep -c \"^\$h\" \"$d/desktop.b3\")\" = 1 ]"
  check "同素材 BLAKE3：手机拷贝 = 桌面落地文件" bash -c "h=\$(awk 'NR==1{print \$1}' \"$d/phone-dedup.b3\"); grep -q \"^\$h\" \"$d/desktop.b3\""
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
