#!/usr/bin/env bash
# #1489：#1468「Windows 挪到合入 main 后、PR 上只跑快检」的不变量，此前只有 actionlint 管语法，改坏了 CI 照绿。
#
# 判据（读 .github/workflows 下五条 lane 的 YAML：ci-rust / ci-desktop / ci-android / ci-ios / ci-docs）：
#   1. 每条 lane 的 on.push.branches 恰为 [main]（合入 main 后批量跑全量的入口）；
#   2. 每条 lane 的 concurrency.cancel-in-progress 以 `${{ github.event_name != 'push'` 开头、其后只许接 `&&` 合取项
#      或直接收尾、整式不许出现 `||`（push 上恒为 false：正在跑的不取消、排队只留最新）；字面量 true、缺了这一项都红；
#   3. 这五个文件里 runs-on 含 windows 的 job，if 必须以 `${{ !cancelled() && github.event_name != 'pull_request' &&`
#      开头、整式不许出现 `||`（顶层合取项，PR 上 job 层跳过、汇报 skipped）；且 test (windows)、clippy (windows)、
#      desktop (windows-latest) 三个名字写死的 job 必须都在（防删 job 后断言落空还报绿）。
# YAML 1.1 把键 `on` 读成布尔 True，取触发表按 d.get('on', d.get(True)) 两头都认。
# 缺 PyYAML 一律判红（exit 1），不 SKIP。
# 反证：在临时目录里复制 workflows 造变异（去掉 Windows job 的 pull_request 条件 / 某条 lane 的 cancel-in-progress
# 改 true / 删掉某条 lane 的 push 触发 / push.branches 改成别的分支 / 删掉一个 Windows job），每种都必须判红；原样必须判绿。
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

# check <workflows 目录>：有问题逐条打印到 stdout，退出码 1；全过退出 0、不打印。
check() {
  python3 - "$1" <<'PY'
import os, re, sys, yaml

wf = sys.argv[1]
LANES = ["ci-rust.yml", "ci-desktop.yml", "ci-android.yml", "ci-ios.yml", "ci-docs.yml"]
WIN_NAMES = {"test (windows)", "clippy (windows)", "desktop (windows-latest)"}
CANCEL_RE = re.compile(r"^\$\{\{\s*github\.event_name\s*!=\s*'push'\s*(&&[^|]*)?\}\}$", re.S)
WIN_IF_RE = re.compile(r"^\$\{\{\s*!cancelled\(\)\s*&&\s*github\.event_name\s*!=\s*'pull_request'\s*&&", re.S)
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

missing = WIN_NAMES - seen_win
if missing:
    bad.append("缺 Windows job：" + "、".join(sorted(missing)))

for b in bad:
    print(b)
sys.exit(1 if bad else 0)
PY
}

echo "== 原样：五条 lane 的不变量都成立 =="
if out="$(check "$ROOT/.github/workflows")"; then
  ok "原样判绿"
else
  ko "原样判红："
  printf '%s\n' "$out" | sed 's/^/      /'
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# mutant <说明> <文件> <sed 表达式>：复制一份 workflows，对一个文件做 sed 变异，必须判红。
mutant() {
  local desc="$1" file="$2" expr="$3" dir
  dir="$TMP/m$RANDOM$RANDOM"
  mkdir -p "$dir"
  cp "$ROOT"/.github/workflows/*.yml "$dir/"
  sed -E "$expr" "$dir/$file" > "$dir/$file.new" && mv "$dir/$file.new" "$dir/$file"
  if cmp -s "$dir/$file" "$ROOT/.github/workflows/$file"; then
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
mutant "test (windows) 去掉 pull_request 跳过条件" ci-rust.yml \
  "/name: test \\(windows\\)/,/runs-on/ s/ github\\.event_name != 'pull_request' &&//"
mutant "clippy (windows) 去掉 pull_request 跳过条件" ci-rust.yml \
  "/name: clippy \\(windows\\)/,/runs-on/ s/ github\\.event_name != 'pull_request' &&//"
mutant "desktop (windows-latest) 去掉 pull_request 跳过条件" ci-desktop.yml \
  "/name: desktop \\(windows-latest\\)/,/runs-on/ s/ github\\.event_name != 'pull_request' &&//"
mutant "desktop (windows-latest) 整个 job 删掉" ci-desktop.yml \
  "/^  desktop-windows:/,/^  [a-z][a-z0-9-]*:\$/{/^  desktop-windows:/d;/^  [a-z][a-z0-9-]*:\$/!d;}"
mutant "ci-docs 的 cancel-in-progress 改 true" ci-docs.yml \
  "s/^  cancel-in-progress: .*/  cancel-in-progress: true/"
mutant "ci-ios 的 cancel-in-progress 去掉 push 那一项" ci-ios.yml \
  "s/cancel-in-progress: \\\$\\{\\{ github\\.event_name != 'push' && /cancel-in-progress: \${{ /"
mutant "ci-rust 的 cancel-in-progress 末尾接 || true" ci-rust.yml \
  "s/^(  cancel-in-progress: .*) \\}\\}\$/\\1 || true }}/"
mutant "ci-android 删掉 push 触发" ci-android.yml \
  "/^  push:\$/,/^    branches: \\[main\\]\$/d"
mutant "ci-rust 的 push.branches 改成 develop" ci-rust.yml \
  "/^  push:\$/,/^    branches:/ s/branches: \\[main\\]/branches: [develop]/"

if [ "$fail" -eq 0 ]; then
  echo "== ci-lane-invariants: green ✅ =="
else
  echo "== ci-lane-invariants: RED ❌ =="
fi
exit "$fail"
