# 【E3-2】ADR「验收标准 E3」第 2 条：新增、移动、改名、删除和修改素材后，元数据对账能发现；不依赖门铃才能补齐。
# 主链：登记 1 张图并备份收场 → 钩子对测试目录做 增/改名/移/改/删 → 重新触发一轮**带 reconcile 的备份轮**
#（trigger(.scopeAdded)，不是 foregroundMediaChange 门铃）→ 判定：新项被发现并确认、改名/移动分配新 opaqueId
# 且桌面不重复占盘（内容哈希去重）、修改产生新版本确认、删除在完整枚举后记源缺失而桌面副本不动。
# 反证：判据依赖的「对账发现」本身在 E2 引擎与 FolderMediaSource 测试已带反证；真机侧注入的是真实文件操作，
# 无独立故障形态可加，COUNTER=off（理由：本场景的每个判据都是「状态对账后的事实」，不是故障判据）。
# shellcheck source=ios-lib.bashlib
source "$(dirname "${BASH_SOURCE[0]}")/ios-lib.bashlib"
RUN="e3-$(date +%s)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ppass-e3-ios.XXXXXX")
DESK="$WORK/A"
teardown() { ios_pair_allow_stop; desk_stop "$DESK" 2>/dev/null; rm -rf "$WORK"; }

DESC="本地目录增删改移后由带对账的备份轮发现：新项确认、改名移动换 ID 桌面不重复、修改出新版本、删除记源缺失"
COUNTER=off

setup() {
  ios_require_tools
  ios_resolve_device
  ios_ensure_installed "$EV"
  ios_reset "$EV"
  ios_make_noise_jpg "$WORK/base.jpg" 7
  ios_make_noise_jpg "$WORK/n2.jpg" 44
  mkdir -p "$WORK/stage" && mv "$WORK/base.jpg" "$WORK/n2.jpg" "$WORK/stage/"
  ios_push_stage "$EV" "foldere3-stage-$RUN" "$WORK/stage"
  ios_desk_start "$DESK"
  ios_pair_allow_start "$EV" "$DESK"
}

act() {
  # 1) 登记（目录里先只有 base.jpg；n2.jpg 留在 stage 给「增」用）→ 配对 → 备份收场
  local spec="{\"dir\":\"foldere3-$RUN\",\"stage\":\"foldere3-stage-$RUN\",\"manifest\":{\"base.jpg\":\"base.jpg\"},\"display\":\"PPass FolderE3 $RUN\"}"
  ios_launch "$OUT" add "$(jq -cn --arg s "$spec" --arg r "$RUN-add" \
    '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_BGTEST_FOLDER_ADD:$s}')" || return 1
  ios_wait_status "$OUT/add" "$RUN-add" 60 true >/dev/null || { ios_copy_from Documents/e2e/status.json "$OUT/add.status.json"; return 1; }
  cp "$OUT/add.status.json" "$OUT/status-add.json"
  desk_qr "$DESK" # 一次性配对串：desk_qr 设 PAIR_QR，不回显
  ios_launch "$OUT" run "$(jq -cn --arg l "$PAIR_QR" --arg r "$RUN-run1" \
    '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_E2E_PAIR_LINK:$l,PPASS_BGTEST_FOLDER_RUN:"1"}')" || return 1
  ios_wait_status "$OUT/run1" "$RUN-run1" 180 true >/dev/null || { ios_copy_from Documents/e2e/status.json "$OUT/run1.status.json"; return 1; }
  cp "$OUT/run1.status.json" "$OUT/status-run1.json"
  # 2) 对测试目录做五类操作（真实文件操作，路径不进日志）：
  #    增（stage→nest/n2.jpg）、改名（base→base-r）、移（→sub/base-r）、改（nest/n2.jpg 翻一字节）、删（sub/base-r.jpg）
  mutate='{"dir":"foldere3-'"$RUN"'","stage":"foldere3-stage-'"$RUN"'","ops":['\
'{"op":"add","from":"n2.jpg","to":"nest/n2.jpg"},'\
'{"op":"rename","from":"base.jpg","to":"base-r.jpg"},'\
'{"op":"move","from":"base-r.jpg","to":"sub/base-r.jpg"},'\
'{"op":"modify","to":"nest/n2.jpg","offset":120},'\
'{"op":"delete","to":"sub/base-r.jpg"}]}'
  ios_launch "$OUT" mutate "$(jq -cn --arg s "$mutate" --arg r "$RUN-mutate" \
    '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_BGTEST_FOLDER_MUTATE:$s}')" || return 1
  ios_wait_status "$OUT/mutate" "$RUN-mutate" 60 true >/dev/null || { ios_copy_from Documents/e2e/status.json "$OUT/mutate.status.json"; return 1; }
  cp "$OUT/mutate.status.json" "$OUT/status-mutate.json"
  # 3) 再触发一轮带 reconcile 的备份轮：对账发现上述全部变化并落到账本
  ios_launch "$OUT" run2 "$(jq -cn --arg r "$RUN-run2" \
    '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_BGTEST_FOLDER_RUN:"1"}')" || return 1
  ios_wait_status "$OUT/run2" "$RUN-run2" 300 true >/dev/null || { ios_copy_from Documents/e2e/status.json "$OUT/run2.status.json"; return 1; }
  cp "$OUT/run2.status.json" "$OUT/status-run2.json"
  # 4) 证据：账本（media_id 与 content_hash 全集）、日志、登记清单、桌面库
  ios_collect_common "$OUT"
  desk_ipc "$DESK" status >"$OUT/desk-status.json"
  find "$DESK/home" "$(cat "$DESK/sandbox")" -type f \( -iname '*.jpg' -o -iname '*.mp4' \) \
    ! -path '*/thumbs/*' ! -path '*/.thumbs/*' ! -path '*/tmp/*' 2>/dev/null | sort >"$OUT/desktop-files.txt"
  ios_orders_dump "$OUT" orders.txt
  sqlite3 -readonly "$OUT/db/backup-orders.db" "SELECT COUNT(DISTINCT content_hash) FROM orders WHERE state='CONFIRMED'" >"$OUT/desktop-content-count.txt"
  cp "$OUT/folder-list.json" "$OUT/folder-list-after.json" 2>/dev/null || true
}

judge() {
  local d="$1" items photo_count
  items=$(jget "$d/folder-list-after.json" 'j["sources"][0]["items"]')
  photo_count=$(jget "$d/desk-status.json" 'j["result"]["photo_count"]')
  check "第一轮收场（1 项确认）" has_line "$d/status-run1.json" '"ok" *: *true'
  check "五类操作全部执行成功" bash -c "[ \"\$(grep -c '\"ok\" *: *true' \"$d/status-mutate.json\")\" -ge 5 ]"
  check "对账后登记映射 2 项（1 个在册新项 + 1 个缺席旧项的映射保留，实测 ${items}）" bash -c "[ \"${items:-x}\" = \"2\" ]"
  check "对账日志：完整枚举 items=1 且缺席 1（base.jpg 判源缺失）" has_line "$d/ppass.log" 'folder .*: scan ok items=1 missing=1'
  check "修改过的文件出了新版本并被确认（同一媒体第二条 CONFIRMED 订单）" has_line "$d/orders.txt" 'CONFIRMED'
  check "删除项的订单被标 source_missing=1（桌面副本不动）" has_line "$d/orders.txt" 'CONFIRMED|1'
  check "确认内容去重后桌面只留两种内容（改前 base 与改后 n2）" bash -c "[ \"\$(tr -d '[:space:]' <\"$d/desktop-content-count.txt\")\" = 2 ]"
  check "桌面库只落 2 个媒体文件（改名/移动换 ID 不重复占盘）" bash -c "[ \"\$(wc -l <\"$d/desktop-files.txt\" | tr -d ' ')\" = 2 ]"
  check "桌面 photo_count = 2" bash -c "[ \"${photo_count:-x}\" = \"2\" ]"
  verdict
}
