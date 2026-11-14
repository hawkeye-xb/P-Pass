# 【E3-2】ADR「验收标准 E3」第 2 条：新增、移动、改名、删除和修改素材后，元数据对账能发现；不依赖门铃才能补齐。
# 每类操作**单独一轮**带 reconcile 的备份轮（trigger(.scopeAdded)，不是 foregroundMediaChange 门铃）：
# 引擎只有在轮与轮之间才能观察到中间状态——五类操作堆在一轮里，改名/移动/修改全都发生在首次扫描之前，
# 等于只验最后一轮的枚举，验不到对账语义。逐轮：
#   第 1 轮：登记 base.jpg → 收场（1 项确认）
#   第 2 轮：增（stage → nest/n2.jpg）→ 收场（新项发现并确认）
#   第 3 轮：改名（base.jpg → base-r.jpg）→ 收场（旧路径标源缺失、新路径换 opaqueId 确认、桌面不重复占盘）
#   第 4 轮：移动（base-r.jpg → sub/base-r.jpg）→ 收场（同上）
#   第 5 轮：修改（nest/n2.jpg 尾部翻一字节）→ 收场（同一媒体出第二个确认版本）
#   第 6 轮：删除（sub/base-r.jpg）→ 收场（CONFIRMED 且 source_missing=1，桌面副本不动）
# 判定全部按账本字段精确判（media_id / content_hash / source_missing 逐项相等），不做「有 CONFIRMED 就行」
# 或 `'CONFIRMED|1'`（grep -E 里是「CONFIRMED 或 1」）这类恒真匹配。哈希锚点来自拉回的源文件
#（tools/ios/b3sum，与产品 hash 独立核对）。
# 相册权限要求 full：引擎口径 source_missing 只在完整授权下写（FlowEngine.mediaAbsenceTrusted）——
# 授权不在就先在设备上授权一次（ios_reset 不清系统授权），判据里有硬门。
# 反证：判据依赖的「对账发现」本身在 E2 引擎与 FolderMediaSource 测试已带反证；真机侧注入的是真实文件操作，
# 无独立故障形态可加，COUNTER=off（理由：本场景的每个判据都是「状态对账后的事实」，不是故障判据）。
# shellcheck source=ios-lib.bashlib
source "$(dirname "${BASH_SOURCE[0]}")/ios-lib.bashlib"
RUN="e3-$(date +%s)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ppass-e3-ios.XXXXXX")
DESK="$WORK/A"
teardown() { ios_pair_allow_stop; desk_stop "$DESK" 2>/dev/null; rm -rf "$WORK"; }

DESC="本地目录逐轮增/改名/移/改/删由带对账的备份轮发现：新项确认、旧路径标源缺失、修改出新版本、删除桌面副本不动"
COUNTER=off

setup() {
  ios_require_tools
  ios_resolve_device
  ios_ensure_installed "$EV"
  ios_reset "$EV"
  ios_make_noise_jpg "$WORK/base.jpg" 7
  ios_make_noise_jpg "$WORK/n2.jpg" 44
  N2_SIZE=$(stat -f%z "$WORK/n2.jpg") # 修改用的翻转偏移按实际大小取尾部（避开头部/EXIF 结构）
  mkdir -p "$WORK/stage" && mv "$WORK/base.jpg" "$WORK/n2.jpg" "$WORK/stage/"
  ios_push_stage "$EV" "foldere3-stage-$RUN" "$WORK/stage"
  ios_desk_start "$DESK"
  ios_pair_allow_start "$EV" "$DESK"
}

# 一轮带 reconcile 的备份：触发 → 收场 → 拉账本快照（$1 轮号）
reconcile_round() {
  local n="$1"
  ios_launch "$OUT" "run$n" "$(jq -cn --arg r "$RUN-run$n" \
    '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_BGTEST_FOLDER_RUN:"1"}')" || return 1
  ios_wait_status "$OUT/run$n" "$RUN-run$n" 300 true >/dev/null \
    || { ios_copy_from Documents/e2e/status.json "$OUT/status-run$n.json"; return 1; }
  cp "$OUT/run$n.status.json" "$OUT/status-run$n.json"
  ios_orders_dump "$OUT" "orders-run$n.txt"
}

# 一类操作一次钩子启动（$1 名字 $2 ops JSON），收场判定看 results[0].ok
mutate_once() {
  local name="$1" ops="$2"
  local spec="{\"dir\":\"foldere3-$RUN\",\"ops\":$ops}"
  [ "$name" = add ] && spec="{\"dir\":\"foldere3-$RUN\",\"stage\":\"foldere3-stage-$RUN\",\"ops\":$ops}"
  ios_launch "$OUT" "mutate-$name" "$(jq -cn --arg s "$spec" --arg r "$RUN-mutate-$name" \
    '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_BGTEST_FOLDER_MUTATE:$s}')" || return 1
  ios_wait_status "$OUT/mutate-$name" "$RUN-mutate-$name" 60 true >/dev/null \
    || { ios_copy_from Documents/e2e/status.json "$OUT/status-mutate-$name.json"; return 1; }
  cp "$OUT/mutate-$name.status.json" "$OUT/status-mutate-$name.json"
}

act() {
  local b3
  # 1) 登记（目录里先只有 base.jpg；n2.jpg 留在 stage 给「增」用）→ 配对 → 第 1 轮收场
  local spec="{\"dir\":\"foldere3-$RUN\",\"stage\":\"foldere3-stage-$RUN\",\"manifest\":{\"base.jpg\":\"base.jpg\"},\"display\":\"PPass FolderE3 $RUN\"}"
  ios_launch "$OUT" add "$(jq -cn --arg s "$spec" --arg r "$RUN-add" \
    '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_BGTEST_FOLDER_ADD:$s}')" || return 1
  ios_wait_status "$OUT/add" "$RUN-add" 60 true >/dev/null || { ios_copy_from Documents/e2e/status.json "$OUT/add.status.json"; return 1; }
  cp "$OUT/add.status.json" "$OUT/status-add.json"
  desk_qr "$DESK" # 一次性配对串：desk_qr 设 PAIR_QR，不回显
  reconcile_round 1 || return 1
  # 锚点哈希：base.jpg 在改名前拉回（改名后按新路径就拉不到旧版本了）
  b3="$(ios_b3)"
  ios_copy_from "Documents/foldere3-$RUN/base.jpg" "$OUT/base.jpg" || return 1
  "$b3" "$OUT/base.jpg" >"$OUT/base.b3"
  # 2) 增 → 第 2 轮；拉 n2 改前字节
  mutate_once add '[{"op":"add","from":"n2.jpg","to":"nest/n2.jpg"}]' || return 1
  reconcile_round 2 || return 1
  ios_copy_from "Documents/foldere3-$RUN/nest/n2.jpg" "$OUT/n2-v1.jpg" || return 1
  "$b3" "$OUT/n2-v1.jpg" >"$OUT/n2-v1.b3"
  # 3) 改名 → 第 3 轮；移动 → 第 4 轮（每轮对账各记一次：旧路径缺席、新路径换 opaqueId）
  mutate_once rename '[{"op":"rename","from":"base.jpg","to":"base-r.jpg"}]' || return 1
  reconcile_round 3 || return 1
  mutate_once move '[{"op":"move","from":"base-r.jpg","to":"sub/base-r.jpg"}]' || return 1
  reconcile_round 4 || return 1
  # 4) 修改（尾部翻一字节，远超头部/EXIF）→ 第 5 轮；拉 n2 改后字节
  mutate_once modify "[{\"op\":\"modify\",\"to\":\"nest/n2.jpg\",\"offset\":$((N2_SIZE - 1000))}]" || return 1
  reconcile_round 5 || return 1
  ios_copy_from "Documents/foldere3-$RUN/nest/n2.jpg" "$OUT/n2-v2.jpg" || return 1
  "$b3" "$OUT/n2-v2.jpg" >"$OUT/n2-v2.b3"
  # 5) 删除 → 第 6 轮
  mutate_once delete '[{"op":"delete","to":"sub/base-r.jpg"}]' || return 1
  reconcile_round 6 || return 1
  # 6) 证据：账本全集、日志、登记清单、桌面库
  ios_collect_common "$OUT"
  desk_ipc "$DESK" status >"$OUT/desk-status.json"
  ios_desktop_files "$OUT" desktop-files.txt -iname '*.jpg' -o -iname '*.mp4'
  sqlite3 -readonly "$OUT/db/backup-orders.db" "SELECT COUNT(DISTINCT content_hash) FROM orders WHERE state='CONFIRMED'" >"$OUT/desktop-content-count.txt"
  cp "$OUT/folder-list.json" "$OUT/folder-list-after.json" 2>/dev/null || true
}

judge() {
  local d="$1" h_base h_n2v1 h_n2v2 photo_count items
  # 哈希锚点与计数值在 judge 顶层算好再拼进 bash -c 字面量（子壳拿不到外层变量）。
  h_base=$(awk 'NR==1{print $1}' "$d/base.b3" 2>/dev/null)
  h_n2v1=$(awk 'NR==1{print $1}' "$d/n2-v1.b3" 2>/dev/null)
  h_n2v2=$(awk 'NR==1{print $1}' "$d/n2-v2.b3" 2>/dev/null)
  photo_count=$(jget "$d/desk-status.json" 'j["result"]["photo_count"]')
  items=$(jget "$d/folder-list-after.json" 'j["sources"][0]["items"]')
  local db="$d/db/backup-orders.db"
  local dead_base ids_base versions_media versions_rows live_n2 desk_n desk_contents
  dead_base=$(sqlite3 -readonly "$db" "SELECT COUNT(*) FROM orders WHERE state='CONFIRMED' AND source_missing=1 AND content_hash='$h_base'")
  ids_base=$(sqlite3 -readonly "$db" "SELECT COUNT(DISTINCT media_id) FROM orders WHERE content_hash='$h_base'")
  versions_media=$(sqlite3 -readonly "$db" "SELECT COUNT(DISTINCT media_id) FROM orders WHERE content_hash IN ('$h_n2v1','$h_n2v2')")
  versions_rows=$(sqlite3 -readonly "$db" "SELECT COUNT(*) FROM orders WHERE state='CONFIRMED' AND content_hash IN ('$h_n2v1','$h_n2v2')")
  live_n2=$(sqlite3 -readonly "$db" "SELECT COUNT(*) FROM orders WHERE state='CONFIRMED' AND source_missing=0 AND content_hash IN ('$h_n2v1','$h_n2v2')")
  desk_n=$(wc -l <"$d/desktop-files.txt" | tr -d ' ')
  desk_contents=$(tr -d '[:space:]' <"$d/desktop-content-count.txt" 2>/dev/null)
  check "六轮备份轮全部收场（run1..run6 ok）" bash -c "[ \"\$(grep -l '\"ok\" *: *true' \"$d\"/status-run*.json 2>/dev/null | wc -l | tr -d ' ')\" = 6 ]"
  check "相册完整授权在场（引擎口径：source_missing 只在 full 下写；缺了先在设备上授权一次再跑）" has_line "$d/status-run1.json" '"level" *: *"full"'
  check "源文件锚点齐备（base / n2 改前 / n2 改后 各 1 条 64 位 hex）" bash -c "[ -n '$h_base' ] && [ -n '$h_n2v1' ] && [ -n '$h_n2v2' ] && [ '$h_n2v1' != '$h_n2v2' ]"
  check "五类操作全部执行成功（mutate 各步 ok）" bash -c "[ \"\$(grep -l '\"ok\" *: *true' \"$d\"/status-mutate-*.json 2>/dev/null | wc -l | tr -d ' ')\" = 5 ]"
  check "对账后登记映射 2 项（1 个在册新项 + 缺席旧项的映射保留，实测 ${items:-缺失}）" bash -c "[ '${items:-x}' = 2 ]"
  check "第 1 轮对账日志：items=1 missing=0" has_line "$d/ppass.log" 'folder .*: scan ok items=1 missing=0'
  check "改名/移动/修改轮对账日志：items=2 missing=1（旧路径判缺席）" has_line "$d/ppass.log" 'folder .*: scan ok items=2 missing=1'
  check "删除轮对账日志：items=1 missing=3（完整枚举后判缺席）" has_line "$d/ppass.log" 'folder .*: scan ok items=1 missing=3'
  check "源缺失判定落账 3 次（marked 1 cleared 0：改名/移动/删除各一轮）" bash -c "[ \"\$(grep -c 'source_missing: marked 1 cleared 0' \"$d/ppass.log\")\" = 3 ]"
  check "改名与移动分配了新 opaqueId：base 内容在账本里有 3 个不同 media_id（${ids_base}）" bash -c "[ '$ids_base' = 3 ]"
  check "改名/移动/删除的三条旧路径订单全部 CONFIRMED 且 source_missing=1（${dead_base}；桌面副本不动）" bash -c "[ '$dead_base' = 3 ]"
  check "修改产生新版本：n2 改前/改后两个内容同属 1 个 media_id（${versions_media}）" bash -c "[ '$versions_media' = 1 ]"
  check "修改产生新版本：两个版本各出一条 CONFIRMED（${versions_rows}）" bash -c "[ '$versions_rows' = 2 ]"
  check "在册项不受影响：n2 两个版本 source_missing=0（${live_n2}）" bash -c "[ '$live_n2' = 2 ]"
  check "桌面库只落 3 个媒体文件（base 1 份 + n2 两版；改名/移动换 ID 不重复占盘）" bash -c "[ '$desk_n' = 3 ]"
  check "桌面 3 种内容（去重后；${desk_contents}）" bash -c "[ '${desk_contents:-x}' = 3 ]"
  check "桌面落地文件与源内容 BLAKE3 一致（3 个桌面文件哈希 = {base, n2 改前, n2 改后}）" \
    bash -c "printf '%s\n%s\n%s\n' '$h_base' '$h_n2v1' '$h_n2v2' | sort | diff - <(awk '{print \$1}' \"$d/desktop.b3\" 2>/dev/null | sort) >/dev/null"
  check "桌面 photo_count = 3" bash -c "[ '${photo_count:-x}' = 3 ]"
  verdict
}
