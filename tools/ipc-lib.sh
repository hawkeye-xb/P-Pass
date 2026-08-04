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
p = sys.argv[1]
# Linux: daemon 的 IPC socket 在抽象命名空间（\0 前缀，非 /tmp 文件）；
# macOS: /tmp 下文件。按平台选连接路径（双机验证时记账的坑）。
p = ("\0" if platform.system() == "Linux" else "/tmp/") + p
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(p)
f = s.makefile("rw"); f.write(sys.argv[2] + "\n"); f.flush()
f.write(json.dumps({"id": "x", "method": sys.argv[3], "params": json.loads(sys.argv[4])}) + "\n"); f.flush()
resp = json.loads(f.readline())
print(json.dumps(resp, ensure_ascii=False))
sys.exit(0 if resp.get("ok") else 1)
PYEOF
}
