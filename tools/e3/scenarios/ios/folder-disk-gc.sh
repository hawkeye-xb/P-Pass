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
  ios_file_size "$WORK/big.mp4" >"$EV/big-size.txt" # judge 读实测源大小（素材会被 mv 进 stage）
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
  ios_desktop_files "$out" "desktop-files-$name.txt" -iname '*.jpg' -o -iname '*.mp4'
}

act() {
  local spec="{\"dir\":\"foldere3-$RUN\",\"stage\":\"foldere3-stage-$RUN\",\"manifest\":{\"big.mp4\":\"big.mp4\",\"nest/p1.jpg\":\"p1.jpg\"},\"display\":\"PPass FolderE3 $RUN\"}"
  ios_launch "$OUT" add "$(jq -cn --arg s "$spec" --arg r "$RUN-add" \
    '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_BGTEST_FOLDER_ADD:$s}')" || return 1
  ios_wait_status "$OUT/add" "$RUN-add" 60 true >/dev/null || { ios_copy_from Documents/e2e/status.json "$OUT/add.status.json"; return 1; }
  cp "$OUT/add.status.json" "$OUT/status-add.json"
  disk_measure "$OUT" before
  # 源目录占盘的前后值当场摘成固定名文件：judge（含离线回放）不再按 test_dir_foldere3-<RUN> 键去
  # after.json 里拼——回放时 RUN 是新值，键对不上必红。
  jget "$OUT/before.json" 'j["bytes"]["test_dir_foldere3-'"$RUN"'"]' >"$OUT/src-dir-bytes-before.txt"
  # 基线后开始备份（大文件传输需时间；配对在前）。watch 让驱动每拍报 big.mp4 这一张的订单状态。
  desk_qr "$DESK" # 一次性配对串：desk_qr 设 PAIR_QR，不回显
  local watch="{\"display\":\"PPass FolderE3 $RUN\",\"file\":\"big.mp4\"}"
  ios_launch "$OUT" run "$(jq -cn --arg l "$PAIR_QR" --arg r "$RUN-run" --arg w "$watch" \
    '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_E2E_PAIR_LINK:$l,PPASS_BGTEST_FOLDER_RUN:"1",PPASS_BGTEST_FOLDER_RUN_WATCH:$w}')" || return 1
  # 等大文件确实 TRANSFERRING（订单在建且这一张在传）才强杀——崩溃注入。
  # 只等「backing_up」会在扫描/导入阶段就满足（confirmed/in_scope_total 对目录-only 轮没有意义），
  # 杀掉的就不是传输中断场景；等不到就失败收场，绝不杀一个没在传的进程。
  local i hit=0
  for i in $(seq 1 150); do
    ios_copy_from Documents/e2e/status.json "$OUT/mid.status.json" 2>/dev/null || { sleep 2; continue; }
    if [ "$(jq -r '.step // ""' "$OUT/mid.status.json")" = backing_up ] \
       && [ "$(jq -r '.watch_state // ""' "$OUT/mid.status.json")" = TRANSFERRING ]; then
      hit=1
      break
    fi
    sleep 2
  done
  if [ "$hit" != 1 ]; then
    echo "150 次轮询没等到 big.mp4 的 TRANSFERRING（备份太快要收场或没开始）：崩溃注入不执行，本场景按失败收" >&2
    cp "$OUT/mid.status.json" "$OUT/crash-not-hit.status.json" 2>/dev/null || true
    return 1
  fi
  echo "big.mp4 TRANSFERRING observed at $(date '+%T')" >>"$OUT/crash.log"
  [ -n "$APP_PID" ] && xcrun devicectl device process terminate --device "$DEV" --pid "$APP_PID" --kill >>"$OUT/crash.log" 2>&1
  echo "crash injected at $(date '+%T')" >>"$OUT/crash.log"
  sleep 3
  # 重启：崩溃后继续（遗留 TRANSFERRING 单按「遗留续传」最先取）
  ios_launch "$OUT" resume "$(jq -cn --arg r "$RUN-resume" '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_BGTEST_FOLDER_RUN:"1"}')" || return 1
  ios_wait_status "$OUT/resume" "$RUN-resume" 600 true >/dev/null || { ios_copy_from Documents/e2e/status.json "$OUT/resume.status.json"; return 1; }
  cp "$OUT/resume.status.json" "$OUT/status-resume.json"
  disk_measure "$OUT" after
  jget "$OUT/after.json" 'j["bytes"]["test_dir_foldere3-'"$RUN"'"]' >"$OUT/src-dir-bytes-after.txt"
  desktop_du "$OUT" after
  ios_collect_common "$OUT"
  cp "$EV/big-size.txt" "$OUT/big-size.txt" # judge 离线回放也读得到（EV 只在 run_one 里有）
  desk_ipc "$DESK" status >"$OUT/desk-status.json"
}

judge() {
  local d="$1" src_big before_blobs after_blobs tmp_before tmp_after desk_bytes src_before src_after
  src_big=$(tr -d '[:space:]' <"$d/big-size.txt" 2>/dev/null)
  [ -n "$src_big" ] || src_big=0
  before_blobs=$(jget "$d/before.json" 'j["bytes"]["provider_blobs"]')
  after_blobs=$(jget "$d/after.json" 'j["bytes"]["provider_blobs"]')
  tmp_before=$(jget "$d/before.json" 'j["bytes"]["app_tmp"]')
  tmp_after=$(jget "$d/after.json" 'j["bytes"]["app_tmp"]')
  # 桌面 1x：桌面库里媒体文件字节合计（视频+图，不含缩略图/索引）≈ 源大小
  desk_bytes=$(while IFS= read -r f; do ios_file_size "$f"; done <"$d/desktop-files-after.txt" | awk '{s+=$1} END{print s+0}')
  # 源目录占盘：act 当场摘好的固定名文件（离线回放可读），before/after 实对比——只读目录被写入
  # 增量也要判红，不是只查「after 不小于下界」。
  src_before=$(tr -d '[:space:]' <"$d/src-dir-bytes-before.txt" 2>/dev/null)
  src_after=$(tr -d '[:space:]' <"$d/src-dir-bytes-after.txt" 2>/dev/null)
  check "登记与崩溃后续传都收场" has_line "$d/status-resume.json" '"ok" *: *true'
  check "崩溃注入发生在传输中（crash.log 记了 TRANSFERRING 观测，不是扫描阶段杀的）" has_line "$d/crash.log" 'TRANSFERRING observed'
  check "源目录占盘不变（实测 before=${src_before:-缺失} after=${src_after:-缺失} 字节，视频 $src_big + 图；只读未动）" \
    bash -c "[ -n '${src_before:-}' ] && [ '${src_before:-0}' = '${src_after:-1}' ] && [ '${src_after:-0}' -ge $(( src_big + 10000 )) ]"
  check "手机侧 provider blobs 增长远小于源大小（引用导入不复制字节；$before_blobs → $after_blobs)" bash -c "[ \$(( ${after_blobs:-0} - ${before_blobs:-0} )) -lt $(( src_big / 2 )) ]"
  check "App tmp 备份后基本清空（≤ 源大小 5%，$tmp_before → $tmp_after)" bash -c "[ \"${tmp_after:-0}\" -le $(( src_big / 20 + 1000000 )) ]"
  check "桌面库 1x：媒体文件字节合计 $desk_bytes ≈ 源 ${src_big}（浮动含图）" bash -c "[ \"${desk_bytes:-0}\" -ge $(( src_big / 2 )) ] && [ \"${desk_bytes:-0}\" -le $(( src_big + 5000000 )) ]"
  check "桌面收到 2 个媒体文件（视频+图）" bash -c "[ \"\$(wc -l <\"$d/desktop-files-after.txt\" | tr -d ' ')\" = 2 ]"
  check "崩溃后 GC 收敛：重启收场后 blobs 不高于基线（崩溃注入的临时产物被回收；$before_blobs → $after_blobs)" bash -c "[ \"${after_blobs:-0}\" -le $(( ${before_blobs:-0} + 1000000 )) ]"
  check "日志有崩溃前传输与重启后续传两个阶段的痕迹" bash -c "grep -q 'process start:' \"$d/ppass.log\" && grep -q 'folder .*: imported' \"$d/ppass.log\""
  verdict
}
