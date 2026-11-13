# 【E3-4b】ADR「验收标准 E3」第 4 条后半：同一素材同时经相册与目录出现时，桌面只有一份内容。
# 主链：同一份视频字节走两条来源——目录来源（foldere3-* 测试目录里的 mp4）与相册来源（BGTest 种进
# 「PPass BGTest <run>」测试相册的同一文件）→ 备份收场 → 判定：两条来源各有 CONFIRMED 订单（media_id
# 不同），content_hash 相同，桌面库只落一个文件、photo_count 只加 1，文件 BLAKE3 与源一致。
# 订单按现有语义各自完成、release 广播（ADR §「相册与目录内容重复」口径）；桌面按内容哈希判重（ADR §4）。
# 素材程序生成（testsrc 视频），不碰用户相册（测试相册用 tools/ios/delete-test-assets.sh 可清）。
# shellcheck source=ios-lib.bashlib
source "$(dirname "${BASH_SOURCE[0]}")/ios-lib.bashlib"
RUN="e3-$(date +%s)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ppass-e3-ios.XXXXXX")
DESK="$WORK/A"
teardown() { ios_pair_allow_stop; desk_stop "$DESK" 2>/dev/null; rm -rf "$WORK"; }

DESC="同一素材同时经相册与目录来源备份：两条订单各自确认、桌面只有一份内容且 BLAKE3 与源一致"
COUNTER=off

setup() {
  ios_require_tools
  ios_resolve_device
  ios_ensure_installed "$EV"
  ios_reset "$EV"
  ffmpeg -loglevel error -f lavfi -i "testsrc=size=1280x720:rate=24" -f lavfi -i "sine=frequency=440" \
    -t 20 -c:v libx264 -preset veryfast -b:v 3000k -c:a aac -movflags +faststart -y "$WORK/same.mp4" >&2
  [ -s "$WORK/same.mp4" ] || die "同内容视频生成失败"
  mkdir -p "$WORK/stage" && cp "$WORK/same.mp4" "$WORK/stage/same.mp4"
  ios_push_stage "$EV" "foldere3-stage-$RUN" "$WORK/stage"
  # 相册种子走 e3-batch 的 seed 通道：Documents/e2e/seed/（seedRun 读它）；go 信号一并先推（seedRun ready 后立刻种）
  mkdir -p "$WORK/seed" && cp "$WORK/same.mp4" "$WORK/seed/same.mp4" && printf 'go\n' >"$WORK/seed/go"
  ios_push "$WORK/seed/same.mp4" "Documents/e2e/seed/same.mp4"
  ios_push "$WORK/seed/go" "Documents/e2e/seed/go"
  ios_desk_start "$DESK"
  ios_pair_allow_start "$EV" "$DESK"
}

act() {
  # 1) 登记目录来源（目录里 same.mp4）
  local spec="{\"dir\":\"foldere3-$RUN\",\"stage\":\"foldere3-stage-$RUN\",\"manifest\":{\"same.mp4\":\"same.mp4\"},\"display\":\"PPass FolderE3 $RUN\"}"
  ios_launch "$OUT" add "$(jq -cn --arg s "$spec" --arg r "$RUN-add" \
    '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_BGTEST_FOLDER_ADD:$s}')" || return 1
  ios_wait_status "$OUT/add" "$RUN-add" 60 true >/dev/null || { ios_copy_from Documents/e2e/status.json "$OUT/add.status.json"; return 1; }
  # 2) 相册来源：seedRun 配沙盒桌面 A、建测试相册并只选它，把 seed 里的同一文件种进相册
  desk_qr "$DESK" # 一次性配对串：desk_qr 设 PAIR_QR，不回显
  ios_launch "$OUT" seed "$(jq -cn --arg l "$PAIR_QR" --arg r "$RUN-seed" \
    '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_E2E_PAIR_LINK:$l,PPASS_BGTEST:"1"}')" || return 1
  ios_wait_status "$OUT/seed" "$RUN-seed" 180 true >/dev/null || { ios_copy_from Documents/e2e/status.json "$OUT/seed.status.json"; return 1; }
  ios_copy_from Documents/e2e/status.json "$OUT/status-seeded.json"
  jq -r '.step // ""' "$OUT/status-seeded.json" | grep -q '^seeded$' || { echo "种子没写进相册：$(jq -r '.error // .step' "$OUT/status-seeded.json")" >&2; return 1; }
  # 3) 备份收场：相册 1 项 + 目录 1 项（同一内容）
  ios_launch "$OUT" run "$(jq -cn --arg r "$RUN-run" '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_BGTEST_FOLDER_RUN:"1"}')" || return 1
  ios_wait_status "$OUT/run" "$RUN-run" 600 true >/dev/null || { ios_copy_from Documents/e2e/status.json "$OUT/run.status.json"; return 1; }
  cp "$OUT/run.status.json" "$OUT/status-run.json"
  # 4) 证据
  ios_collect_common "$OUT"
  ios_orders_dump "$OUT" orders.txt
  desk_ipc "$DESK" status >"$OUT/desk-status.json"
  find "$DESK/home" "$(cat "$DESK/sandbox")" -type f \( -iname '*.mp4' -o -iname '*.mov' \) \
    ! -path '*/thumbs/*' ! -path '*/tmp/*' 2>/dev/null | sort >"$OUT/desktop-files.txt"
  local b3; b3="$(ios_b3)"
  ios_copy_from "Documents/foldere3-$RUN/same.mp4" "$OUT/phone-same.mp4"
  "$b3" "$OUT/phone-same.mp4" >"$OUT/phone.b3"
  : >"$OUT/desktop.b3"
  while IFS= read -r f; do "$b3" "$f" >>"$OUT/desktop.b3"; done <"$OUT/desktop-files.txt"
  { echo "== phone =="; cat "$OUT/phone.b3"; echo "== desktop =="; cat "$OUT/desktop.b3"; } >"$OUT/hashes.txt"
  sqlite3 -readonly "$OUT/db/backup-orders.db" \
    "SELECT media_id, state, content_hash FROM orders WHERE state='CONFIRMED' ORDER BY media_id" >"$OUT/confirmed.txt"
}

judge() {
  local d="$1" folder_ids album_ids
  check "相册种子就位（seeded，1 视频）" has_line "$d/status-seeded.json" '"step" *: *"seeded"'
  check "备份收场（相册+目录两项确认）" has_line "$d/status-run.json" '"ok" *: *true'
  check "相册来源与目录来源各有 CONFIRMED 订单（media_id 形态不同：folder: 前缀 vs PHAsset id）" bash -c "album=\$(grep -cv '^folder:' \"$d/confirmed.txt\"); folder=\$(grep -c '^folder:' \"$d/confirmed.txt\"); [ \"\$album\" -ge 1 ] && [ \"\$folder\" -ge 1 ]"
  check "两条来源订单的 content_hash 相同（同一素材）" bash -c "[ \"\$(awk -F'|' '{print \$3}' \"$d/confirmed.txt\" | sort -u | wc -l | tr -d ' ')\" = 1 ]"
  check "桌面 photo_count = 1（内容去重）" bash -c "[ \"\$(jget \"$d/desk-status.json\" 'j[\"result\"][\"photo_count\"]')\" = 1 ]"
  check "桌面库只落 1 个视频文件" bash -c "[ \"\$(wc -l <\"$d/desktop-files.txt\" | tr -d ' ')\" = 1 ]"
  check "手机源 BLAKE3 = 桌面落地文件 BLAKE3" bash -c "h=\$(awk 'NR==1{print \$1}' \"$d/phone.b3\"); grep -q \"^\$h\" \"$d/desktop.b3\""
  verdict
}
