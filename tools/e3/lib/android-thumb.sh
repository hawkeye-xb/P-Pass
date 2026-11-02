# A-P1 / A-P2 共用：桩返回坏缩略图（非 JPEG / 超尺寸）时手机拒收、显示「无法显示预览」、不崩。
# 注入只改桩自己沙盒里的缩略图缓存（桩命中缓存就原样回字节），绝不碰真实库。
# 场景文件设 KIND=png|big 后 source 本文件。
# shellcheck shell=bash
COUNTER=on

thumbs_root() {
  local d
  d=$(eph_db)
  d="${d%/index.sqlite}/thumbs"
  case "$d" in "$(eph_sandbox)"-local/*) [ -d "$d" ] && echo "$d" ;; *) return 1 ;; esac
}
mkpng() { python3 -I - "$1" <<'PY'
import sys, zlib, struct
def ch(t, d):
    c = struct.pack(">I", len(d)) + t + d
    return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
w = h = 256
raw = b"".join(b"\0" + b"\x80\x40\xc0" * w for _ in range(h))
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + ch(b"IDAT", zlib.compress(raw)) + ch(b"IEND", b""))
PY
}
# 4000x3000 的真 JPEG（宽高 > 1024）
mkbig() {
  local t="$E3_STATE/big.png"
  python3 -I - "$t" <<'PY'
import sys, zlib, struct
def ch(t, d):
    c = struct.pack(">I", len(d)) + t + d
    return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
w, h = 4000, 3000
raw = (b"\0" + b"\x30\x90\x60" * w) * h
open(sys.argv[1], "wb").write(b"\x89PNG\r\n\x1a\n" + ch(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + ch(b"IDAT", zlib.compress(raw, 1)) + ch(b"IEND", b""))
PY
  sips -s format jpeg "$t" --out "$1" >/dev/null 2>&1
}
pss() { A shell dumpsys meminfo "$PKG" | awk '/TOTAL PSS:|TOTAL:/{print $3; exit}'; }

setup() {
  ensure_paired "$EV" || { echo "配对没走完"; return 1; }
  ensure_photos 3 E3T || { echo "桩里没有照片"; return 1; }
  reopen
  sleep 5
  thumbs_root >/dev/null || { echo "桩里还没生成缩略图"; return 1; }
  BAK="$E3_STATE/thumb-bak"
  rm -rf "$BAK"
  mkdir -p "$BAK"
  (cd "$(thumbs_root)" && find . -name '*.jpg' | while read -r f; do mkdir -p "$BAK/$(dirname "$f")"; cp -p "$f" "$BAK/$f"; done)
  [ -n "$(find "$BAK" -name '*.jpg' | head -1)" ] || { echo "缩略图缓存为空"; return 1; }
}

inject() {
  local f
  find "$(thumbs_root)" -name '*.jpg' | while read -r f; do
    if [ "$KIND" = png ]; then mkpng "$f"; else mkbig "$f"; fi
    echo "$f $(stat -f %z "$f")B $(head -c4 "$f" | xxd -p)"
  done
}
restore() { (cd "$BAK" && find . -name '*.jpg' | while read -r f; do cp -p "$f" "$(thumbs_root)/$f"; done); }

# 重开 → 网格 → 点第一格看大图 → 采集
observe() {
  local xy
  pss >"$OUT/pss-before.txt"
  logcat_clear
  reopen
  app_pid >"$OUT/pid-before.txt"
  sleep 4
  ui_dump "$OUT/grid.xml"
  shot "$OUT/grid.png"
  xy=$(first_cell_xy) && fg_guard && tap_xy "$xy"
  sleep 4
  ui_dump "$OUT/viewer.xml"
  ui_texts "$OUT/viewer.xml" >"$OUT/viewer.txt"
  shot "$OUT/viewer.png"
  fg_guard && A shell input keyevent BACK
  sleep 2
  app_pid >"$OUT/pid-after.txt"
  pss >"$OUT/pss-after.txt"
  logcat_save "$OUT/logcat.txt"
  echo "$KIND" >"$OUT/kind.txt"
}

act() { inject >"$OUT/inject.txt"; observe; }

judge() {
  local d="$1" want
  [ "$(cat "$d/kind.txt" 2>/dev/null)" = png ] && want=NotJpeg || want=TooLarge
  check "手机拒收缩略图（PPassThumb rejected: ${want}）" has_line "$d/logcat.txt" "PPassThumb.*rejected: $want"
  check "大图页显示「无法显示预览」" has_line "$d/viewer.txt" '无法显示预览'
  check "logcat 无 FATAL" no_line "$d/logcat.txt" 'FATAL EXCEPTION'
  check "进程没换（不崩）" same_pid "$d"
  if [ "$want" = TooLarge ]; then check "内存增量 < 100MB" pss_ok "$d"; fi
  verdict
}
same_pid() { local a; a=$(tr -d '[:space:]' <"$1/pid-before.txt"); [ -n "$a" ] && [ "$a" = "$(tr -d '[:space:]' <"$1/pid-after.txt")" ]; }
pss_ok() { local a b; a=$(cat "$1/pss-before.txt"); b=$(cat "$1/pss-after.txt"); [ -n "$a" ] && [ -n "$b" ] && [ $(((b - a) / 1024)) -lt 100 ]; }

# 反证：还原缓存后同一流程必须不再出现拒收/「无法显示预览」⇒ judge 判红
counter() { restore; observe; }
teardown() { [ -d "${BAK:-}" ] && restore; return 0; }
