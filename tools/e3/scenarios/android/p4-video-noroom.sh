# A-P4：手机剩余空间不够放这段视频时点播放 → 提示空间不足、不下载、不崩。
# 判定线（VideoPlayback.kt）：可分配空间 < 声明×2 + 64MB ⇒ NoRoom。
# 注入：把桩索引里该视频的声明大小改成 1TB（远超手机剩余），不用真去占满手机存储（test.2 回归是 fallocate
# 占位到只剩几 GB，风险大、恢复慢）；原片不动。
# 反证：改回真实大小 ⇒ 日志变成 space ok, fetching、能播放 ⇒ judge 判红。
DESC="手机空间不够时点播放：提示空间不足、不下载、不崩；改回后能播（注入类，带反证）"
COUNTER=on
source "$E3_LIB/android-video.sh"
HUGE=1099511627776

setup() { setup_video; }

play_once() {
  app_stop
  runas rm -rf cache
  logcat_clear
  open_video play || { echo "没进视频页"; return 1; }
  tap_play play
  logcat_save "$OUT/logcat.txt"
  echo "$1" >"$OUT/declared-expected.txt"
}

act() {
  eph_sql "update asset set bytes=$HUGE where lower(hex(hash))='$VH'"
  play_once "$HUGE"
}

judge() {
  local d="$1"
  check "手机拿到的声明大小 = 本轮索引值（$(cat "$d/declared-expected.txt" 2>/dev/null)）" \
    has_line "$d/logcat.txt" "play tapped, declared=$(cat "$d/declared-expected.txt" 2>/dev/null)\$"
  check "判空间不足、不下载（not fetched: needs …）" has_line "$d/logcat.txt" 'PPassVideo.*not fetched: needs'
  check "页面提示空间不足" has_line "$d/play-after.txt" '空间不足'
  check "没有开始下载（无 space ok / fetched in）" no_line "$d/logcat.txt" 'PPassVideo.*(space ok|fetched in)'
  check "logcat 无 FATAL" no_line "$d/logcat.txt" 'FATAL EXCEPTION'
  verdict
}

counter() {
  eph_sql "update asset set bytes=$VSZ where lower(hex(hash))='$VH'"
  play_once "$VSZ"
}

teardown() { [ -n "${VH:-}" ] && [ -n "${VSZ:-}" ] && eph_sql "update asset set bytes=$VSZ where lower(hex(hash))='$VH'"; return 0; }
