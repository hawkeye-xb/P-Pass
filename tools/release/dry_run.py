#!/usr/bin/env python3
"""REL-12（#711）：发布链 dry-run——不花真 tag，把「正式 tag」与「test tag」两条路径各跑一遍。

跑的是 .github/workflows/release.yml / mirror-latest.yml **本身**（按 step 抽出 run 块，
经 tools/release/gha_sim.py 按 runner 语义逐步执行），覆盖：
  create-draft（版本门禁、说明缺失告警、建草稿）→ upload-android（组装清单 → 签名 → 校验 → 上传、
  test 自动发布、test-channel 指针）→ upload-macos → finalize-manifest（桌面收口：冻结件 / 动态清单、
  分端清单、签名、上传）→ upload-windows → finalize-manifest-windows（#788②：test tag 出 Windows
  分端清单并写进 test-channel；正式 tag 跳过）→ mirror-latest 的镜像判定。
  #852：test tag 按端发布——同一个场景里连发几个 test tag（只改 Android / 只改桌面 / 改共享代码 /
  只改文档），断言没改动的一端零构建、它在 test-channel 里的清单逐字节不动。

假的部分（只有这些）：
  - 构建产物：临时目录里的随机字节当 APK / .app.tar.gz（构建、公证不在范围内）；macOS 那份的
    文件清单取自 release.yml 里 macOS job 的 upload-artifact `path:`（#539：资产集合有断言）；
  - 仓库：临时 git 仓库（当前工作区的 tools/ + 临时 versions.json / 说明文件），tag 现打；
  - gh：PATH 前置的 stub（tools/release/gha_sim.py 里的 GH_STUB），记录调用、本地存 release，不访问网络；
  - 签名密钥：运行时用 tauri signer 现生成的临时密钥（不碰 UPDATE_SIGNING_KEY），
    签名由独立校验器 tools/release/verify-update-sig.mjs 验。

用法：
  tools/release/dry-run.sh [--keep]          # 或 just release-dry-run
  RELEASE_YML=<另一份 release.yml> tools/release/dry-run.sh   # 拿别的 workflow 版本跑（对照 / 反证）
退出码：0 全部断言通过；1 有断言失败；2 dry-run 自身跑不起来。
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import plistlib
import tarfile
import zipfile
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from gha_sim import Runner, SimError, gh_calls, load_workflow, write_gh_stub  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
REPO = "hawkeye-xb/P-Pass"
SIGNER = ["npx", "-y", "@tauri-apps/cli@2.11.4", "signer"]

PREV_TAG, FORMAL_TAG, TEST_TAG, BAD_TAG = "v2099.1.0", "v2099.1.1", "v0.0.1-test.1", "v2099.1.2"
PREV_VERSIONS = {"desktop": "9.8.0", "android": "9.8.1", "androidVersionCode": 1}
CUR_VERSIONS = {"desktop": "9.8.1", "android": "9.8.2", "androidVersionCode": 2}  # 两端都涨：android 有说明、macOS 没有
BAD_VERSIONS = {"desktop": "9.8.1", "android": "9.8.3", "androidVersionCode": 3}  # android 说明不合规（含网址）
STALE_TAURI_CONF_VERSION = "9.7.0"  # #809：apps/desktop/src-tauri/tauri.conf.json 里那个不随发布改的号

# 构建 job 不在 dry-run 里跑：结果按 tag push 的真实情形给。Windows 只跟 test tag（#788②），
# 由 Scenario.build_result 按 tag 判定；这里的值只是正式 tag 的情形。
BUILD_RESULTS = {"android": "success", "macos-arm64": "success", "windows-x64": "skipped"}
WINDOWS_INSTALLER = "P-Pass_{v}_x64-setup.exe"
TEST_CHANNEL_WINDOWS_MANIFEST = f"https://github.com/{REPO}/releases/download/test-channel/manifest-windows.json"
TEST_CHANNEL_MACOS_MANIFEST = f"https://github.com/{REPO}/releases/download/test-channel/manifest-macos.json"  # #852
RELEASE_JOBS = ["plan-builds", "android-reuse", "macos-reuse", "create-draft", "upload-android", "upload-macos", "upload-windows", "finalize-manifest", "finalize-manifest-windows",
                "finalize-notes"]

# #773：假 CHANGELOG——正式场景只该取 [2099.1.1] 那一节（不带 Unreleased、不带上一版）。
FORMAL_SECTION = "**Android 9.8.2 · macOS 9.8.2**\n\n### Fixed\n- 演练条目：只该出现在 2099.1.1 的正文开头。"
CHANGELOG = (
    "# Changelog\n\n## [Unreleased]\n\n- 未发布的条目不许进正文\n\n"
    f"## [2099.1.1] - 2099-01-02\n\n{FORMAL_SECTION}\n\n\n"
    "## [2099.1.0] - 2099-01-01\n\n- 上一版的条目不许进正文\n"
)


class Check:
    def __init__(self):
        self.fails = 0

    def __call__(self, ok: bool, desc: str, detail: str = ""):
        if ok:
            print(f"  PASS: {desc}")
        else:
            self.fails += 1
            print(f"  FAIL: {desc}")
            if detail:
                print("    " + detail.strip().replace("\n", "\n    ")[-4000:])
        return ok


def sh(argv, **kw):
    kw.setdefault("check", True)
    return subprocess.run(argv, **kw)


def git(repo: Path, *args):
    sh(["git", "-c", "core.hooksPath=/dev/null", "-c", "user.name=dry-run", "-c", "user.email=dry-run@test.invalid",
        "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false", "-C", str(repo), *args],
       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
       # 固定提交时间 ⇒ 提交号可复现（--summary 对照时不因时间戳而不同）
       env={**os.environ, "GIT_AUTHOR_DATE": "2099-01-01T00:00:00Z", "GIT_COMMITTER_DATE": "2099-01-01T00:00:00Z"})


def sha256(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


# ── 准备：临时密钥、临时仓库、假产物 ─────────────────────────────────────


def make_key(d: Path) -> tuple[str, Path]:
    key = d / "dry-run.key"
    p = sh(SIGNER + ["generate", "-w", str(key), "-p", "", "--ci"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
           text=True, check=False, env={**os.environ, "CI": "true"})
    if p.returncode != 0 or not key.exists():
        raise SimError(f"生成临时签名密钥失败：{p.stdout}")
    pub = Path(str(key) + ".pub")
    real = ROOT / "apps/desktop/src-tauri/tauri.conf.json"
    if real.exists() and pub.read_text().strip() in real.read_text():
        raise SimError("临时公钥竟与仓库里的正式公钥相同——拒绝继续")
    return key.read_text(), pub


def good_notes() -> dict[str, str]:
    fixtures = HERE / "fixtures" / "notes"
    return {str(p.relative_to(fixtures)): p.read_text() for p in sorted(fixtures.rglob("*.txt"))}


BAD_NOTES = {"android/9.8.3.zh.txt": "详情见 https://example.invalid/notes\n", "android/9.8.3.en.txt": "See the notes page.\n"}


def make_origin(d: Path, name: str, commits: list, changelog: str = CHANGELOG) -> tuple[Path, str]:
    """临时仓库：按 commits（versions, notes, tags）依次提交打 tag。返回 (bare origin, 最后一个提交的 sha)。

    每个场景一个独立仓库：create-draft 的「上一个 v* tag」取的是版本序最高的那个，
    多个场景的 tag 混在一个仓库里会互相当成「上一版」。
    """
    src = d / f"src-{name}"
    src.mkdir()
    git(src, "init", "-q", "-b", "main")
    shutil.copytree(ROOT / "tools", src / "tools", ignore=shutil.ignore_patterns("__pycache__", "fixtures"))
    (src / "release").mkdir()
    shutil.copy2(ROOT / "release/legacy-manifest.json", src / "release/legacy-manifest.json")
    # #809：桌面外壳的 tauri 配置——version 故意是个过期号，构建版本若还从这里来，断言立刻红。
    conf = src / "apps/desktop/src-tauri/tauri.conf.json"
    conf.parent.mkdir(parents=True)
    conf.write_text(json.dumps({"productName": "P-Pass", "version": STALE_TAURI_CONF_VERSION}, indent=2) + "\n")
    (src / "CHANGELOG.md").write_text(changelog)

    def commit(versions: dict, notes: dict[str, str], files: dict[str, str], msg: str, *tags: str):
        (src / "release/versions.json").write_text(json.dumps(versions, indent=2) + "\n")
        for rel, body in files.items():  # #852：test tag 按改动路径判定，场景要能改指定路径
            (src / rel).parent.mkdir(parents=True, exist_ok=True)
            (src / rel).write_text(body)
        nd = src / "release/notes"
        if nd.exists():
            shutil.rmtree(nd)
        for rel, body in notes.items():
            (nd / rel).parent.mkdir(parents=True, exist_ok=True)
            (nd / rel).write_text(body)
        git(src, "add", "-A")
        git(src, "commit", "-q", "--allow-empty", "-m", msg)  # #838 none：两次提交版本相同
        for t in tags:
            git(src, "tag", t)

    for i, (versions, notes, tags, *files) in enumerate(commits):
        commit(versions, notes, files[0] if files else {}, f"c{i}", *tags)
    sha = subprocess.run(["git", "-C", str(src), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    origin = d / f"origin-{name}.git"
    sh(["git", "clone", "-q", "--bare", str(src), str(origin)], stderr=subprocess.PIPE)
    return origin, sha


def fake_bytes(seed: str, n: int) -> bytes:
    """可复现的「随机」字节（--summary 对照时 sha256 稳定）。"""
    out, h = b"", seed.encode()
    while len(out) < n:
        h = hashlib.sha256(h).digest()
        out += h
    return out[:n]


# #539：release 上 macOS 资产的完整集合（{v} = 该端版本号）。正式发布不再附带 daemon 层
# 自包含 zip——多出来或少一个都判红。
MACOS_RELEASE_ASSETS = ("P-Pass_{v}_macos-arm64.dmg", "P-Pass_{v}_macos-arm64.app.tar.gz", "SHA256SUMS-macos-arm64")
MACOS_SUMS = "SHA256SUMS-macos-arm64"


def macos_upload_names(wf: dict, desktop_ver: str) -> list[str]:
    """macOS 构建 job 的 upload-artifact `path:` 列表 → 文件名（`*` 代入版本号）。

    构建 job 本身不在 dry-run 里跑，但它往 artifact 里放什么由 release.yml 决定——fixture 从这里
    派生，而不是另写一份清单：workflow 把某个产物加回上传列表，dry-run 立刻看得见。
    """
    steps = [s for s in wf["jobs"]["macos-arm64"]["steps"] if "actions/upload-artifact@" in str(s.get("uses", ""))]
    if len(steps) != 1:
        raise SimError(f"macos-arm64 job 应恰有 1 个 upload-artifact 步骤，实际 {len(steps)}")
    paths = [ln.strip() for ln in str(steps[0]["with"]["path"]).splitlines() if ln.strip()]
    return [Path(p).name.replace("*", desktop_ver) for p in paths]


def fake_apk(p: Path, ver: str):
    """假 APK：一个 zip，里面放 VERSION（dry-run 的 aapt2 桩从这里读 versionName）+ 可复现的填充字节。"""
    with zipfile.ZipFile(p, "w") as z:
        for name, data in (("VERSION", ver.encode()), ("classes.dex", fake_bytes(f"apk {ver}", 4096))):
            info = zipfile.ZipInfo(name, date_time=(2099, 1, 1, 0, 0, 0))
            z.writestr(info, data)


def fake_app_tar(p: Path, ver: str):
    """假 .app.tar.gz：真的 tar.gz，带 P-Pass.app/Contents/Info.plist（#838 复用时核对包内版本号）。"""
    plist = plistlib.dumps({"CFBundleShortVersionString": ver})
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", mtime=0) as gz, tarfile.open(fileobj=gz, mode="w") as t:
        info = tarfile.TarInfo("P-Pass.app/Contents/Info.plist")
        info.size, info.mtime = len(plist), 0
        t.addfile(info, io.BytesIO(plist))
    p.write_bytes(buf.getvalue())


AAPT2_STUB = r"""#!/usr/bin/env python3
# dry-run 桩：aapt2 dump badging <apk> → 从假 APK 的 VERSION 读 versionName
import sys, zipfile
v = zipfile.ZipFile(sys.argv[-1]).read("VERSION").decode()
print(f"package: name='com.hawkeyexb.ppass' versionCode='1' versionName='{v}'")
"""


def make_artifacts(d: Path, wf: dict, android_ver: str, desktop_ver: str) -> Path:
    """假构建产物，按 build job 上传 artifact 的布局放（artifact 名 → 文件）。"""
    a = d / "artifacts"
    (a / "android").mkdir(parents=True)
    fake_apk(a / "android" / f"P-Pass_{android_ver}_android.apk", android_ver)
    m = a / "macos-arm64"
    m.mkdir()
    names = macos_upload_names(wf, desktop_ver)
    for name in names:
        if name.endswith(".app.tar.gz"):
            fake_app_tar(m / name, desktop_ver)
        elif name != MACOS_SUMS:
            (m / name).write_bytes(fake_bytes(f"{name}", 2048))
    if MACOS_SUMS in names:
        (m / MACOS_SUMS).write_text("".join(f"{sha256(p)}  {p.name}\n" for p in sorted(m.iterdir())))
    # #788②：Windows 两个 artifact（upload-windows / finalize-manifest-windows 下载的布局）
    w = a / "windows-x64"
    w.mkdir()
    for name in ("daemon.exe", "testclient.exe", "BUILD_INFO-windows-x64"):
        (w / name).write_bytes(fake_bytes(f"win {name} {desktop_ver}", 1024))
    (w / "SHA256SUMS-windows-x64").write_text("".join(f"{sha256(p)}  {p.name}\n" for p in sorted(w.iterdir())))
    wi = a / "windows-x64-installer"
    wi.mkdir()
    (wi / WINDOWS_INSTALLER.format(v=desktop_ver)).write_bytes(fake_bytes(f"nsis {desktop_ver}", 4096))
    return a


def check_macos_assets(ck: Check, sc: "Scenario", tag: str, desktop_ver: str):
    d = sc.state / "releases" / tag / "assets"
    got = sorted(p.name for p in d.iterdir() if "macos-arm64" in p.name) if d.exists() else []
    want = sorted(n.format(v=desktop_ver) for n in MACOS_RELEASE_ASSETS)
    ck(got == want, f"#539：release {tag} 的 macOS 资产恰为 {want}（不含 zip）", f"实际 {got}")


# ── #809：桌面构建 job 里外壳与 daemon 的版本号同源 ──────────────────────
#
# 构建 job 的其余部分（工具链、依赖缓存、签名、公证）不在 dry-run 范围内，只跑与版本号
# 有关的几步——release.yml 里的**原文**：Resolve desktop version → Build release binaries
# （daemon 吃 PPF_BUILD_VERSION）→ 外壳那一步（macOS = bundle-desktop-macos.sh 全脚本，
# Windows = NSIS 那步）。cargo / pnpm / codesign / npm 是 PATH 前置的桩：
#   - cargo：按 crates/daemon/build.rs 的规则把 PPF_BUILD_VERSION 烤进假 daemon
#     （`--version` 打印 `P-Pass daemon <号>`；没注入就是 CARGO_PKG_VERSION 的占位号）；
#   - pnpm tauri build|bundle：按 tauri CLI 的规则把 `--config` 合并到 tauri.conf.json 上，
#     记下外壳拿到的 version（= 编进壳的 package_info / Info.plist 的 CFBundleShortVersionString）。
# 判据：外壳（build 与 bundle 两次调用）== daemon == tools/release-version.sh desktop。

CARGO_PKG_PLACEHOLDER = "0.0.0-cargo-pkg-version"

BUILD_STUB_CARGO = r"""#!/usr/bin/env bash
# dry-run 桩：cargo build → 假 daemon（版本规则同 crates/daemon/build.rs + ipc::daemon_version）
set -euo pipefail
v="${PPF_BUILD_VERSION:-}"; v="$(printf '%s' "$v" | tr -d '[:space:]')"; v="${v#v}"
[ -n "$v" ] || v="__PLACEHOLDER__"
mkdir -p target/release
for f in daemon daemon.exe testclient.exe; do
  printf '#!/bin/sh\necho "P-Pass daemon %s"\n' "$v" > "target/release/$f"; chmod +x "target/release/$f"
done
echo "$v" >> "$DRYRUN_REC/daemon"
""".replace("__PLACEHOLDER__", CARGO_PKG_PLACEHOLDER)

BUILD_STUB_PNPM = r'''#!/usr/bin/env python3
# dry-run 桩：pnpm install（无操作）/ pnpm tauri build|bundle（记录外壳拿到的 version，造假产物）
import json, os, plistlib, shutil, sys
from pathlib import Path
a = sys.argv[1:]
if not a or a[0] != "tauri":
    sys.exit(0)
sub, rest = a[1], a[2:]
conf = json.loads(Path("src-tauri/tauri.conf.json").read_text())
def merge(dst, src):  # json merge patch（tauri CLI 的 --config 语义）
    for k, v in src.items():
        if isinstance(v, dict) and isinstance(dst.get(k), dict):
            merge(dst[k], v)
        elif v is None:
            dst.pop(k, None)
        else:
            dst[k] = v
i = 0
while i < len(rest):
    if rest[i] in ("-c", "--config"):
        val = rest[i + 1]
        merge(conf, json.loads(Path(val).read_text() if os.path.isfile(val) else val))
        i += 2
    else:
        i += 1
ver = conf.get("version", "")
rec = Path(os.environ["DRYRUN_REC"])
with open(rec / f"shell-{sub}", "a") as f:
    f.write(ver + "\n")
# 记下插件 endpoint（test 包读 test-channel 分端清单）给断言用
(rec / f"shell-{sub}-updater.json").write_text(json.dumps({
    "endpoints": conf.get("plugins", {}).get("updater", {}).get("endpoints"),
}))
bundle_dir = Path("src-tauri/target/release/bundle")
if sub == "bundle":
    app = bundle_dir / "macos/P-Pass.app"
    (app / "Contents/MacOS").mkdir(parents=True, exist_ok=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleShortVersionString": ver}))
    shutil.copy2("src-tauri/binaries/ppf-daemon-aarch64-apple-darwin", app / "Contents/MacOS/ppf-daemon")
elif sub == "build" and "--no-bundle" not in rest:
    (bundle_dir / "nsis").mkdir(parents=True, exist_ok=True)
    (bundle_dir / "nsis" / f"P-Pass_{ver}_x64-setup.exe").write_bytes(b"fake")
'''

# job → 外壳那一步（release.yml 里的 step 名）。改名时这里跟着改，否则 dry-run 直接报错。
SHELL_STEPS = {"macos-arm64": "Bundle desktop .app + dmg (H-10c)", "windows-x64": "Build desktop shell installer (NSIS, T7)"}
BUILD_VERSION_STEPS = ["Resolve desktop version (UPD-13)", "Build release binaries"]


def build_versions(ck: Check, sc: "Scenario", wf: dict, tag: str, want: str):
    """在 sc 的临时仓库上跑两个桌面构建 job 的版本相关步骤，断言外壳 == daemon == want。"""
    stub = sc.dir / "build-bin"
    stub.mkdir(exist_ok=True)
    for name, body in (("cargo", BUILD_STUB_CARGO), ("pnpm", BUILD_STUB_PNPM),
                       ("npm", "#!/bin/sh\nexit 0\n"), ("codesign", "#!/bin/sh\nexit 0\n")):
        (stub / name).write_text(body)
        (stub / name).chmod(0o755)
    runner = Runner(sc.dir / "build-jobs", origin=sc.runner.origin, artifacts=sc.artifacts, stub_bin=stub,
                    repository=REPO, base_path=os.environ["PATH"])
    github = {"event_name": "push", "ref": f"refs/tags/{tag}", "ref_name": tag, "repository": REPO,
              "token": "dry-run-token", "workflow_sha": sc.sha, "event": {}}
    for job_id, shell_step in SHELL_STEPS.items():
        rec = sc.dir / f"build-rec-{job_id}"
        rec.mkdir()
        rel = sc.dir / f"build-rel-{job_id}"
        steps = wf["jobs"][job_id]["steps"]
        by_name = {s.get("name"): s for s in steps}
        missing = [n for n in BUILD_VERSION_STEPS + [shell_step] if n not in by_name]
        if missing:
            raise SimError(f"{job_id} 找不到步骤 {missing}（#809 dry-run 跟着 release.yml 的 step 名走）")
        checkout = next(s for s in steps if str(s.get("uses", "")).startswith("actions/checkout@"))
        picked = [checkout] + [by_name[n] for n in BUILD_VERSION_STEPS]
        # 模拟器一律用 bash 跑 run 块；Windows runner 默认是 pwsh——实际 shell 不是 bash 的步骤，
        # 这里跑通也不代表 CI 上能跑通（v0.9.12-test.12：版本号在 pwsh 里求成空串）。
        job_shell = ((wf["jobs"][job_id].get("defaults") or {}).get("run") or {}).get("shell")
        if "windows" in str(wf["jobs"][job_id].get("runs-on", "")):
            pwsh = [s.get("name") for s in steps if "run" in s and (s.get("shell") or job_shell) != "bash"]
            ck(not pwsh, f"{job_id}：Windows runner 上每个 run 步骤实际都用 bash（默认 pwsh 会让 bash 语法静默失效）",
               f"没指定 bash 的步骤：{pwsh}")
        if job_id == "macos-arm64":
            # 代替 bundle-macos.sh（dylib 收集 / rpath 改写不在范围内）：daemon + lib/ 摆进 rel 目录
            picked.append({"name": "(dry-run) stage sidecar", "run": f"mkdir -p {rel}/lib && cp target/release/daemon {rel}/daemon"})
            s = dict(by_name[shell_step])
            s["run"] = s["run"].replace("/tmp/rel", str(rel))  # release.yml 写死 /tmp/rel；沙箱里换成临时目录
            picked.append(s)
        else:
            picked.append(by_name[shell_step])
        mini = {"env": {**(wf.get("env") or {}), "DRYRUN_REC": str(rec)},
                "jobs": {job_id: {"steps": picked}}}
        r = runner.run_job(mini, job_id, github=github, inputs={}, secrets={}, needs={})
        resolved = r.steps[1].outputs.get("name", "") if len(r.steps) > 1 else ""

        def read(name: str) -> list[str]:
            p = rec / name
            return p.read_text().split() if p.exists() else []

        daemon, shell_build, shell_bundle = read("daemon"), read("shell-build"), read("shell-bundle")
        ck(r.result == "success", f"#809 {job_id} @ {tag}：版本相关构建步骤全部成功", r.log)
        ck(resolved == want, f"#809 {job_id} @ {tag}：release-version.sh desktop = {want}", f"实际 {resolved!r}")
        ck(daemon == [want], f"#809 {job_id} @ {tag}：daemon 版本 = {want}", f"实际 {daemon}")
        # build（编进壳的 package_info，shell.announce / getVersion() 报的就是它）每一次都得是 want
        ck(shell_build != [] and set(shell_build) == {want}, f"#809 {job_id} @ {tag}：外壳二进制版本（tauri build）= {want}",
           f"实际 {shell_build}（tauri.conf.json 里是 {STALE_TAURI_CONF_VERSION}）")
        if job_id == "macos-arm64":
            ck(shell_bundle == [want], f"#809 {job_id} @ {tag}：外壳 Info.plist 版本（tauri bundle）= {want}",
               f"实际 {shell_bundle}（tauri.conf.json 里是 {STALE_TAURI_CONF_VERSION}）")
            # #852：macOS 与 Windows 同口径——插件 endpoint 由共用的 tools/release/tauri-config.mjs 生成，
            # test 包指向 test-channel/manifest-macos.json，正式包不覆盖（用 tauri.conf.json）。
            # build 与 bundle 两次调用都要拿到同一份（endpoint 在 build 那一步编进二进制）。
            for sub in ("build", "bundle"):
                upd_file = rec / f"shell-{sub}-updater.json"
                upd = json.loads(upd_file.read_text()) if upd_file.exists() else {}
                if "-test." in tag:
                    ck(upd.get("endpoints") == [TEST_CHANNEL_MACOS_MANIFEST],
                       f"#852 {job_id} @ {tag}：test 包的更新 endpoint（tauri {sub}）= test-channel/manifest-macos.json",
                       json.dumps(upd))
                else:
                    ck(upd_file.exists() and upd.get("endpoints") is None,
                       f"#852 {job_id} @ {tag}：正式包不覆盖 endpoint（tauri {sub}，用 tauri.conf.json）",
                       json.dumps(upd))
        else:
            upd_file = rec / "shell-build-updater.json"
            upd = json.loads(upd_file.read_text()) if upd_file.exists() else {}
            if "-test." in tag:
                ck(upd.get("endpoints") == [TEST_CHANNEL_WINDOWS_MANIFEST],
                   f"#788② {job_id} @ {tag}：test 包的更新 endpoint = test-channel/manifest-windows.json",
                   json.dumps(upd))
            else:
                ck(upd.get("endpoints") is None,
                   f"#788② {job_id} @ {tag}：正式包不覆盖 endpoint（用 tauri.windows.conf.json）",
                   json.dumps(upd))


# ── 跑 workflow ────────────────────────────────────────────────────────


class Scenario:
    def __init__(self, base: Path, name: str, origin: Path, sha: str, key: str, android_ver: str, desktop_ver: str,
                 wf: dict):
        self.dir = base / name
        self.dir.mkdir()
        self.state = self.dir / "gh-state"
        self.bin = self.dir / "bin"
        write_gh_stub(self.bin, self.state)
        (self.bin / "aapt2").write_text(AAPT2_STUB)
        (self.bin / "aapt2").chmod(0o755)
        self.artifacts = make_artifacts(self.dir, wf, android_ver, desktop_ver)
        self.runner = Runner(self.dir / "jobs", origin=origin, artifacts=self.artifacts, stub_bin=self.bin,
                             repository=REPO, base_path=os.environ["PATH"])
        self.sha, self.key = sha, key
        self.jobs: dict = {}

    def release(self, wf: dict, tag: str, jobs=RELEASE_JOBS):
        self.tag = tag
        github = {"event_name": "push", "ref": f"refs/tags/{tag}", "ref_name": tag, "repository": REPO,
                  "token": "dry-run-token", "workflow_sha": self.sha, "event": {}}
        self.wf, self.github = wf, github
        for job_id in jobs:
            needs = {}
            for n in wf["jobs"][job_id].get("needs", []) or []:
                if n in self.jobs:
                    needs[n] = {"result": self.jobs[n].result, "outputs": self.jobs[n].outputs}
                elif n in BUILD_RESULTS:
                    needs[n] = {"result": self.build_result(n), "outputs": {}}
                else:
                    raise SimError(f"{job_id} needs {n}，dry-run 没有它的结果")
            # 没配置的 secret 在 GitHub 上是空串（VT_API_KEY 未配置 ⇒ VirusTotal 步跳过）
            self.jobs[job_id] = self.runner.run_job(wf, job_id, github=github, inputs={},
                                                    secrets={"UPDATE_SIGNING_KEY": self.key, "VT_API_KEY": ""},
                                                    needs=needs)
        return self.jobs

    def build_result(self, job: str) -> str:
        """构建 job 不在 dry-run 里跑：#838 之后它跑不跑取决于 plan-builds 的判定。"""
        plan = self.jobs.get("plan-builds")
        if job in ("android", "macos-arm64", "windows-x64") and plan is not None:
            # #852：跑不跑由 release.yml 里该构建 job 自己的 if: 决定（按 plan-builds 的真实结果求值），
            # 不在这里另写一份规则——job 的步骤换成空表，只看它被不被跳过。
            stub = {**self.wf, "jobs": {job: {**self.wf["jobs"][job], "steps": []}}}
            needs = {"plan-builds": {"result": plan.result, "outputs": plan.outputs}}
            return self.runner.run_job(stub, job, github=self.github, inputs={}, secrets={}, needs=needs).result
        return BUILD_RESULTS[job]

    def rebuild_artifacts(self, wf: dict, android_ver: str, desktop_ver: str):
        """下一次发布的假构建产物（换版本号）；判定为复用的一端，artifact 由复用 job 产出，这里先删掉。"""
        shutil.rmtree(self.artifacts)
        self.artifacts = make_artifacts(self.dir / f"next-{android_ver}-{desktop_ver}", wf, android_ver, desktop_ver)
        self.runner.artifacts = self.artifacts

    def mirror(self, wf: dict, event: str, tag: str) -> dict:
        ev = {"workflow_run": {"event": {"workflow_run": {"head_branch": tag}}},
              "release": {"event": {"release": {"tag_name": tag}}},
              "workflow_dispatch": {"event": {}}}[event]
        github = {"event_name": event, "ref": "refs/heads/main", "ref_name": "main", "repository": REPO,
                  "token": "dry-run-token", "workflow_sha": self.sha, **ev}
        inputs = {"tag": tag} if event == "workflow_dispatch" else {}
        r = self.runner.run_job(wf, "mirror", github=github, inputs=inputs, secrets={}, needs={}, until="Resolve tag")
        step = r.step("Resolve tag")
        return {"result": r.result, "rc": step.rc, "log": step.log, "outputs": step.outputs}

    def asset(self, tag: str, name: str) -> Path:
        return self.state / "releases" / tag / "assets" / name

    def meta(self, tag: str) -> dict | None:
        p = self.state / "releases" / tag / "meta.json"
        return json.loads(p.read_text()) if p.exists() else None

    def publish(self, tag: str):
        """人工 publish（网页上点发布）——dry-run 里直接调 stub。"""
        sh([str(self.bin / "gh"), "release", "edit", tag, "--draft=false"], stdout=subprocess.DEVNULL)

    def calls(self) -> list:
        return gh_calls(self.state)

    def summary(self) -> dict:
        """可对照的行为摘要（--summary）：每步结论、::warning::/::error:: 注解、gh 调用、上传的清单。

        去掉每次必变的部分（pub_date、签名里的时间戳、临时路径），用来对比「抽脚本前后」的
        release.yml 在同样输入下行为是否一致。
        """
        def norm(s: str) -> str:
            return s.replace(str(self.dir), "<SANDBOX>")

        jobs = {j: {"result": r.result, "steps": [[s.name, s.outcome] for s in r.steps],
                    "annotations": sorted({norm(l.strip()) for s in r.steps for l in s.log.splitlines()
                                           if l.strip().startswith(("::warning::", "::error::", "::notice::"))})}
                for j, r in self.jobs.items()}
        calls = [[norm(a) for a in c] for c in self.calls()]
        manifests = {}
        rels = self.state / "releases"
        for p in sorted(rels.glob("*/assets/manifest*.json")) if rels.exists() else []:
            m = json.loads(p.read_text())
            m.pop("pub_date", None)
            for e in m.get("platforms", {}).values():
                e["signature"] = "<non-empty>" if e.get("signature") else ""
            manifests[f"{p.parent.parent.name}/{p.name}"] = m
        return {"jobs": jobs, "gh_calls": calls, "manifests": manifests}


SUMMARY: dict = {}


# ── 断言 ──────────────────────────────────────────────────────────────


def verify_sig(pub: Path, asset: Path, sig: str) -> tuple[bool, str]:
    p = subprocess.run(["node", str(HERE / "verify-update-sig.mjs"), str(pub), str(asset), sig or "@/dev/null"],
                       capture_output=True, text=True)
    return p.returncode == 0, (p.stdout + p.stderr).strip()


def check_manifest(ck: Check, sc: Scenario, pub: Path, tag: str, name: str, *, version: str, targets: dict,
                   notes: str, notes_i18n: dict | None):
    """targets：{target: 资产文件名}。资产字节取 stub release 里上传的那份（= 客户端会下载到的）。"""
    p = sc.asset(tag, name)
    if not ck(p.exists(), f"{name} 已上传到 release {tag}"):
        return
    m = json.loads(p.read_text())
    ck(m.get("version") == version, f"{name}: version = {version}", f"实际 {m.get('version')!r}")
    ck(sorted(m.get("platforms", {})) == sorted(targets), f"{name}: 只含 {sorted(targets)}", f"实际 {sorted(m.get('platforms', {}))}")
    ck(m.get("notes") == notes, f"{name}: notes = {notes!r}", f"实际 {m.get('notes')!r}")
    if notes_i18n is None:
        ck("notes_i18n" not in m, f"{name}: 没有 notes_i18n")
    else:
        ck(m.get("notes_i18n") == notes_i18n, f"{name}: notes_i18n = {notes_i18n}", f"实际 {m.get('notes_i18n')!r}")
    # #872：test tag 的下载链接指向滚动的 test-channel（tag 自己的 release 保持 draft）。
    home = "test-channel" if "-test." in tag else tag
    for target, asset_name in targets.items():
        e = m.get("platforms", {}).get(target, {})
        asset = sc.asset(tag, asset_name)
        want_url = f"https://github.com/{REPO}/releases/download/{home}/{asset_name}"
        ck(e.get("url") == want_url, f"{name}: {target} url → {home} 的 {asset_name}", f"实际 {e.get('url')!r}")
        if home != tag:
            served = sc.asset(home, asset_name)
            ck(served.exists() and served.read_bytes() == asset.read_bytes(),
               f"{name}: {target} 的 {asset_name} 已在 {home} 里，且与本 tag 构建的字节一致")
        ck(asset.exists() and e.get("sha256") == sha256(asset), f"{name}: {target} sha256 与上传的资产一致")
        ok, why = verify_sig(pub, asset, e.get("signature", ""))
        ck(ok, f"{name}: {target} 签名可用临时公钥校验通过", why)


def fixture_notes(lang: str) -> str:
    return (HERE / "fixtures/notes/android" / f"{CUR_VERSIONS['android']}.{lang}.txt").read_text().strip()


def job_ok(ck: Check, jobs: dict, job_id: str, want: str = "success"):
    j = jobs[job_id]
    return ck(j.result == want, f"job {job_id} = {want}", f"实际 {j.result}\n{j.log}")


def step_is(ck: Check, jobs: dict, job_id: str, step: str, want: str):
    j = jobs[job_id]
    try:
        s = j.step(step)
    except KeyError as e:
        return ck(False, f"{job_id} /「{step}」= {want}", str(e))
    return ck(s.outcome == want, f"{job_id} /「{step}」= {want}", f"实际 {s.outcome}\n{s.log}")


def formal(ck: Check, base: Path, key: str, pub: Path, rel: dict, mirror: dict):
    print(f"\n== 正式 tag {FORMAL_TAG}（desktop {CUR_VERSIONS['desktop']} 无说明 / android {CUR_VERSIONS['android']} 有说明）")
    av, dv = CUR_VERSIONS["android"], CUR_VERSIONS["desktop"]
    origin, sha = make_origin(base, "formal", [(PREV_VERSIONS, {}, [PREV_TAG]), (CUR_VERSIONS, good_notes(), [FORMAL_TAG])])
    sc = Scenario(base, "formal", origin, sha, key, av, dv, rel)
    jobs = sc.release(rel, FORMAL_TAG)
    for j in ("create-draft", "upload-android", "upload-macos", "finalize-manifest"):
        job_ok(ck, jobs, j)
    check_macos_assets(ck, sc, FORMAL_TAG, dv)
    build_versions(ck, sc, rel, FORMAL_TAG, dv)
    job_ok(ck, jobs, "upload-windows", "skipped")
    job_ok(ck, jobs, "finalize-manifest-windows", "skipped")
    ck(not sc.asset(FORMAL_TAG, "manifest-windows.json").exists(), "#788② 正式 tag 不出 manifest-windows.json（Windows 未正式发布）")
    step_is(ck, jobs, "create-draft", "Version bump gate (UPD-13)", "success")
    s = step_is(ck, jobs, "create-draft", "Release notes presence (#741, warn only)", "success")
    if s:
        log = jobs["create-draft"].step("Release notes presence (#741, warn only)").log
        ck(f"::warning::macos 版本涨到 {dv}" in log, "缺说明文件的端（macOS）出现 ::warning::，退出码 0", log)
        ck("::warning::android" not in log, "有说明文件的端（Android）不告警", log)
    ck((sc.meta(FORMAL_TAG) or {}).get("draft") is True, "正式 tag 停在 draft（等人工 publish），未自动发布",
       json.dumps(sc.meta(FORMAL_TAG)))
    step_is(ck, jobs, "upload-android", "Compose update manifest (UPD-01)", "success")
    step_is(ck, jobs, "upload-android", "Sign update manifest (UPD-01, gated)", "success")
    step_is(ck, jobs, "upload-android", "Point test-channel at this manifest (REL-07)", "skipped")
    ws = jobs["upload-android"].workspace
    ck(not (ws / "artifacts/manifest.json").exists(), "upload-android 不产出动态 manifest.json（只给 test 通道）")
    step_is(ck, jobs, "finalize-manifest", "Sign manifest entries (gated)", "success")
    legacy = (ROOT / "release/legacy-manifest.json").read_bytes()
    ck(sc.asset(FORMAL_TAG, "manifest.json").exists() and sc.asset(FORMAL_TAG, "manifest.json").read_bytes() == legacy,
       "manifest.json = 冻结件原样（不重签、不改字节）")
    apk, mac = f"P-Pass_{av}_android.apk", f"P-Pass_{dv}_macos-arm64.app.tar.gz"
    zh, en = fixture_notes("zh"), fixture_notes("en")
    check_manifest(ck, sc, pub, FORMAL_TAG, "manifest-android.json", version=av, targets={"android-arm64": apk},
                   notes=zh, notes_i18n={"zh": zh, "en": en})
    check_manifest(ck, sc, pub, FORMAL_TAG, "manifest-macos.json", version=dv, targets={"darwin-aarch64": mac},
                   notes="", notes_i18n={})
    ck(not any("test-channel" in a for c in sc.calls() for a in c), "没有任何 gh 调用碰 test-channel")
    # #773：草稿正文（finalize-notes 补齐之后）以 CHANGELOG 本版小节开头，台账在后。
    job_ok(ck, jobs, "finalize-notes")
    body = (sc.meta(FORMAL_TAG) or {}).get("body", "")
    head = f"## 本版更新（{FORMAL_TAG[1:]}）\n\n{FORMAL_SECTION}\n\n---\n\n## P-Pass {FORMAL_TAG[1:]}\n"
    ck(body.startswith(head), "正式 tag 正文：以「本版更新」+ CHANGELOG 该节全文开头，台账在后", body[:600])
    ck("未发布的条目" not in body and "上一版的条目" not in body, "只取本版那一节（不带 Unreleased / 上一版）", body[:600])
    ck("### H-10c 资产 SHA-256" in body, "台账的后续段落（SHA-256）照常追加在后面", body[-400:])
    log = jobs["create-draft"].step("Compose skeleton notes").log
    ck("::warning::" not in log, "有该节时不告警", log)

    # 镜像判定：人工 publish 之后，正式 tag 应被镜像
    sc.publish(FORMAL_TAG)
    for ev in ("workflow_run", "release"):
        r = sc.mirror(mirror, ev, FORMAL_TAG)
        ck(r["rc"] == 0 and r["outputs"].get("tag") == FORMAL_TAG and "skip" not in r["outputs"],
           f"mirror-resolve（{ev}，已发布的正式 tag）→ 镜像 {FORMAL_TAG}", f"{r['outputs']}\n{r['log']}")
    SUMMARY["formal"] = sc.summary()


def test_tag(ck: Check, base: Path, key: str, pub: Path, rel: dict, mirror: dict):
    v = TEST_TAG[1:]
    print(f"\n== test tag {TEST_TAG}（各端版本号 = tag 名，天然没有说明文件）")
    origin, sha = make_origin(base, "test", [(PREV_VERSIONS, {}, [PREV_TAG]), (CUR_VERSIONS, good_notes(), [TEST_TAG])])
    sc = Scenario(base, "test", origin, sha, key, v, v, rel)
    jobs = sc.release(rel, TEST_TAG)
    for j in ("create-draft", "upload-android", "upload-macos", "finalize-manifest"):
        job_ok(ck, jobs, j)
    check_macos_assets(ck, sc, TEST_TAG, v)
    build_versions(ck, sc, rel, TEST_TAG, v)
    job_ok(ck, jobs, "upload-windows")
    job_ok(ck, jobs, "finalize-manifest-windows")
    exe = WINDOWS_INSTALLER.format(v=v)
    # #788②：Windows 分端清单 = 只含 windows-x86_64、version = tag 名、签名可验
    check_manifest(ck, sc, pub, TEST_TAG, "manifest-windows.json", version=v,
                   targets={"windows-x86_64": exe}, notes="", notes_i18n={})
    chw = sc.asset("test-channel", "manifest-windows.json")
    if ck(chw.exists(), "#788② test-channel 指针已写入 manifest-windows.json"):
        mw = json.loads(chw.read_text())
        ck(mw.get("version") == v and sorted(mw["platforms"]) == ["windows-x86_64"],
           "#788② test-channel/manifest-windows.json：version = tag、只含 windows", json.dumps(mw)[:400])
        ok, why = verify_sig(pub, sc.asset(TEST_TAG, exe), mw["platforms"]["windows-x86_64"].get("signature", ""))
        ck(ok, "#788② test-channel/manifest-windows.json 的签名校验通过", why)
    step_is(ck, jobs, "create-draft", "Version bump gate (UPD-13)", "skipped")
    step_is(ck, jobs, "create-draft", "Release notes presence (#741, warn only)", "skipped")
    step_is(ck, jobs, "upload-android", "Point test-channel at this manifest (REL-07)", "success")
    meta = sc.meta(TEST_TAG) or {}
    ck(meta.get("draft") is True, "#872：test tag 的 release 保持 draft（客户端读 test-channel）", json.dumps(meta))
    check_channel(ck, sc, TEST_TAG)
    job_ok(ck, jobs, "finalize-notes")
    body = meta.get("body", "")
    ck(body.startswith(f"## P-Pass {v}\n") and "本版更新" not in body, "#773：test tag 正文不变（不加 CHANGELOG 小节）", body[:300])
    apk, mac = f"P-Pass_{v}_android.apk", f"P-Pass_{v}_macos-arm64.app.tar.gz"
    # test-channel 指针 = upload-android 那份只含 android 的动态清单
    ch = sc.asset("test-channel", "manifest.json")
    if ck(ch.exists(), "test-channel 指针已写入 manifest.json"):
        m = json.loads(ch.read_text())
        ck(m.get("version") == v and sorted(m["platforms"]) == ["android-arm64"], "test-channel 指针：version = tag、只含 android",
           json.dumps(m)[:400])
        ok, why = verify_sig(pub, sc.asset(TEST_TAG, apk), m["platforms"]["android-arm64"].get("signature", ""))
        ck(ok, "test-channel 指针里的签名校验通过", why)
    # #852：test-channel 里与正式版一一对应的分端清单（Android / macOS 都已签名、version = tag）
    for name, target, asset_name in (("manifest-android.json", "android-arm64", apk),
                                     ("manifest-macos.json", "darwin-aarch64", mac)):
        chm = sc.asset("test-channel", name)
        if ck(chm.exists(), f"#852 test-channel 指针已写入 {name}"):
            mm = json.loads(chm.read_text())
            ck(mm.get("version") == v and sorted(mm["platforms"]) == [target],
               f"#852 test-channel/{name}：version = tag、只含 {target}", json.dumps(mm)[:400])
            ok, why = verify_sig(pub, sc.asset(TEST_TAG, asset_name), mm["platforms"][target].get("signature", ""))
            ck(ok, f"#852 test-channel/{name} 的签名校验通过", why)
    step_is(ck, jobs, "finalize-manifest", "Point test-channel at the macOS manifest (#852)", "success")
    # 收口后的动态清单：android + darwin，说明为空（版本号是 tag 名，没有文件）
    check_manifest(ck, sc, pub, TEST_TAG, "manifest.json", version=v,
                   targets={"android-arm64": apk, "darwin-aarch64": mac}, notes="", notes_i18n={})
    check_manifest(ck, sc, pub, TEST_TAG, "manifest-android.json", version=v, targets={"android-arm64": apk},
                   notes="", notes_i18n={})
    check_manifest(ck, sc, pub, TEST_TAG, "manifest-macos.json", version=v, targets={"darwin-aarch64": mac},
                   notes="", notes_i18n={})
    for ev in ("workflow_run", "release", "workflow_dispatch"):
        r = sc.mirror(mirror, ev, TEST_TAG)
        ck(r["rc"] == 0 and r["outputs"].get("skip") == "true" and "tag" not in r["outputs"],
           f"mirror-resolve（{ev}）→ test tag 不镜像（skip=true）", f"{r['outputs']}\n{r['log']}")
    SUMMARY["test"] = sc.summary()


def bad_notes(ck: Check, base: Path, key: str, pub: Path, rel: dict):
    av = BAD_VERSIONS["android"]
    print(f"\n== 正式 tag {BAD_TAG}：说明文件不合规（含网址）⇒ 组装清单必须失败，不带病发布")
    origin, sha = make_origin(base, "bad", [(PREV_VERSIONS, {}, [PREV_TAG]), (BAD_VERSIONS, BAD_NOTES, [BAD_TAG])])  # CHANGELOG 没有 [2099.1.2]
    sc = Scenario(base, "bad-notes", origin, sha, key, av, BAD_VERSIONS["desktop"], rel)
    jobs = sc.release(rel, BAD_TAG, jobs=["plan-builds", "android-reuse", "create-draft", "upload-android"])
    job_ok(ck, jobs, "upload-android", "failure")
    s = step_is(ck, jobs, "upload-android", "Compose update manifest (UPD-01)", "failure")
    if s:
        log = jobs["upload-android"].step("Compose update manifest (UPD-01)").log
        ck("failed lint" in log, "失败原因是说明文件 lint 不过", log)
    ck(not sc.asset(BAD_TAG, "manifest-android.json").exists(), "不合规时没有任何清单被上传")
    # #773：CHANGELOG 缺本版小节 ⇒ 告警、不阻断，正文只有台账。
    step_is(ck, jobs, "create-draft", "Compose skeleton notes", "success")
    log = jobs["create-draft"].step("Compose skeleton notes").log
    ck(f"::warning::CHANGELOG 里没有 [{BAD_TAG[1:]}] 小节" in log, "CHANGELOG 缺本版小节：::warning::，不阻断", log)
    body = (sc.meta(BAD_TAG) or {}).get("body", "")
    ck(body.startswith(f"## P-Pass {BAD_TAG[1:]}\n"), "缺小节时正文只有台账", body[:300])
    SUMMARY["bad-notes"] = sc.summary()


# ── #852：test tag 按端发布（test 通道镜像正式版）──────────────────────────
# 同一个场景（同一个 gh 状态 = 同一个 test-channel）里依次发 test tag：
#   test.1 首发（test-channel 里没有分端清单 ⇒ 拿不准 ⇒ 两端构建）
#   test.2 只改 apps/android/   ⇒ Android 构建、桌面零构建，test-channel/manifest-macos.json 不动
#   test.3 只改 apps/desktop/   ⇒ 桌面构建、Android 零构建，test-channel/manifest-android.json 不动；
#   test.4 改 crates/（共享代码）⇒ 两端构建
#   test.5 只改 docs/           ⇒ plan-builds 报错、不建草稿
# versions.json / 说明文件每次提交都一样（release/** 变化会落进「两端」，掩盖判定）。
PER_END_TAGS = ["v0.0.2-test.1", "v0.0.2-test.2", "v0.0.2-test.3", "v0.0.2-test.4", "v0.0.2-test.5"]
PER_END_CHANNEL = ("manifest.json", "manifest-android.json", "manifest-macos.json")


def before_ver(before: dict, end: str):
    b = before.get("manifest-android.json" if end == "android" else "manifest-macos.json")
    return json.loads(b)["version"] if b else None


def check_channel(ck: Check, sc: Scenario, tag: str):
    """#872：test-channel 里每份清单的下载链接都指向 test-channel 里在的文件；安装包只剩被清单指向的版本。"""
    d = sc.asset("test-channel", "x").parent
    names = sorted(os.listdir(d)) if d.is_dir() else []
    base = f"https://github.com/{REPO}/releases/download/test-channel/"
    refs = set()
    for n in names:
        if not (n.startswith("manifest") and n.endswith(".json")):
            continue
        m = json.loads((d / n).read_text())
        refs.add(m.get("version"))
        for target, e in m.get("platforms", {}).items():
            url = e.get("url", "")
            ck(url.startswith(base) and url[len(base):] in names,
               f"{tag}：test-channel/{n} 的 {target} 下载链接在 test-channel 里", url)
    stale = [n for n in names if n.startswith("P-Pass_") and n[len("P-Pass_"):].split("_")[0] not in refs]
    ck(not stale, f"{tag}：test-channel 里没有清单不指向的旧安装包（引用版本 {sorted(refs)}）", " ".join(stale))


def test_per_end(ck: Check, base: Path, key: str, pub: Path, rel: dict):
    print("\n== #852 test tag 按端发布：只改 Android / 只改桌面 / 改共享代码 / 只改文档")
    t1, t2, t3, t4, t5 = PER_END_TAGS
    notes = good_notes()
    origin, sha = make_origin(base, "per-end", [
        (PREV_VERSIONS, {}, [PREV_TAG]),
        (CUR_VERSIONS, notes, [t1], {"apps/android/app/x.kt": "1\n", "apps/desktop/src/x.js": "1\n", "crates/core/x.rs": "1\n"}),
        (CUR_VERSIONS, notes, [t2], {"apps/android/app/x.kt": "2\n"}),
        (CUR_VERSIONS, notes, [t3], {"apps/desktop/src/x.js": "3\n"}),
        (CUR_VERSIONS, notes, [t4], {"crates/core/x.rs": "4\n"}),
        (CUR_VERSIONS, notes, [t5], {"docs/x.md": "5\n"}),
    ])
    v1 = t1[1:]
    sc = Scenario(base, "per-end", origin, sha, key, v1, v1, rel)

    def channel() -> dict:
        return {n: (sc.asset("test-channel", n).read_bytes() if sc.asset("test-channel", n).exists() else None)
                for n in PER_END_CHANNEL}

    def chver(n: str):
        b = channel()[n]
        return json.loads(b)["version"] if b else None

    def release(tag: str, want: dict):
        v = tag[1:]
        if tag != t1:
            sc.jobs = {}
            sc.rebuild_artifacts(rel, v, v)
        for end, art in (("android", "android"), ("macos", "macos-arm64")):
            if want.get(end) == "skip":
                shutil.rmtree(sc.artifacts / art)  # 构建 job 不跑 ⇒ 没有这一端的 artifact
        return sc.release(rel, tag)

    # test.1：首发，两端构建
    jobs = release(t1, {})
    plan = jobs["plan-builds"]
    ck(plan.outputs.get("android") == "build" and plan.outputs.get("macos") == "build",
       f"{t1}：test-channel 里还没有分端清单 ⇒ 拿不准 ⇒ 两端都构建", json.dumps(plan.outputs) + "\n" + plan.log)
    ck(all(chver(n) == v1 for n in PER_END_CHANNEL), f"{t1}：test-channel 三份清单都指向 {v1}",
       json.dumps({n: chver(n) for n in PER_END_CHANNEL}))

    # test.2 / test.3 / test.4：按改动路径判定
    cases = [(t2, "只改 apps/android/", {"android": "build", "macos": "skip", "windows": "skip"}),
             (t3, "只改 apps/desktop/", {"android": "skip", "macos": "build", "windows": "build"}),
             (t4, "改 crates/（共享代码）", {"android": "build", "macos": "build", "windows": "build"})]
    for tag, what, want in cases:
        v = tag[1:]
        before = channel()
        jobs = release(tag, want)
        plan = jobs["plan-builds"]
        if not job_ok(ck, jobs, "plan-builds"):
            continue
        for end in ("android", "macos"):
            ck(plan.outputs.get(end) == want[end], f"{tag}（{what}）：plan-builds 判 {end} = {want[end]}",
               json.dumps(plan.outputs) + "\n" + plan.log)
            job_ok(ck, jobs, f"{end}-reuse", "skipped")  # test tag 永不复用正式版产物
        ck(sc.build_result("android") == ("success" if want["android"] == "build" else "skipped")
           and sc.build_result("macos-arm64") == ("success" if want["macos"] == "build" else "skipped"),
           f"{tag}：没改动的一端零构建（按 release.yml 构建 job 的 if: 求值被跳过）")
        # 2026-10-12：Windows 同样按端判——只改 Android 时不陪跑 Windows。
        ck(plan.outputs.get("windows") == want["windows"]
           and sc.build_result("windows-x64") == ("success" if want["windows"] == "build" else "skipped"),
           f"{tag}（{what}）：Windows 判 {want['windows']}，构建 job 按 if: 求值一致", json.dumps(plan.outputs))
        job_ok(ck, jobs, "upload-android", "success" if want["android"] == "build" else "skipped")
        job_ok(ck, jobs, "upload-macos", "success" if want["macos"] == "build" else "skipped")
        for j in ("create-draft", "finalize-manifest", "finalize-notes"):
            job_ok(ck, jobs, j)
        after = channel()
        android_files = ("manifest.json", "manifest-android.json")
        for n in PER_END_CHANNEL:
            built = want["android"] == "build" if n in android_files else want["macos"] == "build"
            if built:
                m = json.loads(after[n]) if after[n] else {}
                ck(m.get("version") == v, f"{tag}：test-channel/{n} → {v}", json.dumps(m)[:300])
                target = "android-arm64" if n in android_files else "darwin-aarch64"
                asset_name = f"P-Pass_{v}_android.apk" if target == "android-arm64" else f"P-Pass_{v}_macos-arm64.app.tar.gz"
                ok, why = verify_sig(pub, sc.asset(tag, asset_name), m.get("platforms", {}).get(target, {}).get("signature", ""))
                ck(ok, f"{tag}：test-channel/{n} 的签名校验通过", why)
            else:
                ck(after[n] is not None and after[n] == before[n],
                   f"{tag}：没构建的一端，test-channel/{n} 逐字节不动（仍是 {chver(n)}）")
        ck(sc.asset(tag, "manifest-macos.json").exists() == (want["macos"] == "build"),
           f"{tag}：release 里{'有' if want['macos'] == 'build' else '没有'} manifest-macos.json")
        ck(not any(sc.asset(tag, f).exists() for f in (f"P-Pass_{v}_macos-arm64.dmg",)) or want["macos"] == "build",
           f"{tag}：没构建的桌面端不复制任何产物")
        ck(not sc.asset(tag, f"P-Pass_{v}_android.apk").exists() or want["android"] == "build",
           f"{tag}：没构建的 Android 端不复制任何产物")
        meta = sc.meta(tag) or {}
        ck(meta.get("draft") is True, f"{tag}：release 保持 draft（#872）", json.dumps(meta))
        check_channel(ck, sc, tag)
        for end, name in (("android", "P-Pass_{v}_android.apk"), ("macos", "P-Pass_{v}_macos-arm64.dmg")):
            keep = v if want[end] == "build" else before_ver(before, end)
            ck(sc.asset("test-channel", name.format(v=keep)).exists(),
               f"{tag}：test-channel 里 {end} 的包是 {keep}（{'本次构建' if keep == v else '没构建，保持原样'}）")
        if want["macos"] == "skip":
            step_is(ck, jobs, "finalize-manifest", "Point test-channel at the macOS manifest (#852)", "skipped")

    # test.5：只改文档 ⇒ 两端都没变 ⇒ 报错、不建草稿
    jobs = release(t5, {"android": "skip", "macos": "skip"})
    plan = jobs["plan-builds"]
    job_ok(ck, jobs, "plan-builds", "failure")
    ck("::error::test tag" in plan.log and "各端" in plan.log, f"{t5}（只改 docs/）：各端都没变 ⇒ 明确报错", plan.log)
    job_ok(ck, jobs, "create-draft", "skipped")
    ck(sc.meta(t5) is None, f"{t5}：不建空草稿")
    SUMMARY["test-per-end"] = sc.summary()


# ── #838：构建一次、到处复用 ────────────────────────────────────────────
REUSE_TAG = "v2099.1.3"


def reuse(ck: Check, base: Path, key: str, pub: Path, rel: dict, name: str, cur: dict, notes: dict, want: dict):
    """先发布并 publish 上一个正式版（两端构建），再发本 tag：want = {"android": build|reuse, "macos": ...}；
    两端都 reuse ⇒ plan-builds 必须红、不建草稿。"""
    pa, pd = PREV_VERSIONS["android"], PREV_VERSIONS["desktop"]
    ca, cd = cur["android"], cur["desktop"]
    print(f"\n== #838 {name}：上一版 android {pa} / macOS {pd} → 本版 android {ca} / macOS {cd}（期望 {want}）")
    origin, sha = make_origin(base, f"reuse-{name}", [(PREV_VERSIONS, {}, [PREV_TAG]), (cur, notes, [REUSE_TAG])])
    sc = Scenario(base, f"reuse-{name}", origin, sha, key, pa, pd, rel)
    first = sc.release(rel, PREV_TAG)
    ck(first["plan-builds"].outputs.get("android") == "build" and first["plan-builds"].outputs.get("macos") == "build",
       f"{name}：没有 Latest 时两端都构建", json.dumps(first["plan-builds"].outputs))
    sc.publish(PREV_TAG)
    sc.jobs = {}
    sc.rebuild_artifacts(rel, ca, cd)
    for end, art in (("android", "android"), ("macos", "macos-arm64")):
        if want[end] == "reuse":
            shutil.rmtree(sc.artifacts / art)  # 构建 job 不跑，artifact 只能来自复用 job
    jobs = sc.release(rel, REUSE_TAG)
    plan = jobs["plan-builds"]
    if want["android"] == want["macos"] == "reuse":
        job_ok(ck, jobs, "plan-builds", "failure")
        ck("::error::两端版本号都与 Latest" in plan.log, f"{name}：两端都没涨号 ⇒ 明确报错", plan.log)
        job_ok(ck, jobs, "create-draft", "skipped")
        ck(sc.meta(REUSE_TAG) is None, f"{name}：不建空草稿")
        SUMMARY[f"reuse-{name}"] = sc.summary()
        return
    job_ok(ck, jobs, "plan-builds")
    for end in ("android", "macos"):
        ck(plan.outputs.get(end) == want[end], f"{name}：plan-builds 判 {end} = {want[end]}", json.dumps(plan.outputs))
        job_ok(ck, jobs, f"{end}-reuse", "success" if want[end] == "reuse" else "skipped")
    for j in ("create-draft", "upload-android", "upload-macos", "finalize-manifest", "finalize-notes"):
        job_ok(ck, jobs, j)
    check_macos_assets(ck, sc, REUSE_TAG, cd)
    pairs = {"android": [f"P-Pass_{ca}_android.apk"],
             "macos": [f"P-Pass_{cd}_macos-arm64.dmg", f"P-Pass_{cd}_macos-arm64.app.tar.gz", MACOS_SUMS]}
    for end, files in pairs.items():
        if want[end] != "reuse":
            continue
        for f in files:
            a, b = sc.asset(PREV_TAG, f), sc.asset(REUSE_TAG, f)
            ck(a.exists() and b.exists() and a.read_bytes() == b.read_bytes(), f"{name}：{f} 与 {PREV_TAG} 的那份逐字节相同")
    mver = {"android": ("manifest-android.json", ca), "macos": ("manifest-macos.json", cd)}
    for end, (mf, v) in mver.items():
        p = sc.asset(REUSE_TAG, mf)
        m = json.loads(p.read_text()) if p.exists() else {}
        ck(m.get("version") == v, f"{name}：{mf} 的 version = {v}", json.dumps(m)[:300])
    body = (sc.meta(REUSE_TAG) or {}).get("body", "")
    for end, label, v in (("android", "Android", ca), ("macos", "macOS", cd)):
        line = f"**{label} {v} 产物复用自 {PREV_TAG}**"
        if want[end] == "reuse":
            ck(line in body, f"{name}：正文写明 {label} 产物复用自 {PREV_TAG}", body[:800])
        else:
            ck("复用自" not in body or line not in body, f"{name}：构建的一端（{label}）不写「复用自」")
    SUMMARY[f"reuse-{name}"] = sc.summary()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--keep", action="store_true", help="保留临时目录（排查用）")
    ap.add_argument("--summary", type=Path, help="把可对照的行为摘要写到这个 JSON 文件")
    args = ap.parse_args()
    rel_yml = Path(os.environ.get("RELEASE_YML") or ROOT / ".github/workflows/release.yml")
    mirror_yml = Path(os.environ.get("MIRROR_YML") or ROOT / ".github/workflows/mirror-latest.yml")
    base = Path(tempfile.mkdtemp(prefix="p-pass-release-dry-run."))
    ck = Check()
    try:
        print(f"release workflow: {rel_yml}\nmirror workflow:  {mirror_yml}\nsandbox: {base}")
        rel, mirror = load_workflow(rel_yml), load_workflow(mirror_yml)
        key, pub = make_key(base)
        formal(ck, base, key, pub, rel, mirror)
        test_tag(ck, base, key, pub, rel, mirror)
        bad_notes(ck, base, key, pub, rel)
        test_per_end(ck, base, key, pub, rel)
        # #838：只涨 android ⇒ macOS 复用；只涨桌面 ⇒ android 复用；都不涨 ⇒ 红。
        reuse(ck, base, key, pub, rel, "android-only",
              {**PREV_VERSIONS, "android": CUR_VERSIONS["android"], "androidVersionCode": 2}, good_notes(),
              {"android": "build", "macos": "reuse"})
        reuse(ck, base, key, pub, rel, "desktop-only", {**PREV_VERSIONS, "desktop": CUR_VERSIONS["desktop"]}, {},
              {"android": "reuse", "macos": "build"})
        reuse(ck, base, key, pub, rel, "none", dict(PREV_VERSIONS), {}, {"android": "reuse", "macos": "reuse"})
        if args.summary:
            args.summary.write_text(json.dumps(SUMMARY, ensure_ascii=False, indent=1, sort_keys=True) + "\n")
    except (SimError, subprocess.CalledProcessError) as e:
        detail = getattr(e, "stderr", None)
        print(f"\nDRY-RUN ERROR: {e}{(chr(10) + detail.decode(errors='replace')) if isinstance(detail, bytes) else ''}")
        return 2
    finally:
        if args.keep:
            print(f"\n(sandbox kept: {base})")
        else:
            shutil.rmtree(base, ignore_errors=True)
    if ck.fails:
        print(f"\nrelease dry-run: {ck.fails} 项失败 ❌")
        return 1
    print("\nrelease dry-run: 正式 tag / test tag（含 #852 按端发布）/ #838 复用全部通过 ✅")
    return 0


if __name__ == "__main__":
    sys.exit(main())
