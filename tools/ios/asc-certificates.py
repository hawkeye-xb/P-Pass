#!/usr/bin/env python3
"""只读：列出 App Store Connect 团队里的全部签名证书（GET /v1/certificates），标出疑似 CI 生成的。

    ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_P8="$(cat AuthKey.p8)" tools/ios/asc-certificates.py

背景：#348 的 TestFlight 归档曾带 -allowProvisioningUpdates，全新 runner 每跑一次就新建一张
Apple Development 证书，直到账号上限（run 40298231858）。本脚本只列清单，**绝不吊销**
（吊销不可逆，由人在 developer.apple.com 上挑着删）。

每行：类型 / 名称 / displayName / platform / 生效时间（证书 DER 的 notBefore）/ 过期时间 / 序列号 / 疑似 CI。
「疑似 CI」判据：DEVELOPMENT 类（含 IOS_DEVELOPMENT）且 name / displayName 是「Created via API」
（API 密钥驱动 Xcode 新建的证书就叫这个，实测）或带 runner 主机名特征（Mac-xxxx / runner / GitHub Actions / ip-）。判据只是提示，删之前人看一眼名称与时间。
不打印证书内容本身。依赖：python3 + cryptography；JWT 复用 asc-builds.py 的 make_jwt。
"""
import importlib.util
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("asc_builds", HERE / "asc-builds.py")
_asc = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_asc)

# 实测（run 40306934975）：API 密钥驱动 Xcode 新建的证书名为「Apple Development: Created via API」。
CI_HOST = re.compile(r"(Created via API|Mac-\d+|runner|GitHub|Actions|\bip-\d|\bVM\b|virtual)", re.I)


def fetch(token: str, url: str) -> dict:
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f"asc-certificates: GET {url.split('?')[0]} → HTTP {e.code}: {e.read().decode()[:300]}")


def not_before_after(content_b64: str):
    import base64
    from cryptography import x509

    try:
        cert = x509.load_der_x509_certificate(base64.b64decode(content_b64))
    except Exception:  # noqa: BLE001 —— 解析不了就留空，不影响列清单
        return "", ""
    nb = getattr(cert, "not_valid_before_utc", None) or cert.not_valid_before
    na = getattr(cert, "not_valid_after_utc", None) or cert.not_valid_after
    return nb.strftime("%Y-%m-%dT%H:%M:%SZ"), na.strftime("%Y-%m-%dT%H:%M:%SZ")


def main() -> None:
    key_id, issuer = os.environ.get("ASC_KEY_ID", ""), os.environ.get("ASC_ISSUER_ID", "")
    p8 = os.environ.get("ASC_KEY_P8", "")
    if not (key_id and issuer and p8):
        sys.exit("asc-certificates: 需要 ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_P8")
    token = _asc.make_jwt(key_id, issuer, p8)

    rows = []
    url = f"{_asc.API}/v1/certificates?limit=200"
    while url:
        res = fetch(token, url)
        for c in res.get("data", []):
            a = c.get("attributes", {})
            nb, na = not_before_after(a.get("certificateContent") or "")
            ctype = a.get("certificateType") or ""
            label = f"{a.get('name') or ''} {a.get('displayName') or ''}"
            ci = "DEVELOPMENT" in ctype and bool(CI_HOST.search(label))
            rows.append({
                "id": c.get("id"), "type": ctype, "name": a.get("name"), "displayName": a.get("displayName"),
                "platform": a.get("platform"), "notBefore": nb or "",
                "expiration": a.get("expirationDate") or na, "serial": a.get("serialNumber"),
                "suspectedCI": ci,
            })
        url = (res.get("links") or {}).get("next")

    rows.sort(key=lambda r: (r["type"], r["notBefore"]))
    print(f"证书共 {len(rows)} 张（只读，未吊销任何证书）")
    print("| 类型 | name | displayName | platform | 生效(notBefore) | 过期 | 序列号 | 疑似 CI |")
    print("|---|---|---|---|---|---|---|---|")
    for r in rows:
        print(f"| {r['type']} | {r['name']} | {r['displayName']} | {r['platform'] or ''} | {r['notBefore']} | "
              f"{r['expiration']} | {r['serial']} | {'是' if r['suspectedCI'] else ''} |")
    by_type = {}
    for r in rows:
        by_type[r["type"]] = by_type.get(r["type"], 0) + 1
    print("\n按类型计数：" + "，".join(f"{k}={v}" for k, v in sorted(by_type.items())))
    print(f"疑似 CI 生成：{sum(r['suspectedCI'] for r in rows)} 张")


if __name__ == "__main__":
    main()
