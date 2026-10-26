#!/usr/bin/env python3
"""#1151：release.yml 的凭据隔离门禁（ci-docs lane 跑）。

静态检查三件事，各带反证（--self-test 变异 workflow，判据必须变红）：
  ① 只有 `attest` job 拿 id-token / attestations 权限——跑第三方构建依赖的 job 铸不出来源证明；
  ② 签名凭据（Apple p12 与密码、Android keystore 与密码 / 别名）只允许出现在白名单步骤里；
     job 级 env 只许以 `secrets.X != ''` 的布尔形式引用；
  ④ 引用签名 secret / 更新私钥的 job 必须绑定约定的 environment（#1151，不设审批、限 v* tag 与 main）；
  ③ 执行依赖代码的步骤（pnpm / npm / gradlew / cargo / brew）一律排在引入签名凭据的步骤之前，
     且持有凭据的步骤本身不执行依赖代码。

用法：python3 tools/release/test-secret-isolation.py [--self-test] [release.yml]
"""
from __future__ import annotations

import copy
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/release.yml"

# secret → 允许引用它的 (job, step 名)。
SIGNING = {
    "APPLE_CERT_P12": {("macos-arm64", "Require Apple signing certificate (#1121)"),
                       ("macos-arm64", "Codesign (gated)"),
                       ("macos-arm64", "Sign desktop .app + dmg (H-10c)")},
    "APPLE_CERT_PASSWORD": {("macos-arm64", "Codesign (gated)"),
                            ("macos-arm64", "Sign desktop .app + dmg (H-10c)")},
    "ANDROID_KEYSTORE_BASE64": {("android", "Sign APK (keystore only here)")},
    "ANDROID_KEYSTORE_PASSWORD": {("android", "Sign APK (keystore only here)")},
    "ANDROID_KEYSTORE_ALIAS": {("android", "Sign APK (keystore only here)")},
}
# 执行依赖树里代码的命令。
DEP_CODE = re.compile(r"\b(pnpm|npm|npx|yarn|gradlew|cargo|brew|vcpkg)\b|tools/bundle-desktop-macos\.sh")
# 持有凭据的步骤里，下面这些是允许出现的（签名本身用的脚本）。
SIGN_PHASE_OK = re.compile(r"tools/bundle-desktop-macos\.sh")
ATTEST_ONLY = ("id-token", "attestations")
# #1151：签名 secret 按 environment 隔离（不设审批，限 v* tag 与 main）；job → environment。
ENV_BINDING = {
    "macos-arm64": "release-apple",
    "android": "release-android",
    "upload-android": "release-update-signing",
    "finalize-manifest": "release-update-signing",
    "finalize-manifest-windows": "release-update-signing",
}
UPDATE_KEYS = ("UPDATE_SIGNING_KEY", "UPDATE_SIGNING_KEY_TEST")


def secret_refs(obj) -> set[str]:
    text = yaml.safe_dump(obj, allow_unicode=True)
    return set(re.findall(r"secrets\.([A-Z0-9_]+)", text))


def check(wf: dict) -> list[str]:
    bad: list[str] = []
    for jid, job in wf["jobs"].items():
        perms = job.get("permissions") or {}
        if isinstance(perms, dict):
            for p in ATTEST_ONLY:
                if perms.get(p) == "write" and jid != "attest":
                    bad.append(f"{jid}：不该拿 {p}: write（只有 attest job 能铸来源证明）")
        # job 级 env：只许布尔形式
        for k, v in (job.get("env") or {}).items():
            for sec in secret_refs(v) & set(SIGNING):
                if not re.fullmatch(r"\$\{\{\s*secrets\." + sec + r"\s*!=\s*''\s*\}\}", str(v).strip()):
                    bad.append(f"{jid}：job env {k} 直接带了签名凭据 {sec}（只许 `!= ''` 的布尔判断）")
        steps = job.get("steps") or []
        first_cred = None
        for i, st in enumerate(steps):
            name = st.get("name", "")
            refs = secret_refs({k: v for k, v in st.items() if k in ("env", "with", "run")}) & set(SIGNING)
            for sec in refs:
                if (jid, name) not in SIGNING[sec]:
                    bad.append(f"{jid} /「{name}」：不该接触 {sec}")
            if refs and first_cred is None and any((jid, name) in SIGNING[s] for s in refs):
                first_cred = i
            # 持有凭据的步骤本身不执行依赖代码（签名脚本除外）
            if refs - {"APPLE_CERT_P12"} or (refs and name != "Require Apple signing certificate (#1121)"):
                run = st.get("run", "") or ""
                stripped = SIGN_PHASE_OK.sub("", run)
                if DEP_CODE.search(stripped):
                    bad.append(f"{jid} /「{name}」：持有签名凭据的步骤里不许执行依赖代码")
        # 依赖代码步骤必须排在第一个真正导入凭据的步骤之前
        cred_idx = [i for i, st in enumerate(steps)
                    if (jid, st.get("name", "")) in set().union(*SIGNING.values())
                    and st.get("name") != "Require Apple signing certificate (#1121)"]
        if cred_idx:
            first = cred_idx[0]
            for i, st in enumerate(steps):
                run = st.get("run", "") or ""
                if i > first and DEP_CODE.search(SIGN_PHASE_OK.sub("", run)):
                    bad.append(f"{jid} /「{st.get('name')}」：依赖代码步骤排在了签名凭据步骤之后")
    # ④ 签名 secret 只在绑定了 environment 的 job 里出现
    for jid, job in wf["jobs"].items():
        used = secret_refs(job) & (set(SIGNING) | set(UPDATE_KEYS))
        if used and jid not in ENV_BINDING:
            bad.append(f"{jid}：引用了签名 secret {sorted(used)} 但不在 environment 绑定表里")
    for jid, env in ENV_BINDING.items():
        job = wf["jobs"].get(jid)
        if job is None:
            bad.append(f"{jid}：绑定表里的 job 不存在")
        elif job.get("environment") != env:
            bad.append(f"{jid}：environment 应为 {env}，实际 {job.get('environment')!r}")
    return bad


def self_test(wf: dict) -> int:
    fails = 0

    def expect(label: str, mutate, needle: str):
        nonlocal fails
        w = copy.deepcopy(wf)
        mutate(w)
        out = check(w)
        if any(needle in b for b in out):
            print(f"  ✅ 反证：{label} ⇒ 变红")
        else:
            print(f"  ❌ 反证失败：{label} 没有变红\n     实际：{out}")
            fails += 1

    def step(w, jid, name):
        return next(s for s in w["jobs"][jid]["steps"] if s.get("name") == name)

    expect("macOS 构建步骤带上 p12",
           lambda w: step(w, "macos-arm64", "Build desktop shell (no signing credentials, #1151)").setdefault("env", {}).update(
               APPLE_CERT_P12="${{ secrets.APPLE_CERT_P12 }}"), "不该接触 APPLE_CERT_P12")
    expect("Android 构建步骤带上 keystore 密码",
           lambda w: step(w, "android", "Assemble release APK (unsigned, no signing credentials)").setdefault("env", {}).update(
               ANDROID_KEYSTORE_PASSWORD="${{ secrets.ANDROID_KEYSTORE_PASSWORD }}"), "不该接触 ANDROID_KEYSTORE_PASSWORD")
    expect("build job 拿 id-token",
           lambda w: w["jobs"]["windows-x64"].__setitem__("permissions", {"contents": "read", "id-token": "write"}), "id-token")
    expect("job env 直接带 secret",
           lambda w: w["jobs"]["android"]["env"].update(X="${{ secrets.ANDROID_KEYSTORE_BASE64 }}"), "job env")

    def late_pnpm(w):
        steps = w["jobs"]["macos-arm64"]["steps"]
        steps.append({"name": "late", "run": "pnpm install"})

    expect("依赖安装排在签名步骤之后", late_pnpm, "排在了签名凭据步骤之后")
    expect("签名 job 丢了 environment",
           lambda w: w["jobs"]["android"].pop("environment", None), "environment 应为 release-android")
    expect("别的 job 偷用更新私钥",
           lambda w: w["jobs"]["create-draft"]["steps"][0].setdefault("env", {}).update(
               K="${{ secrets.UPDATE_SIGNING_KEY }}"), "不在 environment 绑定表里")

    def sign_runs_gradle(w):
        step(w, "android", "Sign APK (keystore only here)")["run"] += "\n./gradlew build"

    expect("签名步骤里跑 gradle", sign_runs_gradle, "不许执行依赖代码")
    return fails


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    path = Path(args[0]) if args else WORKFLOW
    wf = yaml.safe_load(path.read_text())
    problems = check(wf)
    for p in problems:
        print(f"  ❌ {p}")
    if problems:
        return 1
    print("  ✅ release.yml 凭据隔离：只有 attest 拿证明权限；签名凭据只在白名单步骤；依赖代码都在凭据之前")
    if "--self-test" in sys.argv and self_test(wf):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
