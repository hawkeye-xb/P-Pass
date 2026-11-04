# R0.4/R0.5：桌面与三星手机配对；只选 PPassRegression 相册；备份 40 张并逐张 sha256 对账。
#
# 前提：桌面已装基线并走完向导（win/install-baseline），手机是基线 0.10.2、未配对。
# 照片由 gen-photos.ps1 程序生成，只推进 DCIM/PPassRegression，用户相册不碰。
# 反证：从库的 originals 里删掉一张再对账，sha256 判据必须变红（teardown 放回）。
DESC="R0.4/R0.5：配对三星手机，只备份 PPassRegression 的 40 张，逐张 sha256 对账"
COUNTER=on
PHOTOS=40

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
WIN_SCOPE_PY="$WIN_SCN_DIR/scope.py"

scope_list() { python3 -I "$WIN_SCOPE_PY" list "$(cygpath -w "$1")" 2>/dev/null; }
scope_selected() { python3 -I "$WIN_SCOPE_PY" selected "$(cygpath -w "$1")" 2>/dev/null; }
scope_find() { python3 -I "$WIN_SCOPE_PY" find "$(cygpath -w "$1")" "$2" 2>/dev/null; }
# 配对后有两种相册页：首次「选择要备份的相册」和后进来的「备份哪些照片」。
scope_screen() { win_phone_has "$1" '备份哪些照片' || win_phone_has "$1" '选择要备份的相册'; }

# 把相册网格滚到能看见目标相册（2 列网格，目标可能在下面几屏）。
scope_scroll_to() {
  local dump="$1" name="$2" i
  for i in $(seq 1 8); do
    win_phone_dump "$dump" || return 1
    scope_find "$dump" "$name" >/dev/null && return 0
    win_adb shell input swipe 540 1800 540 900 300 >/dev/null 2>&1
    sleep 1
  done
  return 1
}

# 只勾选目标相册：先把已勾选的其它相册点掉，再确保目标勾上。
scope_select_only() {
  local dump="$1" target="$2" name
  scope_scroll_to "$dump" "$target" || { echo "选范围：滚不到 $target"; return 1; }
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$name" = "$target" ] && continue
    local xy
    xy="$(scope_find "$dump" "$name")" || continue
    # shellcheck disable=SC2086
    win_adb shell input tap $xy >/dev/null 2>&1
    sleep 1
    win_phone_dump "$dump" || return 1
    scope_scroll_to "$dump" "$target" || return 1
  done < <(scope_selected "$dump")
  # 目标没勾上就点一下
  if ! scope_selected "$dump" | grep -qx "$target"; then
    local xy
    xy="$(scope_find "$dump" "$target")" || { echo "选范围：找不到 $target"; return 1; }
    # shellcheck disable=SC2086
    win_adb shell input tap $xy >/dev/null 2>&1
    sleep 1
    win_phone_dump "$dump" || return 1
  fi
  scope_selected "$dump" | grep -qx "$target"
}

setup() {
  win_phone_state | grep -qx device || { echo "adb 看不到手机 ${E3_ANDROID_SERIAL}"; return 77; }
  [ "$(win_phone_version)" = "$WIN_BASE_PHONE_VER" ] || { echo "手机不是基线 $WIN_BASE_PHONE_VER：$(win_phone_version)（先跑 win/install-baseline）"; return 77; }
  win_app_running || win_start_app || { echo "桌面 App 没起来"; return 1; }
  local i
  for i in $(seq 1 30); do win_daemon_running && break; sleep 1; done
  win_daemon_running || { echo "daemon 没起来"; return 1; }
  # 前提：桌面未配对（配过就先跑 install-baseline 重置）。
  win_diag "$E3_STATE/win/pair-precheck" >/dev/null 2>&1 || true
  local n
  n="$(win_json_array_len "$E3_STATE/win/pair-precheck/diag/devices.json")"
  [ "${n:-0}" = 0 ] || { echo "桌面已有 ${n} 台配对设备；本场景要求未配对（先跑 win/install-baseline）"; return 77; }

  # 素材：40 张，缺了就生成；手机端先清空 PPassRegression 再推，保证恰好 40。
  PHOTO_DIR="$E3_STATE/win/photos-$PHOTOS"
  if [ "$(ls "$PHOTO_DIR"/*.jpg 2>/dev/null | wc -l)" != "$PHOTOS" ]; then
    rm -rf "$PHOTO_DIR"
    win_ps_file "$WIN_SCN_DIR/gen-photos.ps1" -Out "$(cygpath -w "$PHOTO_DIR")" -Count "$PHOTOS" -Prefix PPR >/dev/null || { echo "生成测试照片失败"; return 1; }
  fi
  win_phone_stop
  win_adb shell rm -rf /sdcard/DCIM/PPassRegression >/dev/null 2>&1 || true
  win_phone_push_photos "$PHOTO_DIR" || { echo "推送测试照片失败"; return 1; }
  win_phone_grant
  win_phone_start
  BASE_COUNT="$(win_diag "$E3_STATE/win/pair-precheck" >/dev/null 2>&1 && win_status_field "$E3_STATE/win/pair-precheck" photo_count)"
  [ -n "$BASE_COUNT" ] || BASE_COUNT=0
  echo "备份前库内照片数：$BASE_COUNT"
}

act() {
  local d="$OUT" attempt
  # 配对走 iroh relay，偶发 15s 超时（本机实测过一次）；失败重开一次手机 App 再试。
  for attempt in 1 2; do
    win_pair "$d" && break
    [ "$attempt" = 2 ] && { echo "配对失败（已重试一次）"; return 1; }
    echo "配对第 $attempt 次失败，重试"
    win_phone_stop
    sleep 2
    win_phone_start
  done
  # 允许加入后手机还要过「正在连接」→ 选范围/首页，等它稳定再点。
  local i
  for i in $(seq 1 30); do
    win_phone_dump "$d/phone-postpair.xml" || return 1
    scope_screen "$d/phone-postpair.xml" && break
    win_phone_has "$d/phone-postpair.xml" '选择备份范围' && break
    sleep 1
  done
  if ! scope_screen "$d/phone-postpair.xml"; then
    win_phone_tap_xml "$d/phone-postpair.xml" '选择备份范围' || { echo "找不到选择备份范围"; return 1; }
    for i in $(seq 1 15); do
      sleep 1
      win_phone_dump "$d/phone-postpair.xml" || return 1
      scope_screen "$d/phone-postpair.xml" && break
    done
  fi
  scope_screen "$d/phone-postpair.xml" || { echo "没进入选相册页"; return 1; }
  scope_select_only "$d/phone-scope.xml" 'PPassRegression' || { echo "相册选择失败"; return 1; }
  scope_selected "$d/phone-scope.xml" >"$d/scope-selected.txt"
  cat "$d/scope-selected.txt"
  win_phone_tap_text "$d/phone-before-start.xml" '开始备份' || { echo "点不到开始备份"; return 1; }
  # 首次备份会弹「开启后台备份 / 不开启后台备份」；选不开启，保持测试机设置不变，
  # 本次备份照常在前台跑完。
  sleep 2
  win_phone_dump "$d/phone-after-start.xml" || true
  if win_phone_has "$d/phone-after-start.xml" '开启后台备份'; then
    win_phone_tap_xml "$d/phone-after-start.xml" '不开启后台备份' || true
    sleep 1
  fi

  local want=$((BASE_COUNT + PHOTOS)) ok=0 i
  for i in $(seq 1 100); do
    if win_diag "$d" 2>/dev/null; then
      [ "$(win_status_field "$d" photo_count)" = "$want" ] && { ok=1; break; }
    fi
    sleep 3
  done
  [ "$ok" = 1 ] || echo "等待备份完成超时（期望 $want）"
  win_diag "$d" || true
  win_library_hashes "$d" || true
  win_phone_hashes "$d/phone-hashes.txt" || true
  win_ui_dump "$d/desktop-main.txt" || true
  {
    echo "base_count=$BASE_COUNT"
    echo "expected=$want"
    echo "photo_count=$(win_status_field "$d" photo_count)"
    echo "devices=$(win_json_array_len "$d/diag/devices.json")"
    echo "library_count=$(win_library_count)"
  } >"$d/backup.txt"
}

# 每张手机照片的 sha256 都在库 originals 里恰好出现一次。
hash_reconcile() {
  local d="$1" missing=0 dup=0 h n
  [ -s "$d/phone-hashes.txt" ] || { echo "缺手机哈希清单"; return 1; }
  while read -r h _; do
    [ -n "$h" ] || continue
    n="$(grep -c "^$h " "$d/library-hashes.txt" 2>/dev/null || true)"
    [ "${n:-0}" -ge 1 ] || { missing=$((missing + 1)); echo "缺：$h"; }
    [ "${n:-0}" -gt 1 ] && { dup=$((dup + 1)); echo "重复：$h ×$n"; }
  done <"$d/phone-hashes.txt"
  echo "missing=$missing dup=$dup"
  [ "$missing" -eq 0 ] && [ "$dup" -eq 0 ]
}

judge() {
  local d="$1"
  check "桌面恰好 1 台配对设备" grep -qx 'devices=1' "$d/backup.txt"
  check "库内照片数 = 备份前 + 40" grep -qx "photo_count=$(sed -n 's/^expected=//p' "$d/backup.txt" | head -1)" "$d/backup.txt"
  check "手机 40 张的 sha256 全部入库且不重复" hash_reconcile "$d"
  check "只有 PPassRegression 被选" grep -qx 'PPassRegression' "$d/scope-selected.txt"
  check "没有选其它相册" [ "$(grep -c . "$d/scope-selected.txt")" = 1 ]
  check "daemon 日志无 panic" no_line "$d/diag/daemon.log" 'panicked|PANIC'
  verdict
}

counter() {
  local d="$OUT" victim rel
  # 故障条件：从 originals 删掉一张已入库的原图，再按同样规则对账 ⇒ 必须变红。
  victim="$(sed -n '1s/^[0-9a-f]*  //p' "$d/../main/library-hashes.txt")"
  [ -n "$victim" ] || victim="$(sed -n '1s/^[0-9a-f]*  //p' "$E3_STATE/win/pair-precheck/library-hashes.txt" 2>/dev/null)"
  if [ -z "$victim" ]; then
    # 没有主证据时现取一张
    win_library_hashes "$d" >/dev/null 2>&1 || true
    victim="$(sed -n '1s/^[0-9a-f]*  //p' "$d/library-hashes.txt")"
  fi
  rel="$victim"
  if [ -n "$rel" ]; then
    mkdir -p "$E3_STATE/win/counter-keep"
    cp "$(win_library_dir)/$rel" "$E3_STATE/win/counter-keep/victim.jpg"
    echo "$rel" >"$E3_STATE/win/counter-keep/rel.txt"
    rm -f "$(win_library_dir)/$rel"
  fi
  win_diag "$d" || true
  win_library_hashes "$d" || true
  win_phone_hashes "$d/phone-hashes.txt" || true
  cp "$d/../main/backup.txt" "$d/backup.txt" 2>/dev/null || true
  {
    echo "base_count=$(sed -n 's/^base_count=//p' "$d/backup.txt" 2>/dev/null)"
    echo "expected=$(sed -n 's/^expected=//p' "$d/backup.txt" 2>/dev/null)"
    echo "photo_count=$(win_status_field "$d" photo_count)"
    echo "devices=$(win_json_array_len "$d/diag/devices.json")"
  } >"$d/backup.txt"
  cp "$d/../main/scope-selected.txt" "$d/scope-selected.txt" 2>/dev/null || true
}

teardown() {
  if [ -f "$E3_STATE/win/counter-keep/rel.txt" ]; then
    local rel
    rel="$(cat "$E3_STATE/win/counter-keep/rel.txt")"
    cp "$E3_STATE/win/counter-keep/victim.jpg" "$(win_library_dir)/$rel" 2>/dev/null || true
    rm -rf "$E3_STATE/win/counter-keep"
  fi
  return 0
}
