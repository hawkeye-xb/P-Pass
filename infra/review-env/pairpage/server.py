#!/usr/bin/env python3
"""审核配对页后端：把 daemon 的 IPC 暴露成 3 个 HTTP 接口。

只用标准库，不引第三方依赖 —— 审核环境是「提审前部署、审核期间不更新」的
冻结形态，依赖越少越好。

  GET  /api/qr         → 现生成一张配对二维码串（pairing.start，10 分钟 TTL）
  GET  /api/qr.png?d=  → 把串画成 PNG（需要系统里装了 qrencode）
  GET  /api/pending    → 待确认列表（pairing.pending）
  POST /api/confirm    → 允许/拒绝（pairing.confirm）
  GET  /healthz        → 存活探针
  GET  /               → 页面

IPC 走 daemon 的 ipc.token（两行：socket 名 + 令牌）。Linux 是抽象命名空间
socket（\\0 前缀），macOS 是 /tmp 下的文件 —— 与仓库 tools/ipc-lib.sh 同款握手。

环境变量：
  PPF_IPC_TOKEN_FILE  daemon 写出的 ipc.token 路径（默认 /var/lib/ppass-review/ipc.token）
  PORT                监听端口（默认 8787，只绑 127.0.0.1，对外由 nginx 暴露）
"""
import json
import os
import platform
import socket
import subprocess
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN_FILE = os.environ.get("PPF_IPC_TOKEN_FILE", "/var/lib/ppass-review/ipc.token")
HERE = os.path.dirname(os.path.abspath(__file__))


def ipc(method, params=None):
    """调 daemon IPC，返回 (ok, payload)。"""
    with open(TOKEN_FILE) as f:
        sock_name, token = f.read().split("\n")[:2]
    path = ("\0" if platform.system() == "Linux" else "/tmp/") + sock_name
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    s.connect(path)
    f = s.makefile("rw")
    f.write(token + "\n")
    f.flush()
    f.write(json.dumps({"id": "web", "method": method, "params": params or {}}) + "\n")
    f.flush()
    resp = json.loads(f.readline())
    s.close()
    return bool(resp.get("ok")), resp


def qr_png(data):
    p = subprocess.run(
        ["qrencode", "-o", "-", "-s", "8", "-m", "2", "-t", "PNG"],
        input=data.encode(),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if p.returncode != 0:
        raise RuntimeError(p.stderr.decode()[:200])
    return p.stdout


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):  # noqa: A002 —— 覆写基类签名
        sys.stderr.write("%s %s\n" % (self.address_string(), format % args))

    def _send(self, code, body, ctype="application/json; charset=utf-8", extra=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False)
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Robots-Tag", "noindex, nofollow, noarchive")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        try:
            if u.path == "/":
                with open(os.path.join(HERE, "index.html"), "rb") as f:
                    return self._send(200, f.read(), "text/html; charset=utf-8")
            if u.path == "/api/qr":
                ok, resp = ipc("pairing.start")
                if not ok:
                    return self._send(502, {"ok": False, "error": resp})
                return self._send(200, {"ok": True, "qr": resp["result"]["qr"]})
            if u.path == "/api/qr.png":
                data = (q.get("d") or [""])[0]
                if not data.startswith("ppf://pair?"):
                    return self._send(400, {"ok": False, "error": "bad data"})
                return self._send(200, qr_png(data), "image/png")
            if u.path == "/api/pending":
                ok, resp = ipc("pairing.pending")
                if not ok:
                    return self._send(502, {"ok": False, "error": resp})
                return self._send(200, {"ok": True, **resp["result"]})
            if u.path == "/healthz":
                return self._send(200, {"ok": True})
            return self._send(404, {"ok": False, "error": "not found"})
        except Exception as e:  # noqa: BLE001 —— 后端任何异常都要变成可读的 500
            return self._send(500, {"ok": False, "error": f"{type(e).__name__}: {e}"})

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        try:
            if u.path == "/api/confirm":
                n = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(n) or b"{}")
                ok, resp = ipc("pairing.confirm", {"accept": bool(body.get("accept", True))})
                if not ok:
                    return self._send(502, {"ok": False, "error": resp})
                return self._send(200, {"ok": True, **resp["result"]})
            return self._send(404, {"ok": False, "error": "not found"})
        except Exception as e:  # noqa: BLE001
            return self._send(500, {"ok": False, "error": f"{type(e).__name__}: {e}"})


if __name__ == "__main__":
    port = int(os.environ.get("PORT", "8787"))
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    sys.stderr.write(f"pairpage backend on 127.0.0.1:{port}, ipc={TOKEN_FILE}\n")
    srv.serve_forever()
