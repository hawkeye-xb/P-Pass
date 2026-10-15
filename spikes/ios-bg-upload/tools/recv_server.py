#!/usr/bin/env python3
"""IOS-03 spike：本地接收端。记录每个请求的方法、路径、全部请求头、body 形状，回一个 64 hex 的完成凭据头。

用法：python3 recv_server.py <port> <out_dir>
- 每个请求在 out_dir/requests.jsonl 追加一行；body 原样存成 out_dir/body-<n>.bin。
- 回 200，头 X-PPass-Receipt = sha256(body) 的 hex（64 个字符），用来看 responseHeaderFields 能否带回（第 7 问）。
- 支持 Content-Length 与 chunked 两种 body。
"""
import hashlib
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(sys.argv[1])
OUT = sys.argv[2]
os.makedirs(OUT, exist_ok=True)
COUNTER = [0]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _read_body(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            chunks, sizes = [], []
            while True:
                line = self.rfile.readline().strip()
                size = int(line.split(b";")[0], 16)
                if size == 0:
                    while self.rfile.readline().strip():
                        pass
                    break
                chunks.append(self.rfile.read(size))
                sizes.append(size)
                self.rfile.readline()
            return b"".join(chunks), sizes
        length = int(self.headers.get("Content-Length", "0") or 0)
        return (self.rfile.read(length) if length else b""), None

    def _handle(self):
        started = time.time()
        body, chunk_sizes = self._read_body()
        COUNTER[0] += 1
        n = COUNTER[0]
        with open(os.path.join(OUT, f"body-{n}.bin"), "wb") as f:
            f.write(body)
        digest = hashlib.sha256(body).hexdigest()
        record = {
            "n": n,
            "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "client": self.client_address[0],
            "method": self.command,
            "path": self.path,
            "http_version": self.request_version,
            "headers": dict(self.headers.items()),
            "body_bytes": len(body),
            "body_head_hex": body[:16].hex(),
            "body_sha256": digest,
            "chunk_sizes": chunk_sizes,
            "looks_multipart": body[:2] == b"--",
            "read_seconds": round(time.time() - started, 3),
        }
        with open(os.path.join(OUT, "requests.jsonl"), "a") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
        print(json.dumps(record, ensure_ascii=False), flush=True)
        self.send_response(200)
        self.send_header("X-PPass-Receipt", digest)
        self.send_header("Content-Length", "0")
        self.end_headers()

    do_GET = do_PUT = do_POST = do_PATCH = do_DELETE = _handle

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
