# A-P5：原片实际大小超过声明 → 手机收到超出部分立即中止、提示「无法获取视频」、不播放。
# 注入：原片不动，把桩索引里该视频的声明大小 bytes 改成一半（test.2 回归实测：给原片追加字节的注入无效，
# 桩监视 originals、文件一改就重新入库成新资产，声明随之等于实际）。日志 declared= 证明注入生效。
# 反证：改回 bytes 后同一段能正常拉取播放 ⇒ judge 判红。
DESC="视频实际大于声明时中止、提示失败、不播放；改回后能播（注入类，带反证）"
COUNTER=on
source "$E3_LIB/android-video.sh"

setup() { setup_video; }

play_once() {
  # 已下载的原片会被直接命中、绕过声明校验：每次先清 App 的缓存目录（缓存可随时丢）
  app_stop
  runas rm -rf cache
  logcat_clear
  open_video play || { echo "没进视频页"; return 1; }
  tap_play play
  logcat_save "$OUT/logcat.txt"
  echo "$VSZ" >"$OUT/full-bytes.txt"
  echo "$1" >"$OUT/declared-expected.txt"
}

act() {
  eph_sql "update asset set bytes=$((VSZ / 2)) where lower(hex(hash))='$VH'"
  eph_sql "select bytes from asset where lower(hex(hash))='$VH'" >"$OUT/index-bytes.txt"
  play_once $((VSZ / 2))
}

judge() {
  local d="$1"
  check "手机拿到的声明大小 = 本轮索引值（$(cat "$d/declared-expected.txt" 2>/dev/null)）" \
    has_line "$d/logcat.txt" "play tapped, declared=$(cat "$d/declared-expected.txt" 2>/dev/null)\$"
  check "收到超出声明的数据即中止" has_line "$d/logcat.txt" 'more data than declared|grew past its declared|OriginalExceedsDeclaredSize'
  check "页面提示「无法获取视频」" has_line "$d/play-after.txt" '无法获取视频'
  check "没有播放（无 fetched in）" no_line "$d/logcat.txt" 'PPassVideo.*fetched in'
  check "logcat 无 FATAL" no_line "$d/logcat.txt" 'FATAL EXCEPTION'
  verdict
}

counter() {
  eph_sql "update asset set bytes=$VSZ where lower(hex(hash))='$VH'"
  play_once "$VSZ"
  # 反证要看到的是「正常播放」：把还原后的结论写进证据，judge 因声明=全量、无中止而判红
  grep -c 'PPassVideo.*fetched in' "$OUT/logcat.txt" >"$OUT/fetched-count.txt"
}

teardown() { [ -n "${VH:-}" ] && [ -n "${VSZ:-}" ] && eph_sql "update asset set bytes=$VSZ where lower(hex(hash))='$VH'"; return 0; }
