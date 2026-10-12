#!/usr/bin/env bash
# Shared IPC helper for scenario scripts + dogfood smoke (T-070b: the python
# ipc() heredoc was copy-pasted into 4 scripts — one sourceable copy now).
#
# 依赖调用方已设置 SOCK / TOKEN（daemon 的 ipc.token 两行：socket 名 + 令牌）。
# 用法: source "$ROOT/tools/ipc-lib.sh"  然后  ipc <method> [params-json]

ipc() { # ipc <method> [params-json]
  local params="${2:-}"
  [ -z "$params" ] && params='{}'
  python3 - "$SOCK" "$TOKEN" "$1" "$params" <<'PYEOF'
import socket, json, sys, platform
p, token = sys.argv[1].strip(), sys.argv[2].strip()
req = json.dumps({"id": "x", "method": sys.argv[3], "params": json.loads(sys.argv[4])})
if platform.system() == "Windows":
    # Windows: 命名管道 \\.\pipe\<名>（H-09 实证，见 docs/windows-smoke.md §5）。
    # 字节模式双工管道，按文件打开即可；回包按 \n 切行。
    # 所有管道实例都在服务别人时 open 失败（ERROR_PIPE_BUSY；Python 3.9 实测报成
    # errno 22 EINVAL、winerror 为空）。标准做法是稍等重试（等价于 WaitNamedPipe）。
    import time
    for attempt in range(50):
        try:
            f = open("\\\\.\\pipe\\" + p, "r+b", buffering=0)
            break
        except OSError as e:
            # 管道不存在（daemon 没起来，errno 2）等其它错误直接抛
            if e.errno != 22 or attempt == 49:
                raise
            time.sleep(0.1)
    f.write((token + "\n" + req + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = f.read(1)
        if not chunk:
            break
        buf += chunk
    resp = json.loads(buf.decode())
else:
    # Linux: daemon 的 IPC socket 在抽象命名空间（\0 前缀，非 /tmp 文件）；
    # macOS: /tmp 下文件。按平台选连接路径（双机验证时记账的坑）。
    p = ("\0" if platform.system() == "Linux" else "/tmp/") + p
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(p)
    f = s.makefile("rw"); f.write(token + "\n"); f.flush()
    f.write(req + "\n"); f.flush()
    resp = json.loads(f.readline())
print(json.dumps(resp, ensure_ascii=False))
sys.exit(0 if resp.get("ok") else 1)
PYEOF
}

# SEC-11 (#496)：配对串不再从 daemon 的 stdout 取——stdout 不是终端时 daemon
# 刻意不打印它（含令牌，不能落盘；macOS launchd 下 stdout 就是日志文件）。
# 改经 IPC `pairing.start` 现取，串只在内存/变量里，不经任何文件。
#
# 用法: ipc_pair_qr <ipc.token 路径> [最多重试次数，默认 50（×0.2s）]
#       QR="$PAIR_QR"
# 成功时设全局变量 PAIR_QR（配对串）并把 SOCK / TOKEN 设成本次可用的值；
# 刻意不走 stdout——`$(...)` 子 shell 里设的 SOCK / TOKEN 带不回调用方。
# 每次重试都**重读** ipc.token：它由 ipc.serve 在启动后稍晚才写；而
# crash_recovery 这种沿用数据目录重启的剧本，文件里一开始还是前任实例的令牌。
ipc_pair_qr() {
  local token_file="$1" tries="${2:-50}" resp qr
  for _ in $(seq 1 "$tries"); do
    if [ -s "$token_file" ]; then
      SOCK=$(sed -n 1p "$token_file")
      TOKEN=$(sed -n 2p "$token_file")
      if resp=$(ipc pairing.start 2>/dev/null); then
        qr=$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["qr"])')
        case "$qr" in
          ppf://pair\?*) PAIR_QR="$qr"; return 0 ;;
        esac
      fi
    fi
    sleep 0.2
  done
  echo "ipc_pair_qr: $token_file 对应的 daemon 在 IPC 上始终没给出配对串" >&2
  return 1
}
