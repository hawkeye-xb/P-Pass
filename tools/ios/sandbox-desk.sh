#!/usr/bin/env bash
# iOS 真机脚本共用：在本机起「测试沙盒桌面」（daemon --ephemeral），一台一个工作目录。
#
# #1115 之后脚本连不上本机正式桌面（常驻 daemon 只认签名程序），也不该连：要「同一台电脑 /
# 换一台电脑」就起两台沙盒（e3-batch.sh），要「桌面暂时不可达」就暂停沙盒进程（sim-bg-task.sh）。
# 每台沙盒自带假 HOME 与 daemon 自建的临时库，互不相干，也不碰本机装的 P-Pass。
#
# 用法（先 source 本文件，它会 source ../ipc-lib.sh）：
#   desk_start <工作目录> <daemon 可执行文件>   起一台；工作目录里留 pid / node / sandbox / daemon.out / daemon.err
#   desk_node <工作目录>                         NodeId（64 位 hex）
#   desk_qr <工作目录>                           取一次配对串 → 全局 PAIR_QR（每次取都是新的一次性令牌）
#   desk_ipc <工作目录> <方法> [参数 JSON]       对这一台发 IPC（多台并存时每次都按目录选令牌）
#   desk_photo_count <工作目录>                  这台桌面库里的照片数（status.photo_count）
#   desk_auto_allow <工作目录> [日志…]           后台循环：按客户端打出的 PAIR_CODE 行输码允许（脚本扮演桌面主人）
#   desk_pause / desk_resume <工作目录>          SIGSTOP / SIGCONT：桌面不可达 / 恢复
#   desk_stop <工作目录>                         关 stdin（daemon 3 秒内自退）→ 不退再杀；删掉它的临时库
# 生命周期：daemon 的 stdin 接一个 FIFO，写端由一个 sleep 进程占着；desk_stop 杀掉它 = EOF，daemon 正常收尾。
# 调用方的 EXIT trap 里对每台调一次 desk_stop（幂等）。

# shellcheck source=tools/ipc-lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ipc-lib.sh"

desk_start() { # $1 = 工作目录，$2 = daemon
  local d="$1" bin="$2" node pid
  mkdir -p "$d/home"
  rm -f "$d/stdin"
  mkfifo "$d/stdin"
  HOME="$d/home" PPF_BIND_ADDR="0.0.0.0:0" PPF_RELAY_URLS="" PPF_TELEMETRY_ENABLED=false \
    RUST_LOG="${PPASS_E2E_RUST_LOG:-info}" "$bin" --ephemeral <"$d/stdin" >"$d/daemon.out" 2>"$d/daemon.err" &
  pid=$!
  echo "$pid" >"$d/pid"
  sleep 2147483647 >"$d/stdin" &
  echo $! >"$d/holder"
  node=
  for _ in $(seq 1 150); do
    node=$(sed -n 's/^NodeId: \([0-9a-f]\{64\}\).*/\1/p' "$d/daemon.out" | head -1)
    [ -n "$node" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
  done
  if [ -z "$node" ]; then
    echo "desk_start: $d 的沙盒 daemon 没打出 NodeId：" >&2
    tail -5 "$d/daemon.err" >&2 || true
    return 1
  fi
  echo "$node" >"$d/node"
  ipc_sandbox_dir "$d/daemon.out" || return 1
  echo "$SANDBOX_DIR" >"$d/sandbox"
  # 令牌文件在 NodeId 之后才写，等它出现并真能答话。
  desk_qr "$d" >/dev/null || return 1
}

desk_node() { cat "$1/node"; }

desk_use() { # 把 SOCK / TOKEN 指向这一台
  local t
  t="$(cat "$1/sandbox")/ipc.token"
  SOCK=$(sed -n 1p "$t")
  TOKEN=$(sed -n 2p "$t")
}

desk_qr() { ipc_pair_qr "$(cat "$1/sandbox")/ipc.token"; }

desk_ipc() { # $1 = 工作目录，$2 = 方法，$3 = 参数
  desk_use "$1"
  ipc "$2" "${3:-}"
}

desk_photo_count() {
  desk_ipc "$1" status | jq -r '.result.photo_count'
}

desk_auto_allow() { # $1 = 工作目录，其余 = 额外要扫的日志文件；后台跑，pid 记在 <工作目录>/allow，desk_stop 收掉
  # #1118：允许 = 输入手机显示的验证码。客户端（testclient / androidTest / iOS e2e）把
  # `PAIR_CODE=<6 位> node=<手机 NodeId>` 打到日志；这里从 <工作目录>/codes/* 与额外文件里按
  # node 找码，用它确认那一行。没找到码的行不动（盲点允许已不可能）。
  local d="$1"
  shift
  mkdir -p "$d/codes"
  (
    local resp n pid code
    pid=$(cat "$d/pid")
    while kill -0 "$pid" 2>/dev/null; do
      if resp=$(desk_ipc "$d" pairing.pending 2>/dev/null); then
        for n in $(printf '%s' "$resp" | jq -r '.result.pending[]?.node_id // empty'); do
          # 日志文件可能还没出现（客户端还没起来）：缺文件不算错——调用方开着 set -e / pipefail，
          # 这里一失败整个循环就退出了，再也没人输码。
          code=$({ cat "$d"/codes/* "$@" 2>/dev/null || true; } | sed -n "s/.*PAIR_CODE=\([0-9]\{6\}\) node=$n.*/\1/p" | tail -1)
          [ -n "$code" ] || continue
          desk_ipc "$d" pairing.confirm "$(jq -cn --arg n "$n" --arg c "$code" '{accept: true, node_id: $n, code: $c}')" >/dev/null 2>&1 \
            && echo "  桌面 $(basename "$d")：已用验证码允许 ${n:0:8}…"
        done
      fi
      sleep 0.3
    done
  ) &
  echo $! >"$d/allow"
}

desk_pause() { kill -STOP "$(cat "$1/pid")"; }
desk_resume() { kill -CONT "$(cat "$1/pid")"; }

desk_stop() { # 幂等
  local d="$1" pid
  [ -f "$d/pid" ] || return 0
  pid=$(cat "$d/pid")
  kill -CONT "$pid" 2>/dev/null || true
  local helper
  for helper in allow holder; do
    [ -f "$d/$helper" ] || continue
    kill "$(cat "$d/$helper")" 2>/dev/null || true
    wait "$(cat "$d/$helper")" 2>/dev/null || true # 收掉作业，免得 bash 打一行 Terminated
  done
  for _ in $(seq 1 25); do kill -0 "$pid" 2>/dev/null || break; sleep 0.2; done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; fi
  wait "$pid" 2>/dev/null || true
  [ -f "$d/sandbox" ] && rm -rf "$(cat "$d/sandbox")"
  rm -f "$d/pid" "$d/allow" "$d/holder" "$d/stdin"
}
