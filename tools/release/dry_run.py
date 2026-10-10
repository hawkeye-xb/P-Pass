#!/usr/bin/env python3
"""REL-12（#711）：发布链 dry-run——不花真 tag，把「正式 tag」与「test tag」两条路径各跑一遍。

跑的是 .github/workflows/release.yml / mirror-latest.yml **本身**（按 step 抽出 run 块，
经 tools/release/gha_sim.py 按 runner 语义逐步执行），覆盖：
  create-draft（版本门禁、说明缺失告警、建草稿）→ upload-android（组装清单 → 签名 → 校验 → 上传、
  test 自动发布、test-channel 指针）→ upload-macos → finalize-manifest（桌面收口：冻结件 / 动态清单、
  分端清单、签名、上传）→ finalize-manifest-windows（应被跳过）→ mirror-latest 的镜像判定。

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
import hashlib
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

# 构建 job 不在 dry-run 里跑：结果按 tag push 的真实情形给（Windows 在 tag push 上恒跳过）。
BUILD_RESULTS = {"android": "success", "macos-arm64": "success", "windows-x64": "skipped"}
RELEASE_JOBS = ["create-draft", "upload-android", "upload-macos", "upload-windows", "finalize-manifest", "finalize-manifest-windows",
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
    (src / "CHANGELOG.md").write_text(changelog)

    def commit(versions: dict, notes: dict[str, str], msg: str, *tags: str):
        (src / "release/versions.json").write_text(json.dumps(versions, indent=2) + "\n")
        nd = src / "release/notes"
        if nd.exists():
            shutil.rmtree(nd)
        for rel, body in notes.items():
            (nd / rel).parent.mkdir(parents=True, exist_ok=True)
            (nd / rel).write_text(body)
        git(src, "add", "-A")
        git(src, "commit", "-qm", msg)
        for t in tags:
            git(src, "tag", t)

    for i, (versions, notes, tags) in enumerate(commits):
        commit(versions, notes, f"c{i}", *tags)
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


def make_artifacts(d: Path, wf: dict, android_ver: str, desktop_ver: str) -> Path:
    """假构建产物，按 build job 上传 artifact 的布局放（artifact 名 → 文件）。"""
    a = d / "artifacts"
    (a / "android").mkdir(parents=True)
    (a / "android" / f"P-Pass_{android_ver}_android.apk").write_bytes(fake_bytes(f"apk {android_ver}", 4096))
    m = a / "macos-arm64"
    m.mkdir()
    names = macos_upload_names(wf, desktop_ver)
    for name in names:
        if name != MACOS_SUMS:
            (m / name).write_bytes(fake_bytes(f"{name}", 2048))
    if MACOS_SUMS in names:
        (m / MACOS_SUMS).write_text("".join(f"{sha256(p)}  {p.name}\n" for p in sorted(m.iterdir())))
    return a


def check_macos_assets(ck: Check, sc: "Scenario", tag: str, desktop_ver: str):
    d = sc.state / "releases" / tag / "assets"
    got = sorted(p.name for p in d.iterdir() if "macos-arm64" in p.name) if d.exists() else []
    want = sorted(n.format(v=desktop_ver) for n in MACOS_RELEASE_ASSETS)
    ck(got == want, f"#539：release {tag} 的 macOS 资产恰为 {want}（不含 zip）", f"实际 {got}")


# ── 跑 workflow ────────────────────────────────────────────────────────


class Scenario:
    def __init__(self, base: Path, name: str, origin: Path, sha: str, key: str, android_ver: str, desktop_ver: str,
                 wf: dict):
        self.dir = base / name
        self.dir.mkdir()
        self.state = self.dir / "gh-state"
        self.bin = self.dir / "bin"
        write_gh_stub(self.bin, self.state)
        self.artifacts = make_artifacts(self.dir, wf, android_ver, desktop_ver)
        self.runner = Runner(self.dir / "jobs", origin=origin, artifacts=self.artifacts, stub_bin=self.bin,
                             repository=REPO, base_path=os.environ["PATH"])
        self.sha, self.key = sha, key
        self.jobs: dict = {}

    def release(self, wf: dict, tag: str, jobs=RELEASE_JOBS):
        github = {"event_name": "push", "ref": f"refs/tags/{tag}", "ref_name": tag, "repository": REPO,
                  "token": "dry-run-token", "workflow_sha": self.sha, "event": {}}
        for job_id in jobs:
            needs = {}
            for n in wf["jobs"][job_id].get("needs", []) or []:
                if n in self.jobs:
                    needs[n] = {"result": self.jobs[n].result, "outputs": self.jobs[n].outputs}
                elif n in BUILD_RESULTS:
                    needs[n] = {"result": BUILD_RESULTS[n], "outputs": {}}
                else:
                    raise SimError(f"{job_id} needs {n}，dry-run 没有它的结果")
            self.jobs[job_id] = self.runner.run_job(wf, job_id, github=github, inputs={},
                                                    secrets={"UPDATE_SIGNING_KEY": self.key}, needs=needs)
        return self.jobs

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
    for target, asset_name in targets.items():
        e = m.get("platforms", {}).get(target, {})
        asset = sc.asset(tag, asset_name)
        want_url = f"https://github.com/{REPO}/releases/download/{tag}/{asset_name}"
        ck(e.get("url") == want_url, f"{name}: {target} url → 本 release 的 {asset_name}", f"实际 {e.get('url')!r}")
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
    job_ok(ck, jobs, "finalize-manifest-windows", "skipped")
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
    step_is(ck, jobs, "upload-android", "Auto-publish test tags as prerelease", "skipped")
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
    job_ok(ck, jobs, "finalize-manifest-windows", "skipped")
    step_is(ck, jobs, "create-draft", "Version bump gate (UPD-13)", "skipped")
    step_is(ck, jobs, "create-draft", "Release notes presence (#741, warn only)", "skipped")
    step_is(ck, jobs, "upload-android", "Auto-publish test tags as prerelease", "success")
    step_is(ck, jobs, "upload-android", "Point test-channel at this manifest (REL-07)", "success")
    meta = sc.meta(TEST_TAG) or {}
    ck(meta.get("draft") is False and meta.get("prerelease") is True, "test tag 自动发布为 prerelease", json.dumps(meta))
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
    jobs = sc.release(rel, BAD_TAG, jobs=["create-draft", "upload-android"])
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
    print("\nrelease dry-run: 正式 tag / test tag 两条路径全部通过 ✅")
    return 0


if __name__ == "__main__":
    sys.exit(main())
