#!/usr/bin/env python3
"""#348：到 App Store Connect 查某个构建是否已到（上传成功的 ASC 侧证据）。

    ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_P8="$(cat AuthKey.p8)" \
      tools/ios/asc-builds.py --short 0.9.13 --build 9013000001 [--wait 900]

按 bundle id（Base.xcconfig 的 PPASS_BUNDLE_ID）找 App，再按 预发布版本号 + 构建号 找 build，
打印 processingState（PROCESSING / VALID / INVALID / FAILED）。找到（任何状态，除 INVALID/FAILED）退出 0；
--wait 秒内没出现退出 1。密钥只在内存里用，不落盘、不打印。
依赖：python3 + cryptography（pip install cryptography）。
"""
import argparse
import base64
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://api.appstoreconnect.apple.com"


def b64u(b: bytes) -> bytes:
    return base64.urlsafe_b64encode(b).rstrip(b"=")


def make_jwt(key_id: str, issuer: str, p8: str) -> str:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

    key = serialization.load_pem_private_key(p8.encode(), password=None)
    header = b64u(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}, separators=(",", ":")).encode())
    now = int(time.time())
    payload = b64u(json.dumps({"iss": issuer, "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}, separators=(",", ":")).encode())
    signing_input = header + b"." + payload
    r, s = decode_dss_signature(key.sign(signing_input, ec.ECDSA(hashes.SHA256())))
    sig = b64u(r.to_bytes(32, "big") + s.to_bytes(32, "big"))
    return (signing_input + b"." + sig).decode()


def get(token: str, path: str, params: dict) -> dict:
    url = f"{API}{path}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        sys.exit(f"asc-builds: GET {path} → HTTP {e.code}: {e.read().decode()[:300]}")


def bundle_id() -> str:
    xc = Path(__file__).resolve().parents[2] / "apps/ios/Config/Base.xcconfig"
    m = re.search(r"^PPASS_BUNDLE_ID\s*=\s*(\S+)", xc.read_text(), re.M)
    if not m:
        sys.exit("asc-builds: Base.xcconfig 里找不到 PPASS_BUNDLE_ID")
    return m.group(1)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--short", required=True, help="CFBundleShortVersionString，如 0.9.13")
    ap.add_argument("--build", required=True, help="CFBundleVersion（构建号）")
    ap.add_argument("--wait", type=int, default=0, help="最多等多少秒让构建出现（默认不等）")
    a = ap.parse_args()

    key_id, issuer = os.environ.get("ASC_KEY_ID", ""), os.environ.get("ASC_ISSUER_ID", "")
    p8 = os.environ.get("ASC_KEY_P8", "")
    if not (key_id and issuer and p8):
        sys.exit("asc-builds: 需要 ASC_KEY_ID / ASC_ISSUER_ID / ASC_KEY_P8")
    token = make_jwt(key_id, issuer, p8)

    bid = bundle_id()
    apps = get(token, "/v1/apps", {"filter[bundleId]": bid})["data"]
    if not apps:
        sys.exit(f"asc-builds: App Store Connect 里没有 bundle id={bid} 的 App")
    app_id = apps[0]["id"]
    print(f"app: {apps[0]['attributes'].get('name')} ({bid}) id={app_id}")

    deadline = time.time() + a.wait
    while True:
        res = get(token, "/v1/builds", {
            "filter[app]": app_id,
            "filter[preReleaseVersion.version]": a.short,
            "filter[version]": a.build,
        })
        if res["data"]:
            attrs = res["data"][0]["attributes"]
            state = attrs.get("processingState")
            print(f"build 已到 App Store Connect：version={a.short} build={attrs.get('version')} "
                  f"processingState={state} uploadedDate={attrs.get('uploadedDate')} expired={attrs.get('expired')}")
            sys.exit(0 if state in ("PROCESSING", "VALID") else 1)
        if time.time() >= deadline:
            sys.exit(f"asc-builds: 在 {a.wait}s 内没查到 version={a.short} build={a.build}")
        time.sleep(30)


if __name__ == "__main__":
    main()
