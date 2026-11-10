#!/usr/bin/env bash
# #1595：CI 与发布链「外部下载不再被 GitHub 抖动卡住」的不变量（方案 docs/decisions/2026-11-10-ci-download-resilience.md）。
#
# 判据（读仓里的实际文件，不读思路）：
#   1. 跑 Gradle 的每条 workflow（含 gradle/actions/setup-gradle 的：ci-android / audit-deps / release / e2e）
#      都必须接 ./.github/actions/gradle-wrapper-cache，并且有一个 actions/cache/save 步骤同时满足
#      「if 带 success()」与「key 取 steps.gradle-dist.outputs.key」——否则每次都从 services.gradle.org
#      现拉发行版，GitHub 抖动时把 job / 发版卡住；没有 success() 又会把半截下载存进缓存。
#   2. tools/fetch-ffmpeg.sh 的下载必须带 `curl -fL --retry 5 --retry-delay 2 --retry-all-errors`，
#      且 verify_sha256 校验还在——重试不能换来「校验被绕开」。
# 反证：把 workflows 与 fetch-ffmpeg.sh 复制到临时目录做变异（删缓存 action / 去掉 success() /
#       e2e 删缓存 action / 去掉 --retry-all-errors / --retry 5 改 0 / 校验函数改名），
#       每种都必须判红；原样必须判绿。
#
# 用法: tools/test-ci-download-resilience.sh
# 退出码: 0 全过 / 1 有失败
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

fail=0
ok() { echo "  ✅ $1"; }
ko() { echo "  ❌ $1"; fail=1; }

# check <仓库根>：有问题逐条打印到 stdout，退出码 1；全过退出 0、不打印。
check() {
  python3 -I - "$1" <<'PY'
import glob, os, sys

root = sys.argv[1]
bad = []

for path in sorted(glob.glob(os.path.join(root, ".github", "workflows", "*.yml"))):
    text = open(path, encoding="utf-8").read()
    if "gradle/actions/setup-gradle" not in text:
        continue
    name = os.path.basename(path)
    if "uses: ./.github/actions/gradle-wrapper-cache" not in text:
        bad.append(f"{name}: 跑 Gradle 却没接 ./.github/actions/gradle-wrapper-cache（发行版每次都现拉）")
    lines = text.splitlines()
    saved = False
    for i, line in enumerate(lines):
        if "actions/cache/save" in line:
            # if: 写在 uses: 前面，窗口往前多取几行才能把这一步的 if 一起看到。
            block = "\n".join(lines[max(0, i - 6):i + 9])
            if "steps.gradle-dist.outputs.key" in block and "success()" in block:
                saved = True
    if not saved:
        bad.append(
            f"{name}: 没有「只在 job 成功时保存」的发行版缓存步"
            "（actions/cache/save + if: success() + steps.gradle-dist.outputs.key）"
        )

fetch = os.path.join(root, "tools", "fetch-ffmpeg.sh")
text = open(fetch, encoding="utf-8").read()
if "curl -fL --retry 5 --retry-delay 2 --retry-all-errors" not in text:
    bad.append("tools/fetch-ffmpeg.sh: 下载不是 curl -fL --retry 5 --retry-delay 2 --retry-all-errors")
if "verify_sha256" not in text:
    bad.append("tools/fetch-ffmpeg.sh: sha256 校验函数没了（重试不能换掉校验）")

for b in bad:
    print(b)
sys.exit(1 if bad else 0)
PY
}

echo "== 原样：Gradle 缓存接线与 fetch-ffmpeg 重试都成立 =="
if out="$(check "$ROOT")"; then
  ok "原样判绿"
else
  ko "原样判红："
  printf '%s\n' "$out" | sed 's/^/      /'
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# mutant <说明> <相对仓库根的文件> <sed 表达式>：复制一份 workflows 与 fetch-ffmpeg.sh，
# 对一个文件做 sed 变异，必须判红。
mutant() {
  local desc="$1" file="$2" expr="$3" dir
  dir="$TMP/m$RANDOM$RANDOM"
  mkdir -p "$dir/.github/workflows" "$dir/tools"
  cp "$ROOT"/.github/workflows/*.yml "$dir/.github/workflows/"
  cp "$ROOT/tools/fetch-ffmpeg.sh" "$dir/tools/"
  sed -E "$expr" "$dir/$file" >"$dir/$file.new" && mv "$dir/$file.new" "$dir/$file"
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
mutant "release.yml 删掉缓存 action" .github/workflows/release.yml \
  "/gradle-wrapper-cache/d"
mutant "release.yml 的保存步去掉 success()" .github/workflows/release.yml \
  "s/if: success\\(\\) && steps\\.gradle-dist/if: always() \&\& steps.gradle-dist/"
mutant "e2e.yml 删掉缓存 action" .github/workflows/e2e.yml \
  "/gradle-wrapper-cache/d"
mutant "audit-deps.yml 删掉缓存 action" .github/workflows/audit-deps.yml \
  "/gradle-wrapper-cache/d"
mutant "fetch-ffmpeg.sh 去掉 --retry-all-errors" tools/fetch-ffmpeg.sh \
  "s/ --retry-all-errors//"
mutant "fetch-ffmpeg.sh 把 --retry 5 改成 0" tools/fetch-ffmpeg.sh \
  "s/--retry 5/--retry 0/"
mutant "fetch-ffmpeg.sh 去掉 sha256 校验" tools/fetch-ffmpeg.sh \
  "s/verify_sha256/verify_none/g"

if [ "$fail" -eq 0 ]; then
  echo "== ci-download-resilience: green ✅ =="
else
  echo "== ci-download-resilience: RED ❌ =="
fi
exit "$fail"
