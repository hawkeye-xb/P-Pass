# A-P3 / A-P5 共用：推一段今天日期的视频进相册、等它备份进桩，拿到它在桩索引里的 hash 与声明大小。
# shellcheck shell=bash
VNAME="PPR_E3V_vid.mp4"

# setup_video：配对 + 推视频 + 等入库；设 VH（hash 小写十六进制）、VSZ（索引里的 bytes）
setup_video() {
  local i
  ensure_paired "$EV" || { echo "配对没走完"; return 1; }
  VH=$(eph_sql "select lower(hex(hash)) from asset where rel_path like '%$VNAME'")
  if [ -z "$VH" ]; then
    mkdir -p "$E3_STATE/video"
    ffmpeg -loglevel error -y -f lavfi -i testsrc2=size=1280x720:rate=30 -t 8 -c:v libx264 -b:v 5M \
      -pix_fmt yuv420p -movflags +faststart "$E3_STATE/video/$VNAME" || return 1
    push_photos "$E3_STATE/video"
    for i in $(seq 1 60); do
      sleep 4
      VH=$(eph_sql "select lower(hex(hash)) from asset where rel_path like '%$VNAME'")
      [ -n "$VH" ] && break
    done
  fi
  [ -n "$VH" ] || { echo "视频没进桩"; return 1; }
  VSZ=$(eph_sql "select bytes from asset where lower(hex(hash))='$VH'")
  echo "视频 hash=${VH:0:16} bytes=$VSZ"
}

# open_video <证据前缀>：重开 App → 网格里点这段视频 → 进视频页；成功返回 0
open_video() {
  local xy
  reopen
  wait_text "${VH:0:8}" 30 || true
  xy=$(ui_find "${VH:0:8}") || xy=$(first_cell_xy) || return 1
  fg_guard && tap_xy "$xy"
  wait_text "播放" 15 || return 1
  ui_dump "$OUT/$1-cover.xml"
  ui_texts "$OUT/$1-cover.xml" >"$OUT/$1-cover.txt"
  shot "$OUT/$1-cover.png"
}
# tap_play <证据前缀>：点「播放」，等手机出结论日志，采集
tap_play() {
  local i
  fg_guard && tap_xy "$(ui_find '播放')"
  for i in $(seq 1 40); do
    sleep 1
    A logcat -d | grep -q 'PPassVideo.*\(fetched in\|fetch failed\|fetch stopped\|not fetched\|more data than declared\|grew past\)' && break
  done
  sleep 2
  ui_dump "$OUT/$1-after.xml"
  ui_texts "$OUT/$1-after.xml" >"$OUT/$1-after.txt"
  shot "$OUT/$1-after.png"
  fg_guard && A shell input keyevent BACK
  sleep 1
}
