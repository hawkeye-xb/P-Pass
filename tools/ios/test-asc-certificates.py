#!/usr/bin/env python3
"""离线自测 asc-certificates.py 的吊销判据（不联网）：只有名称正是「Created via API」的开发证书能进吊销计划，
任何一张不合规就整体中止。由 ci-ios 的证书 job 在吊销前先跑。"""
import importlib.util
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("asc_certificates", HERE / "asc-certificates.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

ROWS = [
    {"id": "1", "type": "DEVELOPMENT", "name": "Created via API", "displayName": "Created via API", "serial": "AA01", "notBefore": "t1"},
    {"id": "2", "type": "DEVELOPMENT", "name": "Created via API", "displayName": "Created via API", "serial": "AA02", "notBefore": "t2"},
    {"id": "3", "type": "DEVELOPMENT", "name": "Zhaowen Li", "displayName": "Zhaowen Li", "serial": "BB01", "notBefore": "t3"},
    {"id": "4", "type": "DEVELOPER_ID_APPLICATION_G2", "name": "Created via API", "displayName": "Created via API", "serial": "CC01", "notBefore": "t4"},
]


def aborts(serials):
    try:
        m.revoke_plan(ROWS, serials)
    except SystemExit:
        return True
    return False


fails = []
plan = m.revoke_plan(ROWS, ["aa01", "AA02"])
if [r["id"] for r in plan] != ["1", "2"]:
    fails.append("两张 CI 证书（序列号大小写不敏感）应全部进计划")
for case, serials in [
    ("混入个人开发证书", ["AA01", "BB01"]),
    ("混入 Developer ID（即使名称是 Created via API）", ["AA01", "CC01"]),
    ("清单里不存在的序列号", ["AA01", "ZZ99"]),
]:
    if not aborts(serials):
        fails.append(f"{case} 必须整体中止")

if fails:
    raise SystemExit("test-asc-certificates: FAIL\n  " + "\n  ".join(fails))
print("test-asc-certificates: ok（合规两张放行；个人证书 / Developer ID / 不存在的序列号均整体中止）")
