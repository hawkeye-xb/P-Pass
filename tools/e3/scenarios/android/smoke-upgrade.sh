# 冒烟①②③（A-up）：基线包（上一版）配对候选 daemon 的 --ephemeral 桩、备份 N 张程序生成的图 →
# `install -r` 覆盖装候选包 → 不用重新配对、前台不崩、再推 2 张也备份上；两端计数一致；logcat 无 FATAL。
#
# 基线包 = merge-base(HEAD, origin/main) 的 debug 包（同一把本机 debug 签名才能覆盖安装；run-as 也只认 debug 包），
# 由 just verify 编好并缓存；也可 E3_ANDROID_BASE_APK 指定。
# 反证：升级后 pm clear（抹掉配对与账本）再开 App ⇒ 必须判红（回到欢迎页、手机侧计数为 0）。
# #1412：素材只进专用测试相册、范围只勾它（读回存下的范围作判据）——手机相机相册里有当天的真实照片也不影响计数。
DESC="上一版→候选覆盖升级：配对仍在、不崩、两端计数一致、无 FATAL"
COUNTER=off
N="${E3_ANDROID_N:-6}"
TAG="E3S"

setup() {
  local base cand
  base=$(base_apk)
  cand=$(cand_apk)
  [ -f "$base" ] || { echo "缺基线包：${base}（just verify 会编；或 E3_ANDROID_BASE_APK=…）"; return 1; }
  [ -f "$cand" ] || { echo "缺候选包（apps/android 的 assembleDebug 产物；或 E3_ANDROID_APK=…）"; return 1; }
  [ -x "$(cand_daemon)" ] || { echo "缺候选 daemon：$(cand_daemon)"; return 1; }
  # 清掉所有场景推过的测试素材（包括视频场景留下的那段、种子图），计数才只算本场景推的
  rm_photos "PPR_"
  # 第一批先推：测试相册要有图才出现在选范围页（范围「从今天起」按入库时间算，当天推的在范围内）
  gen_photos "$E3_STATE/photos-$TAG" "$N" "${TAG}a"
  push_photos "$E3_STATE/photos-$TAG"
  album_wait "$N" || { echo "测试相册没入库 $N 张"; return 1; }
  eph_start "$(cand_daemon)"
  install_fresh "$base"
  pkg_info >"$EV/base-pkg.txt"
  logcat_clear
  pair_with_stub "$EV" || { echo "配对没走完（或备份范围不是只有测试相册，见 run.log）"; return 1; }
  eph_wait_count "$N" 240 || { echo "基线包没把 $N 张备份上"; return 1; }
  eph_ipc status >"$EV/base-stub-status.json"
}

# 手机侧「已备份」数：debug 包的备份账本 backup-orders.db 里 CONFIRMED、源文件还在的不同内容数
# （连同 -wal 一起拉，否则读不到还没 checkpoint 的行）
phone_done_count() {
  local f db="$E3_STATE/orders.db"
  rm -f "$db" "$db-wal" "$db-shm"
  for f in "" -wal -shm; do
    A exec-out run-as "$PKG" cat "databases/backup-orders.db$f" >"$db$f" 2>/dev/null
    [ -s "$db$f" ] || rm -f "$db$f"
  done
  sqlite3 "$db" "select count(distinct content_hash) from orders where state='CONFIRMED' and source_missing=0" 2>/dev/null
}

collect() {
  pkg_info >"$OUT/pkg.txt"
  app_pid >"$OUT/pid.txt"
  ui_dump "$OUT/home.xml"
  ui_texts "$OUT/home.xml" >"$OUT/home.txt"
  shot "$OUT/home.png"
  eph_ipc status >"$OUT/stub-status.json"
  eph_ipc devices.list >"$OUT/stub-devices.json"
  phone_done_count >"$OUT/phone-count.txt"
  app_scope_ids >"$OUT/scope.txt"
  album_bucket_id >"$OUT/album-bucket.txt"
  eph_sql "select rel_path from asset order by rel_path" >"$OUT/stub-assets.txt" 2>/dev/null || true
  echo $((N + 2)) >"$OUT/expected.txt"
  logcat_save "$OUT/logcat.txt"
  cp "$EV/base-pkg.txt" "$OUT/base-pkg.txt"
  cp "$EPH_STATE/d.log" "$OUT/stub-daemon.log"
}

act() {
  A install -r "$(cand_apk)" >"$OUT/install.txt" 2>&1
  app_start
  sleep 3
  dismiss_update
  gen_photos "$E3_STATE/photos-$TAG-b" 2 "${TAG}b"
  push_photos "$E3_STATE/photos-$TAG-b"
  eph_wait_count $((N + 2)) 240
  sleep 3
  collect
}

judge() {
  local d="$1" got phone scope album
  got=$(jget "$d/stub-status.json" 'j["result"]["photo_count"]')
  phone=$(tr -d '[:space:]' <"$d/phone-count.txt" 2>/dev/null)
  scope=$(tr -d '[:space:]' <"$d/scope.txt" 2>/dev/null)
  album=$(tr -d '[:space:]' <"$d/album-bucket.txt" 2>/dev/null)
  check "覆盖安装成功" has_line "$d/install.txt" 'Success'
  check "是升级不是重装（firstInstallTime 不变）" same_first_install "$d"
  check "App 进程在（前台不崩）" [ -n "$(tr -d '[:space:]' <"$d/pid.txt" 2>/dev/null)" ]
  check "升级后没回到欢迎页（配对仍在）" no_line "$d/home.txt" '扫码连接电脑'
  check "备份范围只含测试相册（[$scope] / ${album}）" same_nonempty "$scope" "$album"
  check "桩里照片数 = 推送数（$got / $(cat "$d/expected.txt")）" [ "$got" = "$(cat "$d/expected.txt")" ]
  check "手机账本已确认数 = 桩里照片数（$phone / ${got}）" [ "$phone" = "$got" ]
  check "logcat 无 FATAL" no_line "$d/logcat.txt" 'FATAL EXCEPTION'
  check "桩日志无 panic" no_line "$d/stub-daemon.log" 'panicked|PANIC'
  verdict
}

same_nonempty() { [ -n "$2" ] && [ "$1" = "$2" ]; }

same_first_install() {
  local a b
  a=$(sed -n 's/^firstInstallTime=//p' "$1/base-pkg.txt" | head -1)
  b=$(sed -n 's/^firstInstallTime=//p' "$1/pkg.txt" | head -1)
  [ -n "$a" ] && [ "$a" = "$b" ]
}

counter() {
  cp "$EV/main/install.txt" "$OUT/"
  app_stop
  A shell pm clear "$PKG" >/dev/null
  app_start
  sleep 4
  collect
}

teardown() {
  rm_photos "PPR_$TAG"
  # 桩留给同一次 run 的后续场景；run 结束由 just verify 停
}
