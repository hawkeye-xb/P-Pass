#!/usr/bin/env python3
"""在 Cloudflare 上建/改审核环境的 Tunnel + DNS（幂等）。

为什么需要 Tunnel：国内云服务器上，未备案域名会被阿里云按 SNI/Host 拦截
（443 直接 RST、80 返回 `Server: Beaver` 403）。Tunnel 是**出站**连接，
源站不开放任何入站端口，也不走那条被拦的路径。

用法（凭据只从环境变量读，不进代码、不进日志）：

    export CLOUDFLARE_EMAIL=... CLOUDFLARE_API_KEY=...      # Global Key：X-Auth-Email + X-Auth-Key
    export CF_ACCOUNT_ID=... CF_ZONE_ID=...                  # 取值见 CF 面板
    python3 cf-tunnel.py --host pair.example.com \
        --tunnel ppass-review --origin-sni origin.example.com [--dry-run]

做的事：
  1. 找同名 tunnel（没有就建），类型 config_src=cloudflare（远端配置）
  2. 写 ingress：<host> → https://127.0.0.1:443，originServerName=<host>、noTLSVerify=true
     （源站用自签证书，见 README「证书」；证书对不上也无所谓，因为不校验）
  3. DNS：删同名的旧记录，建 proxied CNAME → <tunnel-id>.cfargotunnel.com
  4. 打印 `cloudflared service install` 要用的 token 文件路径

⚠️ host 必须是**一级**子域：CF 免费版 Universal SSL 只覆盖 `*.zone`，
   二级子域（a.b.zone）没有边缘证书，浏览器侧会收到 handshake failure。
"""
import argparse
import json
import os
import sys
import urllib.request

API = "https://api.cloudflare.com/client/v4"


def cf(path, method="GET", data=None):
    email = os.environ.get("CLOUDFLARE_EMAIL")
    key = os.environ.get("CLOUDFLARE_API_KEY")
    if not email or not key:
        sys.exit("缺 CLOUDFLARE_EMAIL / CLOUDFLARE_API_KEY")
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(API + path, data=body, method=method)
    req.add_header("X-Auth-Email", email)
    req.add_header("X-Auth-Key", key)
    if body:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=30) as r:
        out = json.load(r)
    if not out.get("success"):
        sys.exit(f"{method} {path} 失败: {json.dumps(out)[:400]}")
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True, help="对外域名（CF 一级子域）")
    ap.add_argument("--tunnel", default="ppass-review", help="tunnel 名")
    ap.add_argument("--origin-sni", default=None, help="源站 SNI，默认同 --host")
    ap.add_argument("--local-port", default="443", help="源站端口（默认 443，nginx TLS）")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    acct = os.environ.get("CF_ACCOUNT_ID") or sys.exit("缺 CF_ACCOUNT_ID")
    zone = os.environ.get("CF_ZONE_ID") or sys.exit("缺 CF_ZONE_ID")
    if a.host.count(".") != 2:
        print(f"⚠️  {a.host} 不是一级子域，CF 免费版可能没有边缘证书", file=sys.stderr)

    # 1. tunnel（同名即复用）
    tunnels = cf(f"/accounts/{acct}/cfd_tunnel?is_deleted=false&name={a.tunnel}")["result"]
    if tunnels:
        tid = tunnels[0]["id"]
        print(f"复用 tunnel {a.tunnel}: {tid}")
    elif a.dry_run:
        print(f"[dry-run] 会创建 tunnel {a.tunnel}")
        return
    else:
        tid = cf(f"/accounts/{acct}/cfd_tunnel", "POST",
                 {"name": a.tunnel, "config_src": "cloudflare"})["result"]["id"]
        print(f"创建 tunnel {a.tunnel}: {tid}")

    # 2. ingress
    ingress = {"config": {"ingress": [
        {"hostname": a.host,
         "service": f"https://127.0.0.1:{a.local_port}",
         "originRequest": {"originServerName": a.origin_sni or a.host, "noTLSVerify": True}},
        {"service": "http_status:404"}]}}
    if a.dry_run:
        print("[dry-run] ingress:", json.dumps(ingress, ensure_ascii=False))
    else:
        cf(f"/accounts/{acct}/cfd_tunnel/{tid}/configurations", "PUT", ingress)
        print("ingress 已写入")

    # 3. DNS
    for rec in cf(f"/zones/{zone}/dns_records?name={a.host}")["result"]:
        if a.dry_run:
            print(f"[dry-run] 会删除旧记录 {rec['type']} {rec['content']}")
        else:
            cf(f"/zones/{zone}/dns_records/{rec['id']}", "DELETE")
            print(f"删除旧记录 {rec['type']} {rec['content']}")
    if a.dry_run:
        print("[dry-run] 会创建 proxied CNAME →", f"{tid}.cfargotunnel.com")
    else:
        cf(f"/zones/{zone}/dns_records", "POST", {
            "type": "CNAME", "name": a.host,
            "content": f"{tid}.cfargotunnel.com", "proxied": True, "ttl": 1})
        print("DNS 已指向 tunnel")

    # 4. token
    if not a.dry_run:
        tok = cf(f"/accounts/{acct}/cfd_tunnel/{tid}/token")["result"]
        path = f"/root/.{a.tunnel}-token"
        with open(path, "w") as f:
            f.write(tok)
        os.chmod(path, 0o600)
        print(f"token 写到 {path}（600）")
        print(f"下一步：cloudflared service install $(cat {path}) && rm -f {path}")


if __name__ == "__main__":
    main()
