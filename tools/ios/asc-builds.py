#!/usr/bin/env python3
"""#348：到 App Store Connect 查某个构建是否已到（上传成功的 ASC 侧证据）。

    ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_P8="$(cat AuthKey.p8)" \
      tools/ios/asc-builds.py --short 0.9.13 --build 9013000001 [--wait 900]

按 bundle id（Base.xcconfig 的 PPASS_BUNDLE_ID）找 App，再按 预发布版本号 + 构建号 找 build，
打印 processingState（PROCESSING / VALID / INVALID / FAILED）。找到（PROCESSING / VALID）退出 0；
--wait 秒内没出现退出 2；其余错误（鉴权失败、没有该 App、构建 INVALID/FAILED）退出 1。密钥只在内存里用，不落盘、不打印。
依赖：python3 + cryptography（pip install cryptography）。

#940 防过期守护（只读）：
    tools/ios/asc-builds.py --latest-valid [--stale-days 75] [--open-issues-json FILE] [--body-out FILE]
查最新一个 VALID build 的上传时间，按「TestFlight 构建上传后 90 天过期」算剩余天数；
超过 --stale-days（默认 75）天没有新 build 视为需要提醒。结果以 key=value 逐行打印（可直接追加进 $GITHUB_OUTPUT）：
need_issue=true|false、remaining_days、age_days、latest_uploaded、title。
--open-issues-json 是 `gh issue list --json number,title` 的输出，同标题已有未关闭 issue 时 need_issue=false（不重复开）。
--body-out 写出 issue 正文。判定逻辑是下面的纯函数，单测见 test_asc_builds.py。
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
from datetime import datetime, timedelta, timezone
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


# ── #940 防过期守护：纯函数（不碰网络、不读时钟，now 由调用方传入）──────────────

EXPIRE_DAYS = 90  # TestFlight 构建自上传起 90 天过期
STALE_DAYS = 75  # 超过这么多天没有新 build 就提醒（留 15 天余量）
ISSUE_TITLE = "[IOS] TestFlight 构建临近过期，需要重新上传"


def parse_iso(s: str) -> datetime:
    """解析 ASC 的 uploadedDate（带时区的 ISO 8601，可能以 Z 结尾）。"""
    dt = datetime.fromisoformat(s.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        raise ValueError(f"uploadedDate 缺时区：{s!r}")
    return dt


def staleness(uploaded: "datetime | None", now: datetime, stale_days: int = STALE_DAYS,
              expire_days: int = EXPIRE_DAYS) -> dict:
    """最新 VALID build 的年龄与是否需要提醒。uploaded=None 表示没有任何 VALID build，按已过期处理。"""
    if uploaded is None:
        return {"age_days": None, "remaining_days": 0, "stale": True}
    age = (now - uploaded) // timedelta(days=1)  # 向下取整的整天数
    return {"age_days": age, "remaining_days": expire_days - age, "stale": age > stale_days}


def issue_exists(open_issues: list, title: str) -> bool:
    return any(i.get("title") == title for i in open_issues)


def need_issue(status: dict, open_issues: list, title: str = ISSUE_TITLE) -> bool:
    return bool(status["stale"]) and not issue_exists(open_issues, title)


def issue_body(status: dict, latest_uploaded: "str | None", stale_days: int = STALE_DAYS) -> str:
    rem = status["remaining_days"]
    if status["age_days"] is None:
        state = "App Store Connect 里**没有任何 VALID build**，测试用户现在无法安装。"
    elif rem > 0:
        state = f"最新 VALID build 上传于 {latest_uploaded}，已过 {status['age_days']} 天，**剩余 {rem} 天**过期。"
    else:
        state = f"最新 VALID build 上传于 {latest_uploaded}，已过 {status['age_days']} 天，**已过期**，测试用户打不开 App。"
    return (
        f"防过期守护（#940）发现：超过 {stale_days} 天没有新的 TestFlight build（TestFlight 构建自上传起 {EXPIRE_DAYS} 天过期）。\n\n"
        f"{state}\n\n"
        "## 怎么重新上传\n\n"
        "1. 选一个未被占用的测试版本号：`vX.Y.Z-test.N` 或 `vX.Y.Z-beta.N`（N 比已用过的大；手动入口不许占正式版的号）。\n"
        "2. 运行：`gh workflow run ci-ios.yml --ref <分支> -f testflight_version=vX.Y.Z-test.N`，"
        "或在 Actions 页面选 CI iOS → Run workflow，在 testflight_version 填同样的版本。\n"
        "3. 等 job 成功后到 App Store Connect 的 TestFlight 里确认新 build 状态为可用，并确认外部测试组已选中新 build。\n\n"
        "详见 [docs/RELEASING.md](https://github.com/hawkeye-xb/P-Pass/blob/main/docs/RELEASING.md) §4.2 与 [docs/runbook/ios-testflight-external.md](https://github.com/hawkeye-xb/P-Pass/blob/main/docs/runbook/ios-testflight-external.md)。\n\n"
        "本 issue 由 `.github/workflows/ios-testflight-expiry.yml` 自动开，只提醒、不自动上传；重新上传后关闭即可。\n"
    )


def latest_valid_upload(token: str, app_id: str) -> "str | None":
    res = get(token, "/v1/builds", {
        "filter[app]": app_id,
        "filter[processingState]": "VALID",
        "sort": "-uploadedDate",
        "limit": "1",
    })
    return res["data"][0]["attributes"].get("uploadedDate") if res["data"] else None


def run_guard(a: argparse.Namespace, token: str, app_id: str) -> None:
    uploaded_s = latest_valid_upload(token, app_id)
    uploaded = parse_iso(uploaded_s) if uploaded_s else None
    status = staleness(uploaded, datetime.now(timezone.utc), a.stale_days)
    open_issues = json.loads(Path(a.open_issues_json).read_text()) if a.open_issues_json else []
    need = need_issue(status, open_issues)
    if a.body_out:
        Path(a.body_out).write_text(issue_body(status, uploaded_s, a.stale_days))
    for k, v in (("need_issue", str(need).lower()), ("stale", str(status["stale"]).lower()),
                 ("remaining_days", status["remaining_days"]), ("age_days", status["age_days"]),
                 ("latest_uploaded", uploaded_s), ("title", ISSUE_TITLE)):
        print(f"{k}={'' if v is None else v}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--short", help="CFBundleShortVersionString，如 0.9.13")
    ap.add_argument("--build", help="CFBundleVersion（构建号）")
    ap.add_argument("--latest-valid", action="store_true", help="#940 守护模式：查最新 VALID build 的年龄（只读）")
    ap.add_argument("--stale-days", type=int, default=STALE_DAYS, help="守护模式：超过多少天没新 build 就提醒")
    ap.add_argument("--open-issues-json", help="守护模式：gh issue list --json number,title 的输出文件，用于去重")
    ap.add_argument("--body-out", help="守护模式：issue 正文写到这个文件")
    ap.add_argument("--wait", type=int, default=0, help="最多等多少秒让构建出现（默认不等）")
    a = ap.parse_args()
    if not a.latest_valid and not (a.short and a.build):
        ap.error("需要 --short 和 --build（或 --latest-valid）")

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
    if a.latest_valid:
        run_guard(a, token, app_id)
        return
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
            print(f"asc-builds: 在 {a.wait}s 内没查到 version={a.short} build={a.build}")
            sys.exit(2)
        time.sleep(30)


if __name__ == "__main__":
    main()
