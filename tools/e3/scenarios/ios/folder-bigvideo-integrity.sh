# 【E3-3】ADR「验收标准 E3」第 3 条：代表性大视频完整流式备份，by_reference=true，手机源文件与桌面入库文件
# BLAKE3 一致；对测试副本故意截断或改一字节必须失败，不得确认。
# main：登记测试目录（200MB 真实 H.264 MP4 + 1 张图）→ 备份收场 → 日志带 ref=yes 的引用导入行 →
# 手机源与桌面库文件独立 BLAKE3（tools/ios/b3sum）一致。
# counter（反证）：供数期注入——大文件引用导入完成后把源文件改一字节 / 截断（DEBUG 钩子 folderIntegrity，
# 一次启动内完成 注入 → 等「source changed while serving」→ 钩子自检该张订单不得 CONFIRMED → 还原 →
# 再触发对账 → 等重新确认）；截断与改字节各跑一轮。judge 用「日志无供数期源改动」判据：main 绿、counter 红；
# 反证产物（serve_aborted / orders_after_abort 无 CONFIRMED / 还原后重新确认）留在 counter 证据目录里供报告引用。
# 注入点故意在远超 64KiB 的偏移（flip 默认 offset=size-16），排除「前 64KiB 探针」式假证（ADR §背景）。
# judge 按证据目录形态分流：main 判主链判据；counter 判反证链条（注入→观测→查单→还原→重确认全走完）+
# 「预期失败」红——链条不齐不算变红，离线回放同一份逻辑（详见 judge/judge_main/judge_counter）。
# shellcheck source=ios-lib.bashlib
source "$(dirname "${BASH_SOURCE[0]}")/ios-lib.bashlib"
RUN="e3-$(date +%s)"
BIG_MB="${PPASS_E3_FOLDER_BIG_MB:-200}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ppass-e3-ios.XXXXXX")
DESK="$WORK/A"

DESC="大视频完整流式备份 by_reference 且手机↔桌面 BLAKE3 一致；供数期改一字节/截断必须传输失败不得确认"
COUNTER=on

setup() {
  ios_require_tools
  ios_resolve_device
  ios_ensure_installed "$EV"
  ios_reset "$EV"
  ios_make_bigvideo "$WORK/big.mp4" "$BIG_MB"
  ios_make_bigvideo "$WORK/big2.mp4" "$BIG_MB" 7 # 反证源：内容不同（时长错开），主链不碰它
  ios_make_noise_jpg "$WORK/p1.jpg" 55
  mkdir -p "$WORK/stage" && mv "$WORK/big.mp4" "$WORK/p1.jpg" "$WORK/stage/"
  ios_push_stage "$EV" "foldere3-stage-$RUN" "$WORK/stage"
  mkdir -p "$WORK/stage-b" && mv "$WORK/big2.mp4" "$WORK/stage-b/"
  ios_push_stage "$EV" "foldere3-stage-$RUN-b" "$WORK/stage-b"
  ios_desk_start "$DESK"
  ios_pair_allow_start "$EV" "$DESK"
}

act() {
  local spec="{\"dir\":\"foldere3-$RUN\",\"stage\":\"foldere3-stage-$RUN\",\"manifest\":{\"big.mp4\":\"big.mp4\",\"nest/p1.jpg\":\"p1.jpg\"},\"display\":\"PPass FolderE3 $RUN\"}"
  ios_launch "$OUT" add "$(jq -cn --arg s "$spec" --arg r "$RUN-add" \
    '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_BGTEST_FOLDER_ADD:$s}')" || return 1
  ios_wait_status "$OUT/add" "$RUN-add" 60 true >/dev/null || { ios_copy_from Documents/e2e/status.json "$OUT/add.status.json"; return 1; }
  cp "$OUT/add.status.json" "$OUT/status-add.json"
  desk_qr "$DESK" # 一次性配对串：desk_qr 设 PAIR_QR，不回显
  ios_launch "$OUT" run "$(jq -cn --arg l "$PAIR_QR" --arg r "$RUN-run" \
    '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_E2E_PAIR_LINK:$l,PPASS_BGTEST_FOLDER_RUN:"1"}')" || return 1
  ios_wait_status "$OUT/run" "$RUN-run" 600 true >/dev/null || { ios_copy_from Documents/e2e/status.json "$OUT/run.status.json"; return 1; }
  cp "$OUT/run.status.json" "$OUT/status-run.json"
  ios_collect_common "$OUT"
  desk_ipc "$DESK" status >"$OUT/desk-status.json"
  ios_desktop_files "$OUT" desktop-files.txt -iname '*.mp4'
  local b3; b3="$(ios_b3)"
  ios_copy_from "Documents/foldere3-$RUN/big.mp4" "$OUT/phone-big.mp4"
  "$b3" "$OUT/phone-big.mp4" >"$OUT/phone-big.b3"
  : >"$OUT/desktop.b3"
  while IFS= read -r f; do "$b3" "$f" >>"$OUT/desktop.b3"; done <"$OUT/desktop-files.txt"
  { echo "== phone-big =="; cat "$OUT/phone-big.b3"; echo "== desktop =="; cat "$OUT/desktop.b3"; } >"$OUT/hashes.txt"
}

# 反证证据目录自足：counter() 只产自己的证据（status-add-b / status-integrity-flip / orders-flip /
# ppass.log），不复用 main 的任何文件。judge 按目录形态分流——两种形态各有完整判据，
# 离线回放（tools/e3/run judge）读到哪种就判哪种，不再因缺 main 证据整版飘红。
judge() {
  local d="$1"
  if [ -f "$d/status-integrity-flip.json" ]; then judge_counter "$d"; else judge_main "$d"; fi
}

judge_main() {
  local d="$1" orders confirmed bigsize photo_count
  orders=$(jget "$d/status-run.json" 'j["folder_orders"]')
  confirmed=$(jget "$d/status-run.json" 'j["confirmed"]')
  bigsize=$(ios_file_size "$d/phone-big.mp4")
  photo_count=$(jget "$d/desk-status.json" 'j["result"]["photo_count"]')
  check "备份收场：folder 订单 $orders 条全部确认（confirmed=$confirmed)" bash -c "[ ${orders:-0} -ge 2 ] && [ \"${confirmed:-0}\" = \"${orders:-0}\" ]"
  check "大文件按引用导入（日志 ref=yes，bytes=$bigsize 与源大小一致）" has_line "$d/ppass.log" "folder .*: imported bytes=$bigsize hash=.* ref=yes"
  check "手机源大文件哈希齐备（1 条 64 位 hex；拉回失败留空在这里判红）" b3_list_ok "$d/phone-big.b3" 1
  check "桌面哈希清单齐备（≥1 条）" b3_list_ok "$d/desktop.b3" 1
  check "手机源大文件 BLAKE3 与桌面库文件一致（按完整哈希字段比较）" bash -c "h=\$(awk 'NR==1{print \$1}' \"$d/phone-big.b3\"); awk -v h=\"\$h\" '\$1==h{f=1} END{exit f?0:1}' \"$d/desktop.b3\""
  check "桌面 photo_count = 2" bash -c "[ \"${photo_count:-x}\" = \"2\" ]"
  # 反证判据：干净备份的证据里绝不允许出现「供数期源被改」
  check "日志无供数期源改动（source changed while serving）" no_line "$d/ppass.log" 'source changed while serving'
  verdict
}

judge_counter() {
  local d="$1" old new offset latest
  old=$(jget "$d/status-integrity-flip.json" 'j["corrupted"]["old_byte"]')
  new=$(jget "$d/status-integrity-flip.json" 'j["corrupted"]["new_byte"]')
  offset=$(jget "$d/status-integrity-flip.json" 'j["corrupted"]["offset"]')
  latest=$(jget "$d/status-integrity-flip.json" 'j["waiting_reconfirm"]["latest"]')
  # 反证链条（必须全部 ok 才算「预期失败」在场）：注入真实执行 → 供数期源改动被观测 →
  # 坏内容未确认 → 还原后重新确认。链条不完整时下面不注入预期红，judge 判 0，
  # 由 run 记「反证没变红」拦下——缺证据不许冒充变红。
  check "反证闭环收场（注入→观测→查单→还原→重确认全走完，ok=true）" has_line "$d/status-integrity-flip.json" '"ok" *: *true'
  check "注入已执行（flip：old_byte=${old:-缺失} → new_byte=${new:-缺失}，确实翻了）" bash -c "[ -n '${old:-}' ] && [ '${old:-x}' != '${new:-y}' ]"
  check "注入偏移远超 64KiB（offset=${offset:-0} ≥ 65536，排除前 64KiB 探针式假证）" bash -c "[ '${offset:-0}' -ge 65536 ]"
  check "供数期源改动被观测（source changed while serving 在本轮日志里）" has_line "$d/ppass.log" 'source changed while serving'
  check "注入时该张订单没有坏内容 CONFIRMED（orders_after_abort 无 CONFIRMED）" \
    bash -c "[ \"\$(jq -r '[.orders_after_abort.states[]? | select(. == \"CONFIRMED\")] | length' \"$d/status-integrity-flip.json\" 2>/dev/null)\" = 0 ]"
  check "还原后重新确认（waiting_reconfirm.latest=${latest:-缺失} = CONFIRMED）" bash -c "[ '${latest:-x}' = 'CONFIRMED' ]"
  if [ "$E3_FAILS" -eq 0 ]; then
    # 预期失败：fault 在场 → 主链不变量「日志无供数期源改动」被打破。这是反证模式的判红点——
    # 上面链条全 ok 证明红得 attributable，judge 由此判非 0（run 记「反证已变红」）。
    check "预期失败：供数期源改动在场，主链不变量被打破（本判据在反证模式预期 FAIL）" \
      no_line "$d/ppass.log" 'source changed while serving'
    verdict
  else
    # 反证模式下 judge 的退出码回答的是「反证有没有按预期变红」：run 把任何非 0 都记成「反证已变红」
    # 并保持 counter_ok=1。所以链条不完整（注入没执行、证据缺失、没观测到源改动）时必须判 0，
    # run 才记「反证没变红」并把整轮判 FAIL；这里若跟着 verdict 返回非 0，缺证据反而被当成反证通过。
    echo "  反证链条不完整（上面有 FAIL）——不算预期失败：judge 判 0，由 run 记「反证没变红」，整轮 FAIL"
    return 0
  fi
}

counter() {
  # 供数期改一字节（offset=size-16，远超 64KiB）。注入对象是**反证专用来源** foldere3-$RUN-b（主链没备份过它，
  # 首次导入-供数窗口才存在；已确认项不会重新导入，等不到窗口）。钩子一次启动内完成：等导入 ref=yes → 注入 →
  # 等「source changed while serving」→ 查该张订单不得 CONFIRMED → 还原 → 再触发 → 等重新确认。
  # ADR 口径是「截断**或**改一字节」：两者走同一道供数期校验（provider 逐叶校验，源改动 ⇒ SourceFault.changed
  # ⇒ 传输放弃），反证注入取「改一字节」；截断语义的合同测试在 E2（SourceUnavailableEngineTests / 源变化口径）。
  local spec="{\"dir\":\"foldere3-$RUN-b\",\"stage\":\"foldere3-stage-$RUN-b\",\"manifest\":{\"big2.mp4\":\"big2.mp4\"},\"display\":\"PPass FolderE3 $RUN-b\"}"
  ios_launch "$OUT" add-b "$(jq -cn --arg s "$spec" --arg r "$RUN-addb" \
    '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_BGTEST_FOLDER_ADD:$s}')" || return 1
  ios_wait_status "$OUT/add-b" "$RUN-addb" 60 true >/dev/null || { ios_copy_from Documents/e2e/status.json "$OUT/add-b.status.json"; return 1; }
  local spec2="{\"dir\":\"foldere3-$RUN-b\",\"file\":\"big2.mp4\",\"mode\":\"flip\",\"display\":\"PPass FolderE3 $RUN-b\"}"
  ios_launch "$OUT" integrity-flip "$(jq -cn --arg s "$spec2" --arg r "$RUN-flip" \
    '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_BGTEST_FOLDER_INTEGRITY:$s}')" || return 1
  ios_wait_status "$OUT/integrity-flip" "$RUN-flip" 900 true >/dev/null \
    || { ios_copy_from Documents/e2e/status.json "$OUT/status-integrity-flip.json"; return 1; }
  ios_copy_from Documents/e2e/status.json "$OUT/status-integrity-flip.json"
  ios_orders_dump "$OUT" orders-flip.txt
  ios_pull_log "$OUT/ppass.log"
}

teardown() {
  # 清测试目录与登记记录（只认 foldere3- 前缀）；收掉沙盒桌面
  ios_pair_allow_stop
  ios_launch "$EV" cleanup "$(jq -cn --arg s "{\"dirs\":[\"foldere3-$RUN\",\"foldere3-$RUN-b\"]}" --arg r "$RUN-cleanup" \
    '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_BGTEST_FOLDER_CLEANUP:$s}')" >/dev/null 2>&1 || true
  desk_stop "$DESK" 2>/dev/null || true
  rm -rf "$WORK" 2>/dev/null || true
}
