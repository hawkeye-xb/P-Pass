# A-P3：视频点了才下。在视频页左右翻页时桩几乎不上行；点「播放」后桩上行 ≥ 视频大小、手机日志
# play tapped → space ok, fetching → fetched in。证据 = 桩进程上行字节（macOS nettop）+ 手机日志。
# 反证（--counter）：在「只浏览」窗口里点一次播放 ⇒「浏览时不下载」必须判红。
DESC="视频页浏览不下载、点播放才下（nettop 量桩上行 + 手机日志）"
COUNTER=off
source "$E3_LIB/android-video.sh"

setup() { setup_video; }

out_bytes() { nettop -p "$(cat "$EPH_STATE/pid")" -P -L 1 -J bytes_out -x 2>/dev/null | awk -F, 'NR==2{print $2+0}'; }

run_once() { # <浏览期间是否点播放 0|1>
  local b0 b1 b2 r
  app_stop
  runas rm -rf cache
  logcat_clear
  open_video browse || { echo "没进视频页"; return 1; }
  b0=$(out_bytes)
  [ "$1" = 1 ] && fg_guard && tap_xy "$(ui_find '播放')" && sleep 8
  for r in 1 2 3; do
    fg_guard && A shell input swipe 900 1200 150 1200 250
    sleep 5
    fg_guard && A shell input swipe 150 1200 900 1200 250
    sleep 5
  done
  b1=$(out_bytes)
  A logcat -d -v threadtime >"$OUT/logcat-browse.txt"
  open_video play || { echo "没回到视频页"; return 1; }
  b2=$(out_bytes)
  tap_play play
  sleep 3
  echo $((b1 - b0)) >"$OUT/browse-bytes.txt"
  echo $(($(out_bytes) - b2)) >"$OUT/play-bytes.txt"
  echo "$VSZ" >"$OUT/video-bytes.txt"
  A logcat -d -v threadtime >"$OUT/logcat-play.txt"
}

act() { run_once 0; }

judge() {
  local d="$1" v
  v=$(cat "$d/video-bytes.txt" 2>/dev/null)
  check "视频页显示「播放」入口" has_line "$d/browse-cover.txt" '播放'
  check "浏览时没有 play tapped" no_line "$d/logcat-browse.txt" 'PPassVideo.*play tapped'
  check "浏览时桩上行 < 视频的 1/10（$(cat "$d/browse-bytes.txt") B）" num "$d/browse-bytes.txt" -lt $((v / 10))
  check "点播放后桩上行 ≥ 视频大小（$(cat "$d/play-bytes.txt") / $v B）" num "$d/play-bytes.txt" -ge "$v"
  check "手机日志 fetched in … playing" has_line "$d/logcat-play.txt" 'PPassVideo.*fetched in'
  check "logcat 无 FATAL" no_line "$d/logcat-play.txt" 'FATAL EXCEPTION'
  verdict
}

counter() { run_once 1; }
