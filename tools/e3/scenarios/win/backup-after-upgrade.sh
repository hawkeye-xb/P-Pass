# R1.5：升级到候选后再 push 8 张，只增量入库 8 张、不重复入库。
#
# 前提：win/upgrade-candidate 已把两端升到候选、且配对与 40 张仍在。
# 反证：不触发这次备份（用升级后、push 前的真实快照 + 这 8 张的哈希）对账 ⇒ 8 张必须
# 全部报「缺」，判据变红；不动库、不降级。
DESC="R1.5：升级后再 push 8 张，增量备份恰好 +8、不重复"
COUNTER=on
EXTRA=8

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

snapshot() { # snapshot <目录> <前缀>
  local d="$1" p="$2"
  win_diag "$d" || true
  cp "$d/diag/status.json" "$d/$p-status.json" 2>/dev/null || true
  cp "$d/diag/daemon.log" "$d/$p-daemon.log" 2>/dev/null || true
  win_library_hashes "$d" >/dev/null 2>&1 || true
  cp "$d/library-hashes.txt" "$d/$p-library-hashes.txt" 2>/dev/null || true
  {
    echo "photo_count=$(win_status_field "$d" photo_count)"
    echo "status_version=$(win_status_field "$d" version)"
    echo "phone_version=$(win_phone_version)"
  } >"$d/$p-versions.txt"
}

setup() {
  win_app_running || { echo "桌面 App 没在跑（先跑 win/upgrade-candidate）"; return 77; }
  win_daemon_running || { echo "daemon 没在跑（先跑 win/upgrade-candidate）"; return 77; }
  [ "$(win_app_version)" = "$WIN_CAND_VER" ] || { echo "桌面不是候选 ${WIN_CAND_VER}：$(win_app_version)"; return 77; }
  [ "$(win_phone_version)" = "$WIN_CAND_VER" ] || { echo "手机不是候选 ${WIN_CAND_VER}：$(win_phone_version)"; return 77; }
  EXTRA_DIR="$E3_STATE/win/photos-extra-$EXTRA"
  if [ "$(ls "$EXTRA_DIR"/*.jpg 2>/dev/null | wc -l)" != "$EXTRA" ]; then
    rm -rf "$EXTRA_DIR"
    win_ps_file "$WIN_SCN_DIR/gen-photos.ps1" -Out "$(cygpath -w "$EXTRA_DIR")" -Count "$EXTRA" -Prefix PPRU >/dev/null || { echo "生成增量照片失败"; return 1; }
  fi
  echo "--- 增量前快照 ---"
  snapshot "$EV/main" pre
  cat "$EV/main/pre-versions.txt"
  win_phone_push_photos "$EXTRA_DIR" || { echo "推送增量照片失败"; return 1; }
  sleep 2
}

act() {
  local d="$OUT" want base i
  snapshot "$d" pre
  base="$(grep -o '^photo_count=[0-9]*' "$d/pre-versions.txt" | cut -d= -f2)"
  want=$((base + EXTRA))
  # 打开 App 触发扫描/备份；有「立即备份」就点。首次会弹后台备份提示，选不开启。
  win_phone_stop
  sleep 1
  win_phone_start
  win_phone_dump "$d/phone-home.xml" || true
  if win_phone_has "$d/phone-home.xml" '立即备份'; then
    win_phone_tap_xml "$d/phone-home.xml" '立即备份' || true
  elif win_phone_has "$d/phone-home.xml" '开始备份'; then
    win_phone_tap_xml "$d/phone-home.xml" '开始备份' || true
  fi
  sleep 2
  win_phone_dump "$d/phone-after-trigger.xml" || true
  if win_phone_has "$d/phone-after-trigger.xml" '开启后台备份'; then
    win_phone_tap_xml "$d/phone-after-trigger.xml" '不开启后台备份' || true
  fi
  for i in $(seq 1 60); do
    if win_diag "$d" 2>/dev/null; then
      [ "$(win_status_field "$d" photo_count)" = "$want" ] && break
    fi
    sleep 3
  done
  snapshot "$d" post
  {
    echo "base_count=$base"
    echo "expected=$want"
    echo "photo_count=$(win_status_field "$d" photo_count)"
  } >"$d/backup.txt"
  # 本机生成的 8 张的哈希（与手机上的文件同字节）
  sha256sum "$EXTRA_DIR"/*.jpg | awk '{print $1}' | sort >"$d/extra-hashes.txt"
}

hash_extra() {
  local d="$1" h n missing=0 dup=0
  while read -r h; do
    [ -n "$h" ] || continue
    n="$(grep -c "^$h " "$d/post-library-hashes.txt" 2>/dev/null || true)"
    [ "${n:-0}" -ge 1 ] || { missing=$((missing + 1)); echo "缺：$h"; }
    [ "${n:-0}" -gt 1 ] && { dup=$((dup + 1)); echo "重复：$h ×$n"; }
  done <"$d/extra-hashes.txt"
  echo "missing=$missing dup=$dup"
  [ "$missing" -eq 0 ] && [ "$dup" -eq 0 ]
}

photo_count_matches() { grep -qx "photo_count=$(sed -n 's/^expected=//p' "$1" | head -1)" "$1"; }

judge() {
  local d="$1" pre_n post_n
  pre_n=$(grep -c . "$d/pre-library-hashes.txt" 2>/dev/null || echo 0)
  post_n=$(grep -c . "$d/post-library-hashes.txt" 2>/dev/null || echo 0)
  check "照片数 = 增量前 + 8" photo_count_matches "$d/backup.txt"
  check "8 张全部增量入库且不重复" hash_extra "$d"
  check "库哈希清单 = 增量前 + 8 行（原有照片仍在、不重复）" [ "$post_n" -eq "$((pre_n + 8))" ]
  check "两端仍是候选版本" grep -qx "status_version=$WIN_CAND_VER" "$d/post-versions.txt"
  check "手机仍是候选版本" grep -qx "phone_version=$WIN_CAND_VER" "$d/post-versions.txt"
  check "daemon 日志无 panic" no_line_panic "$d/post-daemon.log"
  verdict
}

counter() {
  local d="$OUT"
  # 去掉触发条件：push 后不打开 App / 不备份。用 push 前的真实库哈希 + 这 8 张的哈希。
  echo "counter: 不触发升级后的增量备份（使用增量前快照）" >"$d/note.txt"
  cp "$EV/main/pre-status.json" "$d/post-status.json" 2>/dev/null || true
  cp "$EV/main/pre-daemon.log" "$d/post-daemon.log" 2>/dev/null || true
  cp "$EV/main/pre-versions.txt" "$d/post-versions.txt"
  cp "$EV/main/pre-library-hashes.txt" "$d/post-library-hashes.txt"
  sha256sum "$EXTRA_DIR"/*.jpg | awk '{print $1}' | sort >"$d/extra-hashes.txt"
  cp "$EV/main/backup.txt" "$d/backup.txt" 2>/dev/null || true
}

teardown() { return 0; }
