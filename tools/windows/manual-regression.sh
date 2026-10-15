#!/usr/bin/env bash
# 人工主导的 Windows 全量回归：人按 docs/runbook/manual-regression-windows.md 一步步操作，
# agent 在每一步之后用本脚本取证。只读取状态、只往手机测试相册里放 agent 生成的图片，
# 不改动产品状态。
#
#   tools/windows/manual-regression.sh push <批次名> <起始序号> <张数>   生成测试图并推到手机 DCIM/PPassRegression
#   tools/windows/manual-regression.sh snap <步骤号>                     取一次证（写进 $WORK/<步骤号>/）
#   tools/windows/manual-regression.sh reconcile                         逐张 sha256 对账
#
# 工作目录：$WORK（默认 %USERPROFILE%\ppcheck\manual）。手机：adb 只连一台。
set -uo pipefail
export MSYS_NO_PATHCONV=1
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${WORK:-$(cygpath -u "$USERPROFILE")/ppcheck/manual}"
mkdir -p "$WORK/img"
PY="${PY:-python}"
APPDIR="$(cygpath -u "$LOCALAPPDATA")/com.p-pass.desktop"
CONF="$APPDIR/config.toml"
PKG=com.hawkeyexb.ppass

# Windows 上 python3 常是商店占位程序；ipc-lib.sh 调 python3，给它一个指向真解释器的 shim。
SHIM="$WORK/.shim"; mkdir -p "$SHIM"
if [ ! -x "$SHIM/python3" ]; then
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$(command -v "$PY")" > "$SHIM/python3"; chmod +x "$SHIM/python3"
fi
export PATH="$SHIM:$PATH"

data_dir() {
  [ -f "$CONF" ] || return 1
  cygpath -u "$(sed -n "s/^data_dir *= *[\"']\(.*\)[\"']\$/\1/p" "$CONF" | sed 's/\\\\/\\/g')"
}

ipc_ready() {
  local d; d=$(data_dir) || return 1
  [ -f "$d/ipc.token" ] || return 1
  SOCK=$(sed -n 1p "$d/ipc.token" | tr -d '\r'); TOKEN=$(sed -n 2p "$d/ipc.token" | tr -d '\r')
  export SOCK TOKEN   # ipc-lib.sh 读这两个
  # shellcheck source=/dev/null
  source "$REPO_ROOT/tools/ipc-lib.sh"
}

cmd_push() {
  local name=$1 start=$2 n=$3 dir="$WORK/img/$1"
  "$PY" - "$dir" "$name" "$start" "$n" <<'EOF'
import sys, os, random
from PIL import Image, ImageDraw
out, prefix, start, n = sys.argv[1], "REG", int(sys.argv[3]), int(sys.argv[4])
os.makedirs(out, exist_ok=True)
for i in range(start, start + n):
    r = random.Random(f"{prefix}-{i}-{os.urandom(4).hex()}")
    im = Image.new("RGB", (1600, 1200), tuple(r.randrange(256) for _ in range(3)))
    d = ImageDraw.Draw(im)
    for _ in range(40):
        x, y = r.randrange(1600), r.randrange(1200)
        d.rectangle([x, y, x + r.randrange(50, 400), y + r.randrange(50, 300)], fill=tuple(r.randrange(256) for _ in range(3)))
    d.text((40, 40), f"{prefix} #{i} {os.urandom(8).hex()}", fill=(255, 255, 255))
    im.save(os.path.join(out, f"{prefix}_{i:04d}.jpg"), quality=90)
EOF
  (cd "$dir" && sha256sum ./*.jpg > "$WORK/img/$name.sha256")
  adb shell mkdir -p /sdcard/DCIM/PPassRegression
  (cd "$dir" && adb push . /sdcard/DCIM/PPassRegression/ | tail -1)
  for f in "$dir"/*.jpg; do
    adb shell am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE \
      -d "file:///sdcard/DCIM/PPassRegression/$(basename "$f")" >/dev/null
  done
  echo "pushed $n ($name): $(wc -l < "$WORK/img/$name.sha256") hashes recorded"
}

cmd_reconcile() {
  local d; d=$(data_dir) || { echo "no config.toml"; return 1; }
  cat "$WORK"/img/*.sha256 2>/dev/null | awk '{print $1}' | sort > "$WORK/exp.hashes"
  find "$d/originals" -type f -name 'REG_*' -print0 2>/dev/null | xargs -0 -r sha256sum | awk '{print $1}' | sort > "$WORK/lib.hashes"
  echo "expected=$(wc -l < "$WORK/exp.hashes") library=$(wc -l < "$WORK/lib.hashes") uniq=$(sort -u "$WORK/lib.hashes" | wc -l)" \
       "missing=$(comm -23 "$WORK/exp.hashes" "$WORK/lib.hashes" | wc -l) extra=$(comm -13 "$WORK/exp.hashes" "$WORK/lib.hashes" | wc -l)"
}

cmd_snap() {
  local step=$1 out="$WORK/$1"; mkdir -p "$out"
  {
    echo "== $step @ $(date '+%F %T')"
    echo "-- desktop processes"; powershell -NoProfile -Command \
      "Get-Process p-pass-desktop,ppf-daemon -ErrorAction SilentlyContinue | ForEach-Object { \"\$(\$_.Name) pid=\$(\$_.Id) start=\$(\$_.StartTime.ToString('HH:mm:ss')) \$(\$_.Path)\" }"
    # 注册表必须在 MSIX 沙盒外读：沙盒里看到的是包私有的虚拟残留（SOP §9.0）。
    # 常驻服务是计划任务 P-Pass（#957）；Run 值只应在老版本上出现，迁移后消失。
    echo "-- installed version / scheduled task / legacy Run value (real registry)"
    powershell -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$REPO_ROOT/tools/windows/run-outside-package.ps1")" \
      -Cmd 'reg query HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\P-Pass /v DisplayVersion 2>nul & schtasks /query /tn P-Pass /fo csv /nh 2>nul & reg query HKCU\Software\Microsoft\Windows\CurrentVersion\Run /v P-Pass 2>nul' \
      | grep -E 'DisplayVersion|P-Pass +REG_SZ|"\\P-Pass"' || echo "not installed / no task / no Run value"
    echo "-- data dir"; find "$APPDIR" -maxdepth 1 -mindepth 1 -printf '%f ' 2>/dev/null; echo
    if ipc_ready; then
      echo "-- ipc status"; ipc status | "$PY" -c "import json,sys;r=json.load(sys.stdin).get('result',{});print({k:r.get(k) for k in ('version','state','photo_count','pid','exe_path')})"
      echo "-- devices"; ipc devices.list | "$PY" -c "import json,sys;[print(d['name'],d['node_id'][:8],'revoked=',d['revoked'],d.get('revoked_by'),'presence=',d['presence'],'conn=',d['connection']) for d in json.load(sys.stdin)['result']['devices']]"
      echo "-- reconcile"; cmd_reconcile
    else
      echo "-- daemon IPC not reachable (no config / token yet, or daemon down)"
    fi
    echo "-- phone"
    adb shell dumpsys package $PKG 2>/dev/null | grep -m1 versionName || echo "app not installed"
    echo "test photos on phone: $(adb shell "content query --uri content://media/external/images/media --projection _id --where \"relative_path='DCIM/PPassRegression/'\"" | grep -c Row)"
    adb shell dumpsys activity services $PKG 2>/dev/null | grep -m3 -E "ServiceRecord|isForeground"
  } 2>&1 | tee "$out/state.txt"
  # 完整日志另存，不打屏
  local uid; uid=$(adb shell pm list packages -U $PKG 2>/dev/null | grep -o 'uid:[0-9]*' | cut -d: -f2 | tr -d '\r')
  : > "$out/logcat.txt"
  [ -n "$uid" ] && adb logcat -d --uid="$uid" > "$out/logcat.txt" 2>/dev/null
  cp "$APPDIR/logs/daemon.log" "$out/daemon.log" 2>/dev/null
  cp "$APPDIR/logs/daemon.err" "$out/daemon.err" 2>/dev/null
  adb exec-out uiautomator dump /dev/tty 2>/dev/null | grep -o 'text="[^"]\+"' | sed 's/^text=//' > "$out/phone-screen.txt"
  echo "saved to $out (logcat $(wc -l < "$out/logcat.txt" 2>/dev/null || echo 0) lines; phone screen texts $(wc -l < "$out/phone-screen.txt"))"
}

case "${1:-}" in
  push) shift; cmd_push "$@" ;;
  snap) shift; cmd_snap "$@" ;;
  reconcile) cmd_reconcile ;;
  *) sed -n 2,10p "$0"; exit 2 ;;
esac
