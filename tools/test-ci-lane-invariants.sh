#!/usr/bin/env bash
# #1489：#1468「Windows 挪到合入 main 后、PR 上只跑快检」的不变量，此前只有 actionlint 管语法，改坏了 CI 照绿。
#
# 判据（读 .github/workflows 下五条 lane 的 YAML：ci-rust / ci-desktop / ci-android / ci-ios / ci-docs，
# 以及 ci-desktop 引用的共享 action .github/actions/desktop-checks/action.yml）：
#   1. 每条 lane 的 on.push.branches 恰为 [main]（合入 main 后批量跑全量的入口）；
#   2. 每条 lane 的 concurrency.cancel-in-progress 以 `${{ github.event_name != 'push'` 开头、其后只许接 `&&` 合取项
#      或直接收尾、整式不许出现 `||`（push 上恒为 false：正在跑的不取消、排队只留最新）；字面量 true、缺了这一项都红；
#   3. 这五个文件里 runs-on 含 windows 的 job，if 必须以 `${{ !cancelled() && github.event_name != 'pull_request' &&`
#      开头、整式不许出现 `||`（顶层合取项，PR 上 job 层跳过、汇报 skipped）；且 test (windows)、clippy (windows)、
#      desktop (windows-latest) 三个名字写死的 job 必须都在（防删 job 后断言落空还报绿）。
#   4. #1555：Linux 桌面检查整个摘掉（产品不发 Linux 包）。ci-desktop.yml 不许再有 desktop-linux job、
#      不许再汇报 `desktop (ubuntu-latest)` 这个检查名，gate.needs 也不许再要它；共享 action 里的
#      `Install cargo-deny`、`License and bans audit (src-tauri)`、`Advisory audit (…)`、`vite build (UI)`
#      四步必须存在且**不带任何 `if:`**（跟着 desktop-windows 无条件跑——判的是 Cargo.lock / advisory DB /
#      Node 产物，与 runner 平台无关）；整个 action 不许有按 Linux 分支的步骤，`System deps (tauri v2 on Linux)`
#      不许回来。两条必需检查名（`desktop (windows-latest)`、`CI Desktop gate`）与 gate 的 `if: always()`
#      也在断言里（一个字不能改）。
#   5. #1556：release.yml 有 workflow 级 concurrency——tag 含 `-test.` 的 test 发布固定到
#      key `test-channel`、cancel-in-progress: false（新 run 排队等前一个跑完，不取消）；
#      stable 发布用另一个 key。两个 test tag 必须同组，test 与 stable 必须不同组。
#   6. #2019：release.yml 调本地可复用 workflow（`uses: ./.github/workflows/*.yml`）时，
#      被调方（workflow 顶层与每个子 job）申请的权限等级不得超过 caller 授予的等级
#      （none < read < write）。GitHub 在 run 启动前静态校验，越级时整次 run 直接
#      startup_failure——0 个 job、没有任何日志。反证：给 ci-docs.yml 的 acceptance-gate
#      加回 `issues: read`，或把所有子 job 都显式写 `contents: read` 再在顶层加 `issues: read`，
#      都必须判红（#2021）。
# YAML 1.1 把键 `on` 读成布尔 True，取触发表按 d.get('on', d.get(True)) 两头都认。
# 缺 PyYAML 一律判红（exit 1），不 SKIP。
# 反证：在临时目录里复制 workflows 与 desktop-checks action 造变异（去掉 Windows job 的 pull_request 条件 / 某条 lane 的
# cancel-in-progress 改 true / 删掉某条 lane 的 push 触发 / push.branches 改成别的分支 / 删掉一个 Windows job /
# 改掉必需检查名 / 把 desktop-linux job 加回来 / 给 cargo-deny 或 vite build 加回 `if: runner.os == 'Linux'` /
# 把 System deps 加回来 / gate.needs 加回 desktop-linux / 去掉 gate 的 if: always()），每种都必须判红；
# 原样必须判绿。
#
# 用法: tools/test-ci-lane-invariants.sh
# 退出码: 0 全过 / 1 有失败
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

fail=0
ok() { echo "  ✅ $1"; }
ko() { echo "  ❌ $1"; fail=1; }

if ! python3 -c 'import yaml' 2>/dev/null; then
  echo "  ❌ python3 缺 PyYAML，无法读 workflow YAML（不 SKIP：装上 PyYAML 再跑）"
  exit 1
fi

# check <仓库根>：有问题逐条打印到 stdout，退出码 1；全过退出 0、不打印。
check() {
  python3 - "$1" "$ROOT/tools/ci-paths.sh" <<'PY'
import os, re, subprocess, sys, yaml

root = sys.argv[1]
wf = os.path.join(root, ".github", "workflows")
action_path = os.path.join(root, ".github", "actions", "desktop-checks", "action.yml")
LANES = ["ci-rust.yml", "ci-desktop.yml", "ci-android.yml", "ci-ios.yml", "ci-docs.yml"]
WIN_NAMES = {"test (windows)", "clippy (windows)", "desktop (windows-latest)"}
CANCEL_RE = re.compile(r"^\$\{\{\s*github\.event_name\s*!=\s*'push'\s*(&&[^|]*)?\}\}$", re.S)
WIN_IF_RE = re.compile(r"^\$\{\{\s*!cancelled\(\)\s*&&\s*github\.event_name\s*!=\s*'pull_request'\s*&&", re.S)
# #1556：release.yml workflow 级 concurrency.group 的形态：test → 固定 key，其余 → 另一 key。
RELEASE_GROUP_RE = re.compile(
    r"^\$\{\{\s*contains\(inputs\.tag,\s*'-test\.'\)\s*&&\s*'([^']+)'\s*\|\|\s*"
    r"format\('([^']*)\{0\}',\s*inputs\.tag\)\s*\}\}$",
    re.S,
)
DESKTOP_WIN_NAME = "desktop (windows-latest)"
DESKTOP_GATE_NAME = "CI Desktop gate"
# #1555：这四步原来带 `if: runner.os == 'Linux'`，现在跟着 desktop-windows 无条件跑。
PORTABLE_STEPS = {
    "Install cargo-deny",
    "License and bans audit (src-tauri)",
    "Advisory audit (src-tauri, only when its Cargo.lock / deny.toml changed)",
    "vite build (UI)",
}
bad = []
seen_win = set()

for lane in LANES:
    path = os.path.join(wf, lane)
    try:
        with open(path, encoding="utf-8") as f:
            d = yaml.safe_load(f)
    except Exception as e:  # 读不到、解析不了都判红
        bad.append(f"{lane}: 读不出 YAML（{e}）")
        continue
    if not isinstance(d, dict):
        bad.append(f"{lane}: 顶层不是映射")
        continue

    on = d.get("on", d.get(True))
    push = on.get("push") if isinstance(on, dict) else None
    branches = push.get("branches") if isinstance(push, dict) else None
    if branches != ["main"]:
        bad.append(f"{lane}: on.push.branches 应为 [main]，实为 {branches!r}")

    conc = d.get("concurrency")
    cip = conc.get("cancel-in-progress") if isinstance(conc, dict) else None
    if not isinstance(cip, str) or not CANCEL_RE.match(cip.strip()):
        bad.append(f"{lane}: concurrency.cancel-in-progress 应以 github.event_name != 'push' 为顶层合取项（push 上为 false），实为 {cip!r}")

    jobs = d.get("jobs") or {}
    for key, job in jobs.items():
        if not isinstance(job, dict):
            continue
        runs_on = job.get("runs-on")
        if "windows" not in str(runs_on).lower():
            continue
        name = job.get("name", key)
        seen_win.add(name)
        cond = job.get("if")
        if not isinstance(cond, str) or not WIN_IF_RE.match(cond.strip()) or "||" in cond:
            bad.append(f"{lane}: Windows job「{name}」的 if 没有以 github.event_name != 'pull_request' 为顶层合取项（PR 上会跑），实为 {cond!r}")

    if lane == "ci-docs.yml":
        steps = jobs.get("changes", {}).get("steps", [])
        paths = next((step.get("with", {}).get("paths", "") for step in steps if step.get("id") == "c"), "")
        globs = [line.strip() for line in paths.splitlines() if line.strip() and not line.lstrip().startswith("#")]
        for name in ("AGENTS.md", "CLAUDE.md"):
            if not globs or subprocess.run(
                ["bash", sys.argv[2], "hit", "-", *globs], input=name + "\n",
                capture_output=True, text=True, check=True,
            ).stdout.strip() != "true":
                bad.append(f"ci-docs.yml: only changing {name} must run the docs check")

    # #1555：Linux 桌面 job 必须没有；桌面检查只剩 Windows。
    if lane == "ci-desktop.yml":
        for key, job in jobs.items():
            jname = job.get("name", key) if isinstance(job, dict) else None
            if key == "desktop-linux" or jname == "desktop (ubuntu-latest)":
                bad.append(
                    f"ci-desktop.yml: 不许再有 desktop-linux job /「desktop (ubuntu-latest)」检查名"
                    f"（#1555 已永久移除 Linux 桌面检查），实为 job「{key}」name={jname!r}"
                )
        win = jobs.get("desktop-windows")
        if not isinstance(win, dict):
            bad.append(f"ci-desktop.yml: 缺 desktop-windows job（{DESKTOP_WIN_NAME} 是必需检查）")
        else:
            if win.get("name") != DESKTOP_WIN_NAME:
                bad.append(f"ci-desktop.yml: desktop-windows 的 name 应为「{DESKTOP_WIN_NAME}」，实为 {win.get('name')!r}")
            steps = win.get("steps") or []
            uses = [str(s.get("uses", "")) for s in steps if isinstance(s, dict)]
            if "./.github/actions/desktop-checks" not in uses:
                bad.append("ci-desktop.yml: desktop-windows 必须引用 ./.github/actions/desktop-checks（所有桌面步骤都在那里）")
        gate = jobs.get("gate")
        if not isinstance(gate, dict):
            bad.append(f"ci-desktop.yml: 缺 gate job（{DESKTOP_GATE_NAME} 是必需检查）")
        else:
            if gate.get("name") != DESKTOP_GATE_NAME:
                bad.append(f"ci-desktop.yml: gate 的 name 应为「{DESKTOP_GATE_NAME}」，实为 {gate.get('name')!r}")
            if gate.get("if") != "always()":
                bad.append(f"ci-desktop.yml: gate 的 if 必须是 always()，实为 {gate.get('if')!r}")
            needs = gate.get("needs")
            if not isinstance(needs, list):
                bad.append(f"ci-desktop.yml: gate.needs 必须是列表，实为 {needs!r}")
            else:
                if "desktop-linux" in needs:
                    bad.append(f"ci-desktop.yml: gate.needs 不许再有 desktop-linux，实为 {needs!r}")
                if not {"changes", "desktop-windows"} <= set(needs):
                    bad.append(f"ci-desktop.yml: gate.needs 必须含 changes / desktop-windows，实为 {needs!r}")

missing = WIN_NAMES - seen_win
if missing:
    bad.append("缺 Windows job：" + "、".join(sorted(missing)))

# #1555：共享 action 里的 Linux-only 判断与系统依赖必须没有了。
try:
    with open(action_path, encoding="utf-8") as f:
        action = yaml.safe_load(f)
except Exception as e:
    bad.append(f"desktop-checks/action.yml: 读不出 YAML（{e}）")
    action = None
if isinstance(action, dict):
    steps = ((action.get("runs") or {}).get("steps")) or []
    if not isinstance(steps, list):
        bad.append("desktop-checks/action.yml: runs.steps 不是列表")
        steps = []
    found = set()
    for step in steps:
        if not isinstance(step, dict):
            continue
        name = step.get("name")
        cond = step.get("if")
        if isinstance(name, str) and name.startswith("System deps"):
            bad.append(f"desktop-checks/action.yml:「{name}」应随 desktop-linux 一起删除，不许回来")
        if isinstance(cond, str) and "Linux" in cond:
            bad.append(f"desktop-checks/action.yml: 步骤「{name}」不该再按 Linux 分支，实为 if: {cond!r}")
        if name in PORTABLE_STEPS:
            found.add(name)
            if "if" in step:
                bad.append(
                    f"desktop-checks/action.yml: 步骤「{name}」必须无条件跑（跟 desktop-windows），不该有 if: {cond!r}"
                )
    absent = PORTABLE_STEPS - found
    if absent:
        bad.append("desktop-checks/action.yml: 缺步骤：" + "、".join(sorted(absent)))

# #1556：release.yml 的 workflow 级 concurrency：test 发布全局串行，stable 用不同 key。
try:
    with open(os.path.join(wf, "release.yml"), encoding="utf-8") as f:
        release = yaml.safe_load(f)
except Exception as e:
    bad.append(f"release.yml: 读不出 YAML（{e}）")
    release = None
if isinstance(release, dict):
    conc = release.get("concurrency")
    if not isinstance(conc, dict):
        bad.append(f"release.yml: 缺 workflow 级 concurrency（test-channel 需要全局串行），实为 {conc!r}")
    else:
        if conc.get("cancel-in-progress") is not False:
            bad.append(
                f"release.yml: concurrency.cancel-in-progress 必须为 false（排队不取消），实为 {conc.get('cancel-in-progress')!r}"
            )
        group = conc.get("group")
        m = RELEASE_GROUP_RE.match(group.strip()) if isinstance(group, str) else None
        if not m:
            bad.append(f"release.yml: concurrency.group 应把 test 发布固定到 test-channel、stable 用另一 key，实为 {group!r}")
        else:
            test_key, stable_fmt = m.group(1), m.group(2)

            def release_key(tag):
                return test_key if "-test." in tag else stable_fmt.replace("{0}", tag)

            if test_key != "test-channel":
                bad.append(f"release.yml: test 发布的 concurrency key 应为 test-channel，实为 {test_key!r}")
            if release_key("v1.2.3-test.1") != release_key("v1.2.3-test.2"):
                bad.append("release.yml: 两个不同 test tag 没有落在同一个 concurrency 组（不会串行）")
            if release_key("v1.2.3") == release_key("v1.2.3-test.1"):
                bad.append("release.yml: test 与 stable 落在同一个 concurrency 组（会互相阻塞）")

    # #2019：可复用 workflow 的权限天花板。caller job 的 permissions 决定上限（job 没写就
    # 继承 workflow 级），被调 workflow 的顶层与每个子 job 都只能等于或低于它；越级时
    # GitHub 在启动前就把整次 run 判成 startup_failure，不会留下任何 job 日志。
    LEVEL = {"none": 0, "read": 1, "write": 2}
    LEVEL_NAME = {v: k for k, v in LEVEL.items()}

    def perms_of(p):
        if p is None:
            return None
        if isinstance(p, str):
            # read-all / write-all 是每个 scope 都取该等级；其它写法按 none 处理。
            return {"*": p[:-4]} if p in ("read-all", "write-all") else {"*": "none"}
        if isinstance(p, dict):
            return {str(k): str(v) for k, v in p.items()}
        return {}

    def level_of(p, scope):
        if p is None:
            return 0
        raw = p[scope] if scope in p else p.get("*", "none")
        return LEVEL.get(raw, 0)

    for caller_key, caller_job in (release.get("jobs") or {}).items():
        uses = caller_job.get("uses") if isinstance(caller_job, dict) else None
        if not isinstance(uses, str) or not uses.startswith("./.github/workflows/"):
            continue
        callee_name = uses.rsplit("/", 1)[-1]
        try:
            with open(os.path.join(wf, callee_name), encoding="utf-8") as f:
                callee = yaml.safe_load(f)
        except Exception as e:
            bad.append(f"release.yml: job「{caller_key}」调用的 {callee_name} 读不出 YAML（{e}）")
            continue
        if not isinstance(callee, dict):
            bad.append(f"release.yml: job「{caller_key}」调用的 {callee_name} 顶层不是映射")
            continue
        caller_perms = perms_of(caller_job.get("permissions", release.get("permissions")))
        # #2021：若被调 workflow 顶层声明了 permissions，即使所有子 job 都显式覆盖了 permissions，
        # 顶层声明仍受 caller 上限约束，单独比较一次防止漏判。
        if "permissions" in callee:
            top_perms = perms_of(callee.get("permissions"))
            for scope in sorted(set(caller_perms or {}) | set(top_perms or {})):
                granted, asked = level_of(caller_perms, scope), level_of(top_perms, scope)
                if asked > granted:
                    bad.append(
                        f"release.yml: job「{caller_key}」调用 {callee_name} 的顶层 permissions "
                        f"申请 {scope}: {LEVEL_NAME[asked]}，超过 caller 授予的 {LEVEL_NAME[granted]}"
                        f"（GitHub 启动校验会判 startup_failure：删掉被调方的越级权限，不给 caller 扩权）"
                    )
        for callee_key, callee_job in (callee.get("jobs") or {}).items():
            if not isinstance(callee_job, dict):
                continue
            callee_perms = perms_of(callee_job.get("permissions", callee.get("permissions")))
            scopes = set(caller_perms or {}) | set(callee_perms or {})
            for scope in sorted(scopes):
                granted, asked = level_of(caller_perms, scope), level_of(callee_perms, scope)
                if asked > granted:
                    bad.append(
                        f"release.yml: job「{caller_key}」调用 {callee_name} 的 job「{callee_key}」"
                        f"申请 {scope}: {LEVEL_NAME[asked]}，超过 caller 授予的 {LEVEL_NAME[granted]}"
                        f"（GitHub 启动校验会判 startup_failure：删掉被调方的越级权限，不给 caller 扩权）"
                    )

for b in bad:
    print(b)
sys.exit(1 if bad else 0)
PY
}

echo "== 原样：五条 lane、桌面 action 与 release.yml 的 concurrency 不变量都成立 =="
if out="$(check "$ROOT")"; then
  ok "原样判绿"
else
  ko "原样判红："
  printf '%s\n' "$out" | sed 's/^/      /'
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# mutant <说明> <相对仓库根的路径> <sed 表达式>：复制一份 workflows + 桌面 action，
# 对一个文件做 sed 变异，必须判红。
mutant() {
  local desc="$1" file="$2" expr="$3" dir
  dir="$TMP/m$RANDOM$RANDOM"
  mkdir -p "$dir/.github/workflows" "$dir/.github/actions/desktop-checks"
  cp "$ROOT"/.github/workflows/*.yml "$dir/.github/workflows/"
  cp "$ROOT/.github/actions/desktop-checks/action.yml" "$dir/.github/actions/desktop-checks/"
  sed -E "$expr" "$dir/$file" > "$dir/$file.new" && mv "$dir/$file.new" "$dir/$file"
  if cmp -s "$dir/$file" "$ROOT/$file"; then
    ko "变异没生效（sed 没改到东西）：$desc"
    return
  fi
  if out="$(check "$dir")"; then
    ko "变异未判红：$desc"
  else
    ok "变异判红：$desc → $(printf '%s' "$out" | head -1)"
  fi
}

echo "== 反证：每种变异都必须判红 =="
mutant "test (windows) 去掉 pull_request 跳过条件" .github/workflows/ci-rust.yml \
  "/name: test \\(windows\\)/,/runs-on/ s/ github\\.event_name != 'pull_request' &&//"
mutant "clippy (windows) 去掉 pull_request 跳过条件" .github/workflows/ci-rust.yml \
  "/name: clippy \\(windows\\)/,/runs-on/ s/ github\\.event_name != 'pull_request' &&//"
mutant "desktop (windows-latest) 去掉 pull_request 跳过条件" .github/workflows/ci-desktop.yml \
  "/name: desktop \\(windows-latest\\)/,/runs-on/ s/ github\\.event_name != 'pull_request' &&//"
mutant "desktop (windows-latest) 整个 job 删掉" .github/workflows/ci-desktop.yml \
  "/^  desktop-windows:/,/^  [a-z][a-z0-9-]*:\$/{/^  desktop-windows:/d;/^  [a-z][a-z0-9-]*:\$/!d;}"
mutant "desktop (windows-latest) 改名字" .github/workflows/ci-desktop.yml \
  "s/^    name: desktop \\(windows-latest\)\$/    name: desktop (windows)/"
mutant "ci-docs misses changes to CLAUDE.md" .github/workflows/ci-docs.yml \
  '/^            CLAUDE\.md$/d'
mutant "ci-docs 的 cancel-in-progress 改 true" .github/workflows/ci-docs.yml \
  "s/^  cancel-in-progress: .*/  cancel-in-progress: true/"
mutant "ci-ios 的 cancel-in-progress 去掉 push 那一项" .github/workflows/ci-ios.yml \
  "s/cancel-in-progress: \\\$\\{\\{ github\\.event_name != 'push' && /cancel-in-progress: \${{ /"
mutant "ci-rust 的 cancel-in-progress 末尾接 || true" .github/workflows/ci-rust.yml \
  "s/^(  cancel-in-progress: .*) \\}\\}\$/\\1 || true }}/"
mutant "ci-android 删掉 push 触发" .github/workflows/ci-android.yml \
  "/^  push:\$/,/^    branches: \\[main\\]\$/d"
mutant "ci-rust 的 push.branches 改成 develop" .github/workflows/ci-rust.yml \
  "/^  push:\$/,/^    branches:/ s/branches: \\[main\\]/branches: [develop]/"
mutant "desktop-linux job 加回来" .github/workflows/ci-desktop.yml \
  "s/^  changes:\$/  desktop-linux:\n    name: desktop (ubuntu-latest)\n    runs-on: ubuntu-latest\n  changes:/"
mutant "Install cargo-deny 加回 runner.os == 'Linux'" .github/actions/desktop-checks/action.yml \
  "s/^(    - name: Install cargo-deny)\$/\\1\n      if: runner.os == 'Linux'/"
mutant "vite build (UI) 加回 runner.os == 'Linux'" .github/actions/desktop-checks/action.yml \
  "s/^(    - name: vite build \\(UI\\))\$/\\1\n      if: runner.os == 'Linux'/"
mutant "System deps (tauri v2 on Linux) 加回来" .github/actions/desktop-checks/action.yml \
  "s/^(    - name: Stub sidecar)\$/    - name: System deps (tauri v2 on Linux)\n      shell: bash\n      run: echo apt\n\\1/"
mutant "gate.needs 加回 desktop-linux" .github/workflows/ci-desktop.yml \
  "s/^    needs: \\[changes, desktop-windows\\]\$/    needs: [changes, desktop-linux, desktop-windows]/"
mutant "CI Desktop gate 去掉 if: always()" .github/workflows/ci-desktop.yml \
  "/^  gate:/,/^    runs-on:/ s/^    if: always\\(\\)\$/    if: false/"
mutant "CI Desktop gate 改名字" .github/workflows/ci-desktop.yml \
  "s/^    name: CI Desktop gate\$/    name: CI Desktop Gate/"

mutant "release.yml 去掉 workflow 级 concurrency" .github/workflows/release.yml \
  "/^concurrency:\$/,/^jobs:\$/d"
mutant "release.yml 的 cancel-in-progress 改成 true" .github/workflows/release.yml \
  "s/^  cancel-in-progress: false\$/  cancel-in-progress: true/"
mutant "release.yml 的 test 匹配条件改成 stable" .github/workflows/release.yml \
  "s/'-test.'/'-stable.'/"
mutant "release.yml 的 stable 也并进 test-channel 组" .github/workflows/release.yml \
  "s/format\('release-stable-.*inputs\.tag\)/'test-channel'/"
mutant "ci-docs 的 acceptance-gate 加回越级的 issues: read" .github/workflows/ci-docs.yml \
  "/^  acceptance-gate:\$/,/^    steps:\$/ s/^      contents: read\$/      contents: read\n      issues: read/"

# #2021：构造「被调 workflow 顶层越级（加 issues: read）+ 所有子 job 均显式写 contents: read」，
# 覆盖「没有任何子 job 继承顶层 permissions 时，顶层越级仍必须被抓到」。
mutant_callee_top_perm() {
  local desc="$1" dir
  dir="$TMP/m$RANDOM$RANDOM"
  mkdir -p "$dir/.github/workflows" "$dir/.github/actions/desktop-checks"
  cp "$ROOT"/.github/workflows/*.yml "$dir/.github/workflows/"
  cp "$ROOT/.github/actions/desktop-checks/action.yml" "$dir/.github/actions/desktop-checks/"
  python3 - "$dir/.github/workflows/ci-docs.yml" <<'PY'
import sys, yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    d = yaml.safe_load(f)
d["permissions"] = {"contents": "read", "issues": "read"}
for job in (d.get("jobs") or {}).values():
    if isinstance(job, dict):
        job["permissions"] = {"contents": "read"}
with open(path, "w", encoding="utf-8") as f:
    yaml.safe_dump(d, f, allow_unicode=True, sort_keys=False)
PY
  if cmp -s "$dir/.github/workflows/ci-docs.yml" "$ROOT/.github/workflows/ci-docs.yml"; then
    ko "变异没生效：${desc}"
    return
  fi
  if out="$(check "$dir")"; then
    ko "变异未判红：${desc}"
  else
    ok "变异判红：${desc} → $(printf '%s' "$out" | head -1)"
  fi
}
mutant_callee_top_perm "ci-docs 所有子 job 显式 contents: read 且顶层加越级的 issues: read"

if [ "$fail" -eq 0 ]; then
  echo "== ci-lane-invariants: green ✅ =="
else
  echo "== ci-lane-invariants: RED ❌ =="
fi
exit "$fail"
