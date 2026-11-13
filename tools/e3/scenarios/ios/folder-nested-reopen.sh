# 【E3-1】ADR「验收标准 E3」第 1 条：在真实本地测试目录中选择嵌套素材，杀进程重开后仍能读取并继续备份。
# 主链：登记（stage 平铺文件摆成嵌套目录）→ 杀进程 → 重启 App（新进程按持久化书签恢复）→ 空相册范围 +
# folder: 项全部在范围 → 备份完成；嵌套素材逐个在桌面沙盒库落地且 BLAKE3 与手机源一致。
# 反证：E3-1 没有「故障在场」形态（授权与书签的故障口径在 E2 已覆盖）；本场景 COUNTER=off。
# 素材全部程序生成（噪声图 / testsrc 视频），测试目录只碰 foldere3-*，不动用户相册与素材。
# shellcheck source=ios-lib.bashlib
source "$(dirname "${BASH_SOURCE[0]}")/ios-lib.bashlib"
RUN="e3-$(date +%s)"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/ppass-e3-ios.XXXXXX")
DESK="$WORK/A"
teardown() { ios_pair_allow_stop; desk_stop "$DESK" 2>/dev/null; rm -rf "$WORK"; }

DESC="本地嵌套测试目录：杀进程重开后按持久化书签继续备份，素材在桌面库逐个落地且 BLAKE3 一致"
COUNTER=off

setup() {
  ios_require_tools
  ios_resolve_device
  ios_ensure_installed "$EV"
  ios_reset "$EV"
  ios_make_noise_jpg "$WORK/p1.jpg" 11
  ios_make_noise_jpg "$WORK/p2.jpg" 22
  ios_make_noise_jpg "$WORK/p3.jpg" 33
  mkdir -p "$WORK/stage" && mv "$WORK"/p1.jpg "$WORK"/p2.jpg "$WORK"/p3.jpg "$WORK/stage/"
  ios_push_stage "$EV" "foldere3-stage-$RUN" "$WORK/stage"
  ios_desk_start "$DESK"
  ios_pair_allow_start "$EV" "$DESK"
}

act() {
  local spec="{\"dir\":\"foldere3-$RUN\",\"stage\":\"foldere3-stage-$RUN\",\"manifest\":{\"nest/p1.jpg\":\"p1.jpg\",\"nest/deep/p2.jpg\":\"p2.jpg\",\"nest/deep/deeper/p3.jpg\":\"p3.jpg\"},\"display\":\"PPass FolderE3 $RUN\"}"
  # 1) 登记（专用启动；登记后该进程即被下一次启动替换 = 一次显式杀进程）
  ios_launch "$OUT" add "$(jq -cn --arg s "$spec" --arg r "$RUN-add" \
    '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_BGTEST_FOLDER_ADD:$s}')" || return 1
  ios_wait_status "$OUT/add" "$RUN-add" 60 true >/dev/null || { ios_copy_from Documents/e2e/status.json "$OUT/add.status.json"; return 1; }
  cp "$OUT/add.status.json" "$OUT/status-add.json"
  # 2) 杀进程（devicectl 终止登记进程）后重启：新进程读持久化注册表与书签继续备份
  [ -n "$APP_PID" ] && xcrun devicectl device process terminate --device "$DEV" --pid "$APP_PID" --kill >>"$OUT/stop.log" 2>&1 || true
  sleep 6  # 等系统 BGTask 重拉 settle，避免与 devicectl 启动竞态
  desk_qr "$DESK" # 一次性配对串：desk_qr 设 PAIR_QR，不回显
  ios_launch "$OUT" run "$(jq -cn --arg l "$PAIR_QR" --arg r "$RUN-run" \
    '{PPASS_E2E_DIR:"container",PPASS_E2E_RUN:$r,PPASS_E2E_PAIR_LINK:$l,PPASS_BGTEST_FOLDER_RUN:"1"}')" || return 1
  ios_wait_status "$OUT/run" "$RUN-run" 300 true >/dev/null || { ios_copy_from Documents/e2e/status.json "$OUT/run.status.json"; return 1; }
  cp "$OUT/run.status.json" "$OUT/status-run.json"
  # 3) 证据：登记清单、账本、日志、桌面库文件与哈希、手机源文件哈希
  ios_collect_common "$OUT"
  desk_ipc "$DESK" status >"$OUT/desk-status.json"
  desk_ipc "$DESK" devices.list >"$OUT/desk-devices.json" 2>/dev/null || true
  cp "$DESK/daemon.out" "$OUT/daemon.out" 2>/dev/null; cp "$DESK/daemon.err" "$OUT/daemon.err" 2>/dev/null
  find "$DESK/home" "$(cat "$DESK/sandbox")" -type f \( -iname '*.jpg' -o -iname '*.mp4' \) \
    ! -path '*/thumbs/*' ! -path '*/.thumbs/*' ! -path '*/tmp/*' 2>/dev/null | sort >"$OUT/desktop-files.txt"
  B3="$(ios_b3)"
  : >"$OUT/desktop.b3"
  while IFS= read -r f; do "$B3" "$f" >>"$OUT/desktop.b3"; done <"$OUT/desktop-files.txt"
  # 手机源文件拉回与哈希（源目录里的三张嵌套图）
  : >"$OUT/phone.b3"
  for f in nest/p1.jpg nest/deep/p2.jpg nest/deep/deeper/p3.jpg; do
    name="phone-$(echo "$f" | tr / -)"
    ios_copy_from "Documents/foldere3-$RUN/$f" "$OUT/$name" || true
    [ -s "$OUT/$name" ] && "$B3" "$OUT/$name" >>"$OUT/phone.b3"
  done
  cp "$OUT/phone.b3" "$OUT/hashes.txt"
  echo "== desktop.b3 ==" >>"$OUT/hashes.txt"; cat "$OUT/desktop.b3" >>"$OUT/hashes.txt"
}

judge() {
  local d="$1" orders confirmed
  orders=$(jget "$d/status-run.json" 'j["folder_orders"]')
  confirmed=$(jget "$d/status-run.json" 'j["confirmed"]')
  check "登记成功（folder_added，含嵌套 manifest）" has_line "$d/status-add.json" '"step" *: *"folder_added"'
  check "杀进程后重启：登记与备份是两个进程（pid 不同）" bash -c "pid1=\$(jq -r '.result.process.processIdentifier' \"$d/launch-add.json\"); pid2=\$(jq -r '.result.process.processIdentifier' \"$d/launch-run.json\"); [ -n \"\$pid1\" ] && [ -n \"\$pid2\" ] && [ \"\$pid1\" != \"\$pid2\" ]"
  check "备份收场：folder 订单 $orders 条全部确认（confirmed=$confirmed)" bash -c "[ ${orders:-0} -ge 3 ] && [ \"${confirmed:-0}\" = \"${orders:-0}\" ]"
  check "重启后书签仍可用（登记清单里有 registered 来源）" has_line "$d/folder-list.json" '"status" *: *"registered"'
  check "引擎看到 3 项嵌套素材（scan ok items=3 missing=0）" has_line "$d/ppass.log" 'folder .*: scan ok items=3 missing=0'
  check "账本里 folder: 前缀订单 ≥3 且全部 CONFIRMED" bash -c "[ \"\$(sqlite3 -readonly \"$d/db/backup-orders.db\" \"SELECT COUNT(*) FROM orders WHERE media_id LIKE 'folder:%' AND state='CONFIRMED'\")\" -ge 3 ]"
  check "桌面库收到 3 个媒体文件" bash -c "[ \"\$(wc -l <\"$d/desktop-files.txt\" | tr -d ' ')\" = 3 ]"
  check "手机源 3 张 BLAKE3 与桌面库逐一相等" bash -c "comm -23 <(awk '{print \$1}' \"$d/phone.b3\" | sort) <(awk '{print \$1}' \"$d/desktop.b3\" | sort) | grep -q . && exit 1 || exit 0"
  check "桌面沙盒日志无 panic" no_line "$d/daemon.err" 'panicked|PANIC'
  verdict
}
