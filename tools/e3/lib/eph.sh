# 配对桩：`daemon --ephemeral`（内存身份、临时沙盒，绝不碰真实库）。脚本经 IPC 配对、计数、注入。
# 状态目录 ${EPH_STATE}：pid / holder / sandbox / d.log。同一次 run 的场景共用一个桩（setup 里 eph_ensure）。
# shellcheck shell=bash

: "${EPH_STATE:=$E3_STATE/eph}"
E3_EPH_PORT="${E3_EPH_PORT:-41245}"

eph_alive() { [ -f "$EPH_STATE/pid" ] && kill -0 "$(cat "$EPH_STATE/pid")" 2>/dev/null && [ -s "$EPH_STATE/sandbox" ]; }

# eph_start <daemon 路径>：起一个新桩（旧的先停）
eph_start() {
  local bin="$1" i dir
  [ -x "$bin" ] || die "桩二进制不存在：$bin"
  eph_stop
  mkdir -p "$EPH_STATE"
  rm -f "$EPH_STATE"/pid "$EPH_STATE"/holder "$EPH_STATE"/sandbox "$EPH_STATE"/ctl "$EPH_STATE"/bin
  mkfifo "$EPH_STATE/ctl"
  PPF_RELAY_URLS="" PPF_BIND_ADDR="0.0.0.0:$E3_EPH_PORT" "$bin" --ephemeral <"$EPH_STATE/ctl" >"$EPH_STATE/d.log" 2>&1 &
  echo $! >"$EPH_STATE/pid"
  echo "$bin" >"$EPH_STATE/bin"
  # 写端由一个睡眠进程长期持有：FIFO 读到 EOF 桩就退出。
  (exec 3>"$EPH_STATE/ctl"; exec sleep 86400) &
  echo $! >"$EPH_STATE/holder"
  for i in $(seq 1 150); do
    dir=$(sed -n 's/^SANDBOX: //p' "$EPH_STATE/d.log" | head -1)
    if [ -n "$dir" ] && [ -s "$dir/ipc.token" ]; then
      echo "$dir" >"$EPH_STATE/sandbox"
      log "配对桩 pid=$(cat "$EPH_STATE/pid") 端口=$E3_EPH_PORT"
      return 0
    fi
    sleep 0.2
  done
  tail -20 "$EPH_STATE/d.log" >&2
  die "配对桩没起来"
}

# eph_ensure <daemon 路径>：桩在跑且是同一个二进制就复用，否则新起
eph_ensure() {
  if eph_alive && [ "$(cat "$EPH_STATE/bin" 2>/dev/null)" = "$1" ]; then return 0; fi
  eph_start "$1"
}

eph_stop() {
  local f
  for f in holder pid; do
    [ -f "$EPH_STATE/$f" ] && kill "$(cat "$EPH_STATE/$f")" 2>/dev/null
  done
  rm -f "$EPH_STATE/pid" "$EPH_STATE/holder" "$EPH_STATE/sandbox"
  sleep 0.5
  return 0
}

eph_sandbox() { cat "$EPH_STATE/sandbox"; }
# eph_ipc <method> [json]
eph_ipc() {
  local p="${2:-}"
  [ -n "$p" ] || p='{}'
  python3 -I "$E3_LIB/ipc.py" "$(eph_sandbox)/ipc.token" "$1" "$p"
}
eph_qr() { eph_ipc pairing.start | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["result"]["qr"])'; }
eph_photo_count() { eph_ipc status 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["result"]["photo_count"])' 2>/dev/null; }
# 桩索引库（注入用）
eph_db() { ls "$(eph_sandbox)"-local/libraries/*/index.sqlite 2>/dev/null | head -1; }
eph_sql() { sqlite3 -cmd ".timeout 5000" "$(eph_db)" "$1"; }
# eph_wait_count <期望张数> <秒>：等桩里的照片数达到期望
eph_wait_count() {
  local want="$1" end=$((SECONDS + $2)) n=
  while [ $SECONDS -lt $end ]; do
    n=$(eph_photo_count)
    [ -n "$n" ] && [ "$n" -ge "$want" ] && return 0
    sleep 3
  done
  log "等 $2s：桩里 ${n:-?} 张，期望 $want"
  return 1
}
