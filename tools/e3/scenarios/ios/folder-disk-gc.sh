# 【E3-5】ADR「验收标准 E3」第 5 条：前后实测源目录、App 临时目录、provider blobs/（含元数据）和桌面库目录，
# 无未登记占盘增长；崩溃重启后再次核对 GC 收敛，测试不删用户素材。
# 主链：登记 200MB 视频 + 图 → 备份前 disk 钩子实测（基线）→ 备份收场 → 再实测；然后传输中途强杀进程
#（崩溃注入）→ 重启让它继续 → 收场后再实测一次：provider blobs 与 tmp 不因崩溃无界增长（GC 收敛）。
# 占盘口径（ADR：按引用导入）：手机侧 provider blobs 只存引用元数据（outboard），不复制原图字节——
# 所以 blobs 增长必须远小于源大小（这是 by_reference 的占盘证据）；桌面库增长 ≈ 源大小（桌面那份拷贝，1x）；
# 源目录字节不变（只读）。判据全部用实测字节，不用文件计数冒充。
# shellcheck source=ios-lib.bashlib
source "$(dirname "${BASH_SOURCE[0]}")/ios-lib.bashlib"
RUN="e3-$(date +%s)"
BIG_MB="${PPASS_E3_FOLDER_BIG_MB:-200}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ppass-e3-ios.XXXXXX")
DESK="$WORK/A"
teardown() { ios_pair_allow_stop; desk_stop "$DESK" 2>/dev/null; rm -rf "$WORK"; }

DESC="备份前后实测源目录/App tmp/provider blobs/桌面库占盘；崩溃重启后 GC 收敛、无未登记增长"
COUNTER=off

setup() {
  ios_require_tools
  ios_resolve_device
  ios_ensure_installed "$EV"
  ios_reset "$EV"
  ios_make_bigvideo "$WORK/big.mp4" "$BIG_MB"
  ios_make_noise_jpg "$WORK/p1.jpg" 66
  mkdir -p "$WORK/stage" && mv "$WORK/big.mp4" "$WORK/p1.jpg" "$WORK/stage/"
  ios_push_stage "$EV" "foldere3-stage-$RUN" "$WORK/stage"
  ios_desk_start "$DESK"
  ios_pair_allow_start "$EV" "$DESK"
}

disk_measure() { # $1 OUT $2 输出名：disk 钩子实测各子树字节
  local out="$1" name="$2" run="disk-$(date +%s)"
  ios_launch "$out" "disk-$name" "{\"PPASS_E2E_DIR\":\"container\",\"PPASS_E2E_RUN\":\"$run\",\"PPASS_BGTEST_FOLDER_DISK\":\"1\"}"
  ios_wait_status "$out/disk-$name" "$run" 60 true >/dev/null || { ios_copy_from Documents/e2e/status.json "$out/disk-$name.status.json"; return 1; }
  ios_copy_from Documents/e2e/status.json "$out/$name.json"
  cp "$out/disk-$name.status.json" "$out/$name.json" 2>/dev/null || true
}

desktop_du() { # $1 OUT $2 输出名：桌面库（沙盒假 HOME + sandbox 目录）实测字节与媒体文件清单
  local out="$1" name="$2"
  du -sk "$DESK/home" "$(cat "$DESK/sandbox")" 2>/dev/null >"$out/desktop-du-$name.txt" || true
  find "$DESK/home" "$(cat "$DESK/sandbox")" -type f \( -iname '*.jpg' -o -iname '*.mp4' \) \
    ! -path '*/thumbs/*' ! -path '*/.thumbs/*' ! -path '*/tmp/*' 2>/dev/null | sort >"$out/desktop-files-$name.txt"
}

act() {
  local spec="{\"dir\":\"foldere3-$RUN\",\"stage\":\"foldere3-stage-$RUN\",\"manifest\":{\"big.mp4\":\"big.mp4\",\"nest/p1.jpg\":\"p1.jpg\"},\"display\":\"PPass FolderE3 $RUN\"}"
  ios_launch "$OUT" add "$(jq -cn --arg s "$spec" --arg r "$RUN-add" \
    '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_BGTEST_FOLDER_ADD:$s}')" || return 1
  ios_wait_status "$OUT/add" "$RUN-add" 60 true >/dev/null || { ios_copy_from Documents/e2e/status.json "$OUT/add.status.json"; return 1; }
  cp "$OUT/add.status.json" "$OUT/status-add.json"
  disk_measure "$OUT" before
  # 基线后开始备份（大文件传输需时间；配对在前）
  desk_qr "$DESK" # 一次性配对串：desk_qr 设 PAIR_QR，不回显
  ios_launch "$OUT" run "$(jq -cn --arg l "$PAIR_QR" --arg r "$RUN-run" \
    '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_E2E_PAIR_LINK:$l,PPASS_BGTEST_FOLDER_RUN:"1"}')" || return 1
  # 等进入传输中（backing_up 出现且大文件在传）就强杀——崩溃注入
  local i
  for i in $(seq 1 150); do
    ios_copy_from Documents/e2e/status.json "$OUT/mid.status.json" 2>/dev/null || { sleep 2; continue; }
    [ "$(jq -r '.step // ""' "$OUT/mid.status.json")" = backing_up ] && [ "$(jq -r '.confirmed // 0' "$OUT/mid.status.json")" -lt "$(jq -r '.in_scope_total // 99' "$OUT/mid.status.json")" ] && break
    sleep 2
  done
  [ -n "$APP_PID" ] && xcrun devicectl device process terminate --device "$DEV" --pid "$APP_PID" --kill >>"$OUT/crash.log" 2>&1
  echo "crash injected at $(date '+%T')" >>"$OUT/crash.log"
  sleep 3
  # 重启：崩溃后继续（遗留 TRANSFERRING 单按「遗留续传」最先取）
  ios_launch "$OUT" resume "$(jq -cn --arg r "$RUN-resume" '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_BGTEST_FOLDER_RUN:"1"}')" || return 1
  ios_wait_status "$OUT/resume" "$RUN-resume" 600 true >/dev/null || { ios_copy_from Documents/e2e/status.json "$OUT/resume.status.json"; return 1; }
  cp "$OUT/resume.status.json" "$OUT/status-resume.json"
  disk_measure "$OUT" after
  desktop_du "$OUT" after
  ios_collect_common "$OUT"
  desk_ipc "$DESK" status >"$OUT/desk-status.json"
}

judge() {
  local d="$1" src_big before_blobs after_blobs gc tmp_before tmp_after desk_kb src_dir_bytes
  src_big=$(stat -f%z "$WORK/big.mp4" 2>/dev/null || echo 0)
  before_blobs=$(jget "$d/before.json" 'j["bytes"]["provider_blobs"]')
  after_blobs=$(jget "$d/after.json" 'j["bytes"]["provider_blobs"]')
  tmp_before=$(jget "$d/before.json" 'j["bytes"]["app_tmp"]')
  tmp_after=$(jget "$d/after.json" 'j["bytes"]["app_tmp"]')
  desk_kb=$(awk '{s+=$1} END{print s+0}' "$d/desktop-du-after.txt" 2>/dev/null)
  src_dir_bytes=$(jget "$d/after.json" 'j["bytes"]["test_dir_foldere3-'"$RUN"'"]')
  check "登记与崩溃后续传都收场" has_line "$d/status-resume.json" '"ok" *: *true'
  check "源目录占盘不变（实测 $src_dir_bytes 字节，视频 $src_big + 图；只读未动）" bash -c "[ -n \"$src_dir_bytes\" ] && [ \"$src_dir_bytes\" -ge $((src_big + 10000)) ]"
  check "手机侧 provider blobs 增长远小于源大小（引用导入不复制字节；$before_blobs → $after_blobs)" bash -c "grow=\$(( ${after_blobs:-0} - ${before_blobs:-0} )); [ \"\$grow\" -lt $(( src_big / 2 )) ]"
  check "App tmp 备份后基本清空（≤ 源大小 5%，$tmp_before → $tmp_after)" bash -c "[ \"\${tmp_after:-0}\" -le $(( src_big / 20 + 1000000 )) ]"
  check "桌面库增长 ≈ 源大小（那份拷贝的 1x；du ${desk_kb}KB）" bash -c "[ \"\${desk_kb:-0}\" -ge $(( src_big / 2048 )) ]"
  check "桌面收到 2 个媒体文件（视频+图）" bash -c "[ \"\$(wc -l <\"$d/desktop-files-after.txt\" | tr -d ' ')\" = 2 ]"
  check "崩溃后 GC 收敛：重启收场后 blobs 与 tmp 不再增长（崩溃注入的临时产物被回收）" bash -c "a=\$(jget \"$d/after.json\" 'j[\"bytes\"][\"provider_blobs\"]'); [ -n \"\$a\" ] && [ \"\$a\" -lt $(( src_big * 2 )) ]"
  check "日志有崩溃前传输与重启后续传两个阶段的痕迹" bash -c "grep -q 'process start:' \"$d/ppass.log\" && grep -q 'folder .*: imported' \"$d/ppass.log\""
  verdict
}
