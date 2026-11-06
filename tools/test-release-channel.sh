#!/usr/bin/env bash
# #1546：test-channel 写入 / 收敛分权的判据测试。
#
# 背景：2026-11-06 run 42210867452 的 job「上传 Android + 更新 manifest」红在
# 「Point test-channel at the Android manifest (#852)」之后的清理段，日志末行
# `no assets match the file pattern`。四个 writer 并行调 point-test-channel.sh，各自枚举 + 删除
# 共享 test-channel，互相删到对方刚枚举出来的资产。
#
# 这个测试锁住修法（docs/decisions/2026-11-06-release-test-channel-single-writer.md）：
#   1. 写路径只上传 / 写清单，不删除；上传失败必须非 0（fail-closed）。
#   2. 收敛在独立脚本里：删没有清单指向的旧包、删过期且无人引用的 test 草稿；幂等；
#      非 test tag / 通道不存在 / 没有清单时不删。
#   3. release.yml 只有一个 job 调收敛脚本，所有 writer 都不调；收敛脚本失败在 workflow 里
#      必须降级为 ::warning:: 且退出 0。
#
# 反证（实现 PR 实测）：
#   ① 把收敛调用放回任一端 writer job ⇒ 结构断言红；
#   ② 把收敛步骤改成直接执行、去掉告警捕获 ⇒ run 块执行断言红；
#   ③ 给 point-test-channel.sh 的上传加 `|| true` ⇒ 上传失败用例红。
#
# 用法: bash tools/test-release-channel.sh
# 退出码: 0 全过 / 1 有失败
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /'; }

# ── stub gh：release view / download / upload / delete-asset / delete / list / create ──
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env python3
import fnmatch, json, os, shutil, subprocess, sys

S = os.environ["STUB_STATE"]
R = os.path.join(S, "releases")
a = sys.argv[1:]

def fail(msg, rc=1):
    sys.stderr.write(msg + "\n")
    sys.exit(rc)

def opt(name, default=None):
    return a[a.index(name) + 1] if name in a else default

def d(tag):
    return os.path.join(R, tag)

def assets(tag):
    return os.path.join(d(tag), "assets")

def exists(tag):
    return os.path.isdir(d(tag))

def meta(tag):
    return {"draft": os.path.exists(os.path.join(d(tag), "DRAFT")),
            "prerelease": os.path.exists(os.path.join(d(tag), "PRERELEASE"))}

if a[:2] == ["release", "view"]:
    tag = a[2] if len(a) > 2 and not a[2].startswith("-") else None
    if not tag or not exists(tag):
        fail("release not found")
    if "--json" in a:
        q = opt("-q") or opt("--jq") or "."
        names = sorted(os.listdir(assets(tag))) if os.path.isdir(assets(tag)) else []
        data = {"isDraft": meta(tag)["draft"], "isPrerelease": meta(tag)["prerelease"],
                "tagName": tag, "assets": [{"name": n} for n in names]}
        r = subprocess.run(["jq", "-r", q], input=json.dumps(data), text=True, capture_output=True)
        sys.stdout.write(r.stdout)
        sys.exit(r.returncode)
    print("title:\t%s\ntag:\t%s\ndraft:\t%s" % (tag, tag, str(meta(tag)["draft"]).lower()))
elif a[:2] == ["release", "download"]:
    tag, pat, out = a[2], opt("-p"), opt("-O")
    hits = [n for n in sorted(os.listdir(assets(tag))) if fnmatch.fnmatch(n, pat)] if os.path.isdir(assets(tag)) else []
    if not hits:
        fail("no assets match the file pattern")
    shutil.copyfile(os.path.join(assets(tag), hits[0]), out or hits[0])
elif a[:2] == ["release", "upload"]:
    tag = a[2]
    os.makedirs(assets(tag), exist_ok=True)
    files = [x for x in a[3:] if not x.startswith("--")]
    # 只让安装包上传失败：清单上传照常，测试才能隔离「安装包上传失败被吞」。
    if os.environ.get("STUB_FAIL_UPLOAD") == "1" and any(f.endswith(".apk") for f in files):
        fail("upload failed")
    for f in files:
        if not os.path.isfile(f):
            fail("upload: %s not found" % f)
        shutil.copyfile(f, os.path.join(assets(tag), os.path.basename(f)))
elif a[:2] == ["release", "delete-asset"]:
    tag, name = a[2], a[3]
    p = os.path.join(assets(tag), name)
    if not os.path.isfile(p):
        fail("no assets match the file pattern")
    os.remove(p)
elif a[:2] == ["release", "delete"]:
    tag = a[2]
    if not exists(tag):
        fail("release not found")
    shutil.rmtree(d(tag))
elif a[:2] == ["release", "create"]:
    tag = a[2]
    if exists(tag):
        fail("release %s already exists" % tag)
    os.makedirs(assets(tag), exist_ok=True)
    if "--draft" in a:
        open(os.path.join(d(tag), "DRAFT"), "w").close()
    if "--prerelease" in a:
        open(os.path.join(d(tag), "PRERELEASE"), "w").close()
elif a[:2] == ["release", "list"]:
    rows = [{"tagName": tag, "isDraft": meta(tag)["draft"], "publishedAt": ""}
            for tag in (sorted(os.listdir(R)) if os.path.isdir(R) else [])]
    q = opt("-q") or opt("--jq") or "."
    r = subprocess.run(["jq", "-r", q], input=json.dumps(rows), text=True, capture_output=True)
    sys.stdout.write(r.stdout)
    sys.exit(r.returncode)
else:
    fail("unsupported gh: " + " ".join(a), 2)
STUB
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"
export STUB_STATE="$TMP/state"
CH="$STUB_STATE/releases/test-channel/assets"

reset_channel() {
  rm -rf "$STUB_STATE"
  mkdir -p "$CH"
  : > "$STUB_STATE/releases/test-channel/assets/.keep"
}
manifest() { # <文件名> <版本> [平台 url]：清单只关心 version 与 platforms[].url
  local name="$1" ver="$2" url="${3:-}"
  if [ -n "$url" ]; then
    printf '{"version":"%s","platforms":{"android-arm64":{"url":"%s"}}}\n' "$ver" "$url" > "$CH/$name"
  else
    printf '{"version":"%s","platforms":{}}\n' "$ver" > "$CH/$name"
  fi
}
asset() { printf '%s' "${2:-x}" > "$CH/$1"; }
draft() { mkdir -p "$STUB_STATE/releases/$1"; : > "$STUB_STATE/releases/$1/DRAFT"; }
has_asset() { [ -f "$CH/$1" ]; }
has_draft() { [ -f "$STUB_STATE/releases/$1/DRAFT" ]; }
run_point() { # <tag> <manifest> [installer...]
  local tag="$1" m="$2"; shift 2
  OUT=$(cd "$TMP" && TAG="$tag" GITHUB_REPOSITORY=hawkeye-xb/P-Pass \
    bash "$ROOT/tools/release/point-test-channel.sh" "$m" "$@" 2>&1); RC=$?
}
run_cleanup() { # <tag>
  OUT=$(cd "$TMP" && TAG="$1" GITHUB_REPOSITORY=hawkeye-xb/P-Pass \
    bash "$ROOT/tools/release/cleanup-test-channel.sh" 2>&1); RC=$?
}

echo "point-test-channel.sh（只写、不清理；上传失败必须红）"
reset_channel
manifest manifest-android.json 0.2.0-test.3 "https://github.com/hawkeye-xb/P-Pass/releases/download/test-channel/P-Pass_0.2.0-test.3_android.apk"
asset P-Pass_0.2.0-test.3_android.apk
asset P-Pass_0.1.0-test.1_android.apk old
draft v0.1.0-test.1
printf '{"version":"0.2.0-test.4","platforms":{"android-arm64":{"url":"https://github.com/hawkeye-xb/P-Pass/releases/download/test-channel/P-Pass_0.2.0-test.4_android.apk"}}}\n' > "$TMP/manifest-android.json"
printf 'new' > "$TMP/P-Pass_0.2.0-test.4_android.apk"
run_point v0.2.0-test.4 "$TMP/manifest-android.json" "$TMP/P-Pass_0.2.0-test.4_android.apk"
{ [ "${RC}" = 0 ] && has_asset P-Pass_0.2.0-test.4_android.apk \
  && [ "$(jq -r .version "$CH/manifest-android.json")" = 0.2.0-test.4 ]; } \
  && ok "上传安装包 + 覆盖清单" || bad "上传安装包 + 覆盖清单（rc=${RC}）" "${OUT}"
{ has_asset P-Pass_0.1.0-test.1_android.apk && has_draft v0.1.0-test.1; } \
  && ok "写路径不删旧安装包、不删旧 test 草稿（清理已移出）" || bad "写路径删了东西（清理仍在 point 脚本里？）"

# 上传失败：不能吞（反证 ③ 的判据）
printf '{"version":"0.2.0-test.5","platforms":{"android-arm64":{"url":"https://github.com/hawkeye-xb/P-Pass/releases/download/test-channel/P-Pass_0.2.0-test.5_android.apk"}}}\n' > "$TMP/m5.json"
printf 'new' > "$TMP/P-Pass_0.2.0-test.5_android.apk"
export STUB_FAIL_UPLOAD=1
run_point v0.2.0-test.5 "$TMP/m5.json" "$TMP/P-Pass_0.2.0-test.5_android.apk"
unset STUB_FAIL_UPLOAD
[ "${RC}" != 0 ] && ok "上传失败 ⇒ 非 0（fail-closed）" || bad "上传失败被吞（rc=${RC}）" "${OUT}"

# 上传失败但清单链接已在通道里（补跑同一 tag）：不能因为链接检查通过就吞掉上传失败。
# 这条是反证 ③ 的判据——把上传改成 `|| true` 时它会红。
printf '{"version":"0.2.0-test.7","platforms":{"android-arm64":{"url":"https://github.com/hawkeye-xb/P-Pass/releases/download/test-channel/P-Pass_0.2.0-test.7_android.apk"}}}\n' > "$TMP/m7.json"
asset P-Pass_0.2.0-test.7_android.apk
printf 'same-bytes' > "$TMP/P-Pass_0.2.0-test.7_android.apk"
export STUB_FAIL_UPLOAD=1
run_point v0.2.0-test.7 "$TMP/m7.json" "$TMP/P-Pass_0.2.0-test.7_android.apk"
unset STUB_FAIL_UPLOAD
{ [ "${RC}" != 0 ] && [ "$(jq -r .version "$CH/manifest-android.json")" = 0.2.0-test.4 ]; } \
  && ok "链接已存在时上传失败仍非 0，且不写清单（反证 ③）" || bad "链接已存在时上传失败被吞（rc=${RC}）" "${OUT}"

# 清单指向不存在的资产：拒绝写清单
printf '{"version":"0.2.0-test.6","platforms":{"android-arm64":{"url":"https://github.com/hawkeye-xb/P-Pass/releases/download/test-channel/nope.apk"}}}\n' > "$TMP/m6.json"
run_point v0.2.0-test.6 "$TMP/m6.json"
{ [ "${RC}" != 0 ] && [ "$(jq -r .version "$CH/manifest-android.json")" = 0.2.0-test.4 ]; } \
  && ok "清单下载链接不在 test-channel ⇒ 拒绝写清单（旧清单不动）" || bad "清单指向缺失资产仍写（rc=${RC}）" "${OUT}"

# 不回拨：通道里的清单已是更新版本（同名清单才判得了版本）
mkdir -p "$TMP/old"
printf '{"version":"0.2.0-test.3","platforms":{}}\n' > "$TMP/old/manifest-android.json"
run_point v0.2.0-test.3 "$TMP/old/manifest-android.json"
{ [ "${RC}" = 0 ] && printf '%s' "${OUT}" | grep -q "不回拨"; } \
  && ok "重跑旧 tag ⇒ 不回拨、直接退出 0" || bad "重跑旧 tag 没有不回拨（rc=${RC}）" "${OUT}"

# 正式 tag：point 拒绝
run_point v2026.11.1 "$TMP/old/manifest-android.json"
[ "${RC}" != 0 ] && ok "正式 tag ⇒ point 脚本拒绝（非 0）" || bad "正式 tag 被 point 脚本接受" "${OUT}"

echo "cleanup-test-channel.sh（单点收敛、幂等、拿不准就保留）"
reset_channel
manifest manifest-android.json 0.3.0-test.4
manifest manifest-macos.json 0.3.0-test.4
manifest manifest-windows.json 0.3.0-test.4
manifest manifest-ios.json 0.3.0-test.3
for f in P-Pass_0.3.0-test.4_android.apk P-Pass_0.3.0-test.4_macos-arm64.app.tar.gz \
         P-Pass_0.3.0-test.4_macos-arm64.dmg P-Pass_0.3.0-test.4_x64-setup.exe; do asset "$f"; done
asset P-Pass_0.3.0-test.3_android.apk old-ios-version
asset P-Pass_0.2.0-test.2_android.apk older
asset SHA256SUMS-macos-arm64 not-a-package
for t in v0.3.0-test.4 v0.3.0-test.3 v0.2.0-test.2 v0.2.0-test.1 v0.3.0-test.5; do draft "$t"; done
run_cleanup v0.3.0-test.4
{ [ "${RC}" = 0 ] \
  && has_asset P-Pass_0.3.0-test.4_android.apk \
  && has_asset P-Pass_0.3.0-test.4_macos-arm64.app.tar.gz \
  && has_asset P-Pass_0.3.0-test.4_macos-arm64.dmg \
  && has_asset P-Pass_0.3.0-test.4_x64-setup.exe \
  && ! has_asset P-Pass_0.3.0-test.3_android.apk \
  && ! has_asset P-Pass_0.2.0-test.2_android.apk \
  && has_asset SHA256SUMS-macos-arm64; } \
  && ok "按被清单指向的版本保留安装包；无版本号文件不动" || bad "安装包保留 / 删除判错（rc=${RC}）" "${OUT}$(ls "$CH")"
{ has_draft v0.3.0-test.4 && has_draft v0.3.0-test.3 \
  && ! has_draft v0.2.0-test.2 && ! has_draft v0.2.0-test.1 \
  && has_draft v0.3.0-test.5; } \
  && ok "旧 test 草稿只删没被指向且比最新被指向版本旧的；更新的不动" || bad "test 草稿删留判错" "${OUT}$(find "$STUB_STATE/releases" -name DRAFT)"
BEFORE=$(cd "$CH" && ls | sort)$'\n'$(find "$STUB_STATE/releases" -maxdepth 1 -name 'v*' | sort)
run_cleanup v0.3.0-test.4
AFTER=$(cd "$CH" && ls | sort)$'\n'$(find "$STUB_STATE/releases" -maxdepth 1 -name 'v*' | sort)
{ [ "${RC}" = 0 ] && [ "${BEFORE}" = "${AFTER}" ]; } \
  && ok "再跑一遍结果相同（幂等）" || bad "第二次运行结果变了（rc=${RC}）" "${OUT}"

# 非 test tag：直接退出，不删
reset_channel
asset P-Pass_0.1.0-test.1_android.apk old
draft v0.1.0-test.1
run_cleanup v2026.11.1
{ [ "${RC}" = 0 ] && has_asset P-Pass_0.1.0-test.1_android.apk && has_draft v0.1.0-test.1; } \
  && ok "非 test tag ⇒ 退出 0、什么都不删" || bad "非 test tag 删了东西（rc=${RC}）" "${OUT}"

# 没有任何清单：不删（拿不准就保留）
reset_channel
asset P-Pass_0.1.0-test.1_android.apk old
draft v0.1.0-test.1
run_cleanup v0.3.0-test.4
{ [ "${RC}" = 0 ] && has_asset P-Pass_0.1.0-test.1_android.apk && has_draft v0.1.0-test.1; } \
  && ok "通道里没有清单 ⇒ 退出 0、什么都不删" || bad "没有清单时仍然删除（rc=${RC}）" "${OUT}"

# 本次 run 自己的 tag 比通道旧（补跑旧 tag）：不能删自己的草稿与 tag
reset_channel
manifest manifest-android.json 0.3.0-test.4
manifest manifest-macos.json 0.3.0-test.4
manifest manifest-windows.json 0.3.0-test.4
manifest manifest-ios.json 0.3.0-test.4
draft v0.3.0-test.3
draft v0.2.0-test.2
run_cleanup v0.3.0-test.3
{ [ "${RC}" = 0 ] && has_draft v0.3.0-test.3 && ! has_draft v0.2.0-test.2; } \
  && ok "补跑比通道旧的 tag：不删本次 run 自己的草稿 / tag，别的旧草稿照删" \
  || bad "补跑旧 tag 时删了自己的草稿 / tag（rc=${RC}）" "${OUT}$(find "$STUB_STATE/releases" -name DRAFT)"

# 通道不存在：退出 0
rm -rf "$STUB_STATE/releases/test-channel"
run_cleanup v0.3.0-test.4
{ [ "${RC}" = 0 ] && printf '%s' "${OUT}" | grep -q "不存在"; } \
  && ok "test-channel 不存在 ⇒ 退出 0" || bad "test-channel 不存在时没有安全退出（rc=${RC}）" "${OUT}"

echo "release.yml（唯一收敛 job；失败只告警；writer 仍 fail-closed）"
W="$ROOT/.github/workflows/release.yml"
P="$ROOT/tools/release/point-test-channel.sh"
if ! python3 -c 'import yaml' 2>/dev/null; then
  bad "需要 PyYAML 才能读 release.yml"
else
  WF_OUT=$(python3 - "$W" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
jobs = wf["jobs"]
callers = []
for jid, job in jobs.items():
    for st in job.get("steps") or []:
        if "cleanup-test-channel.sh" in str(st.get("run", "")):
            callers.append(jid)
print("CALLERS=" + " ".join(callers))
job = jobs.get("cleanup-test-channel") or {}
print("HAS_JOB=" + ("1" if job else "0"))
print("NAME=" + str(job.get("name", "")))
print("NEEDS=" + " ".join(job.get("needs") or []))
print("CONTINUE=" + str(job.get("continue-on-error", "")).lower())
writers = ["upload-android", "finalize-manifest", "finalize-manifest-windows", "finalize-ios", "upload-macos"]
print("WRITER_CONTINUE=" + " ".join(w for w in writers if str((jobs.get(w) or {}).get("continue-on-error", "")).lower() == "true"))
print("WRITER_CALLERS=" + " ".join(w for w in writers for st in (jobs.get(w) or {}).get("steps") or [] if "cleanup-test-channel.sh" in str(st.get("run", ""))))
PY
)
  CALLERS=$(printf '%s\n' "$WF_OUT" | sed -n 's/^CALLERS=//p')
  HAS_JOB=$(printf '%s\n' "$WF_OUT" | sed -n 's/^HAS_JOB=//p')
  NAME=$(printf '%s\n' "$WF_OUT" | sed -n 's/^NAME=//p')
  NEEDS=$(printf '%s\n' "$WF_OUT" | sed -n 's/^NEEDS=//p')
  CONTINUE=$(printf '%s\n' "$WF_OUT" | sed -n 's/^CONTINUE=//p')
  WRITER_CONTINUE=$(printf '%s\n' "$WF_OUT" | sed -n 's/^WRITER_CONTINUE=//p')
  WRITER_CALLERS=$(printf '%s\n' "$WF_OUT" | sed -n 's/^WRITER_CALLERS=//p')
  { [ "$HAS_JOB" = 1 ] && [ "${CALLERS}" = "cleanup-test-channel" ] && [ -z "${WRITER_CALLERS}" ]; } \
    && ok "全仓只有一个 job 调收敛脚本，四个 writer 都不调（反证 ①：放回 writer ⇒ 红）" \
    || bad "收敛脚本的调用点不对（callers=「${CALLERS}」writer_callers=「${WRITER_CALLERS}」）"
  MISSING=""
  for w in upload-android finalize-manifest finalize-manifest-windows finalize-ios; do
    case " ${NEEDS} " in *" $w "*) ;; *) MISSING="${MISSING} $w" ;; esac
  done
  if [ -z "${MISSING}" ]; then ok "收敛 job 等全部四个 writer：${NEEDS}"; else bad "收敛 job 的 needs 少了 writer：${MISSING}（现在：${NEEDS}）"; fi
  case "${NAME}" in *test-channel*|*收敛*) ok "job name 写死且可读：${NAME}" ;; *) bad "job name 不对：${NAME}" ;; esac
  [ "$CONTINUE" = true ] && ok "收敛 job 级 continue-on-error: true（基础设施失败也不判红）" || bad "收敛 job 没有 continue-on-error"
  [ -z "${WRITER_CONTINUE}" ] && ok "writer job 都不带 continue-on-error（上传/指向失败仍红，反证 ③）" || bad "writer job 带了 continue-on-error：${WRITER_CONTINUE}"

  # 从 workflow 抽收敛步骤的 run 块，用一定失败的脚本执行：必须 warning + 退出 0（反证 ②）
  RUNBLOCK="$TMP/cleanup-step.sh"
  python3 - "$W" "$RUNBLOCK" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
for st in wf["jobs"]["cleanup-test-channel"]["steps"]:
    if "cleanup-test-channel.sh" in str(st.get("run", "")):
        open(sys.argv[2], "w", encoding="utf-8").write(st["run"] + "\n")
        break
else:
    sys.exit(3)
PY
  if [ -s "$RUNBLOCK" ]; then
    mkdir -p "$TMP/fake/tools/release"
    printf '#!/usr/bin/env bash\necho "boom: 收敛失败" >&2\nexit 7\n' > "$TMP/fake/tools/release/cleanup-test-channel.sh"
    chmod +x "$TMP/fake/tools/release/cleanup-test-channel.sh"
    STEP_OUT=$(cd "$TMP/fake" && bash "$RUNBLOCK" 2>&1); STEP_RC=$?
    { [ "${STEP_RC}" = 0 ] && printf '%s' "${STEP_OUT}" | grep -q "::warning::" \
      && printf '%s' "${STEP_OUT}" | grep -q "收敛失败"; } \
      && ok "收敛脚本失败 ⇒ 步骤退出 0 且打 ::warning::（反证 ②：改成直接执行 ⇒ 红）" \
      || bad "收敛失败没有降级为 warning（rc=${STEP_RC}）" "${STEP_OUT}"
  else
    bad "抽不出收敛步骤的 run 块"
  fi

  # 写路径不许有删除命令（反证 ①：把清理塞回 point 脚本 ⇒ 红）
  if grep -vE '^[[:space:]]*#' "$P" | grep -Eq 'release[[:space:]]+delete(-asset)?|cleanup-test-channel\.sh'; then
    bad "point-test-channel.sh 里仍有删除 / 收敛调用"
  else
    ok "point-test-channel.sh 里没有删除命令，也不调收敛脚本"
  fi
fi

echo
echo "通过 ${PASS} / 失败 ${FAIL}"
[ "$FAIL" = 0 ]
