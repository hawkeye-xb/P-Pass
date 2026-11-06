#!/usr/bin/env bash
# just doctor：开工前环境自检。在执行者自己的外壳里跑；任一必需项不满足就非 0 退出，并打印怎么修。
# 用法: tools/flow/doctor.sh
#
# 必需项（任一不过 = 非 0，不许带病开工）：
#   1. 当前目录是主副本，或主副本的 worktree；不是 Windows 回归专用克隆（根目录有 .ppass-verify-clone）
#   2. bash 真能执行（Windows 上必须是 Git Bash，不能是没装发行版的 WSL 桩）
#   3. 本地提交拦截已装（复用 tools/hooks/install.sh --check）
#   4. gh 能读本仓库 issue
#   5. git 提交身份在 .github/allowed-identities.txt 里
#   6. 磁盘剩余 ≥ 15G
# 只报不判：
#   7. 私仓：主副本旁边的 ../private 存在 = 完整模式；不存在 = 协作者模式（不写不公开内容）
#   8. 在线设备（adb / devicectl）：只列，不判失败
#
# 测试用环境变量（平时不设）：PPASS_DOCTOR_MIN_FREE_GB 改磁盘下限、PPASS_DOCTOR_SKIP_DEVICES=1 不列设备、
# PPASS_HOOK_REPO 覆盖 owner/repo（与本地提交拦截同口径）。

set -uo pipefail

FAIL=0
ok() { printf '  ✅ %s\n' "$*"; }
warn() { printf '  ⚠ %s\n' "$*"; }
bad() {
  printf '  ✗ %s\n' "$*"
  FAIL=$((FAIL + 1))
}
fix() {
  local l
  for l in "$@"; do printf '      修：%s\n' "$l"; done
}

echo "==> 环境自检（just doctor）"

# ── 0. 得在一个 git 检出里，后面都靠它 ────────────────────────────────
TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "  ✗ 当前目录不在 git 仓库里"
  echo "      修：cd 到主副本（P-Pass）或它的卡 worktree 再跑 just doctor"
  exit 1
}
TOP="$(cd "$TOP" && pwd -P)"
COMMON="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
MAIN_ROOT="$(dirname "$COMMON")"
GIT_DIR="$(cd "$(git rev-parse --absolute-git-dir)" && pwd -P)"
BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"

# ── 1. 位置：主副本 / 主副本的 worktree；回归克隆有标记，拒绝 ─────────
if [ "$TOP" = "$MAIN_ROOT" ]; then
  ok "位置：主副本 ${MAIN_ROOT}"
elif [ "$GIT_DIR" != "$COMMON" ]; then
  ok "位置：主副本的 worktree ${TOP}（分支 ${BRANCH:-detached}）"
else
  bad "位置：当前目录不是主副本，也不是主副本的 worktree（${TOP}）"
  fix "cd 到主副本 ${MAIN_ROOT}，或 just start 给你的卡 worktree"
fi

if [ -e "${TOP}/.ppass-verify-clone" ] || [ -e "${MAIN_ROOT}/.ppass-verify-clone" ]; then
  bad "这是 Windows 回归专用克隆（根目录有 .ppass-verify-clone），不能当日常工作目录"
  fix "回主副本开工：cd ${MAIN_ROOT}" \
    "这个克隆只给 Windows 回归会话用；怎么建见 docs/runbook/full-regression-sop.md"
fi

# ── 2. bash 真能执行（Windows 上必须是 Git Bash，不是 WSL 桩）─────────
bash_bin="$(command -v bash 2>/dev/null || true)"
if [ -z "$bash_bin" ]; then
  bad "PATH 里没有 bash"
  fix "Windows：装 Git for Windows，把它的 bin 目录放进 PATH，用 Git Bash" \
    "macOS / Linux：确认 bash 在 PATH 上"
else
  bash_out="$("$bash_bin" -c 'printf ppass-bash-ok' 2>&1)" || bash_out=""
  if [ "$bash_out" != "ppass-bash-ok" ]; then
    bad "bash（${bash_bin}）不能真正执行：$(printf '%s' "$bash_out" | head -1)"
    fix "Windows 上这多半是没装发行版的 WSL 桩：装 Git for Windows，用 Git Bash 的 bash.exe" \
      "macOS / Linux：确认 ${bash_bin} 可执行，PATH 上的 bash 不是坏链接或占位脚本"
  elif [ "$(uname -s 2>/dev/null || true)" = "Linux" ] && grep -qi microsoft /proc/version 2>/dev/null; then
    bad "当前 bash 跑在 WSL 里（${bash_bin}），不是 Git Bash"
    fix "Windows 上从 Git Bash 开桌面会话（不要用 WSL，也不要经 ssh 用默认 shell），再跑 just doctor"
  else
    ok "bash：${bash_bin}（$("$bash_bin" -c 'printf "%s" "${BASH_VERSION:-?}"' 2>/dev/null)）"
  fi
fi

# ── 3. 本地提交拦截（复用 tools/hooks/install.sh --check）───────────────
if [ ! -f "${TOP}/tools/hooks/install.sh" ]; then
  bad "找不到 ${TOP}/tools/hooks/install.sh，检查不了本地提交拦截"
  fix "确认在 P-Pass 检出里；旧 worktree 先 git rebase origin/main"
else
  if hook_out="$(cd "$TOP" && bash tools/hooks/install.sh --check 2>&1)"; then
    ok "本地提交拦截：已安装"
  else
    bad "本地提交拦截没装好：范围与核心不会被拦"
    printf '%s\n' "$hook_out" | head -8 | sed -e 's/^/      /'
    fix "在主副本里跑 just setup（只装拦截：bash tools/hooks/install.sh）"
  fi
fi

# ── 4. gh 能读本仓库 issue ──────────────────────────────────────────
REPO="${PPASS_HOOK_REPO:-}"
if [ -z "$REPO" ]; then
  REPO="$(git config --get remote.origin.url 2>/dev/null |
    sed -E -e 's#/+$##' -e 's#\.git$##' -e 's#^.*[:/]([^/:]+/[^/:]+)$#\1#')"
fi
case "$REPO" in
  */*) ;;
  *) REPO="" ;;
esac
if [ -z "$REPO" ]; then
  bad "解析不出 GitHub 仓库（origin URL 不认识）"
  fix "确认 origin 指向 hawkeye-xb/P-Pass；或设 PPASS_HOOK_REPO=<owner>/<repo>"
elif ! command -v gh >/dev/null 2>&1; then
  bad "找不到 gh，读不了本仓库 issue"
  fix "装 GitHub CLI 并登录：gh auth login"
else
  if gh_out="$(gh issue list -R "$REPO" --limit 1 --json number 2>&1)"; then
    ok "gh：能读 ${REPO} 的 issue"
  else
    bad "gh 读不到 ${REPO} 的 issue：$(printf '%s' "$gh_out" | head -1)"
    fix "先 gh auth login（gh auth status 看当前账号）"
  fi
fi

# ── 5. git 提交身份在白名单里（DCO / 身份门禁的同一份白名单）────────────
WL="${MAIN_ROOT}/.github/allowed-identities.txt"
[ -f "$WL" ] || WL="${TOP}/.github/allowed-identities.txt"
name="$(git config --get user.name 2>/dev/null || true)"
email="$(git config --get user.email 2>/dev/null || true)"
if [ -z "$name" ] || [ -z "$email" ]; then
  bad "没有设置 git 提交身份（user.name / user.email）"
  fix "git config user.name \"<白名单里的名字>\"" \
    "git config user.email \"<白名单里的邮箱>\""
elif [ ! -f "$WL" ]; then
  bad "找不到 .github/allowed-identities.txt，判不了提交身份"
  fix "确认在 P-Pass 检出里；旧 worktree 先 git rebase origin/main"
elif grep -Fxq "${name} <${email}>" "$WL"; then
  ok "提交身份：${name} <${email}>（在白名单里）"
else
  bad "提交身份「${name} <${email}>」不在 .github/allowed-identities.txt"
  fix "git config user.name / user.email 改成白名单里的身份（见 ${WL}）" \
    "新增身份要让仓库所有者在白名单里加一行，不要绕过身份门禁"
fi

# ── 6. 磁盘剩余 ≥ 15G ──────────────────────────────────────────────
MIN_GB="${PPASS_DOCTOR_MIN_FREE_GB:-15}"
case "$MIN_GB" in
  '' | *[!0-9]*) MIN_GB=15 ;;
esac
avail_kb="$(df -Pk "$MAIN_ROOT" 2>/dev/null | awk 'NR==2 {print $4}')"
case "$avail_kb" in
  '' | *[!0-9]*) avail_kb="" ;;
esac
if [ -z "$avail_kb" ]; then
  warn "磁盘：读不出 ${MAIN_ROOT} 的剩余空间，跳过（≥15G 是硬要求，自己再确认一次）"
else
  need_kb=$((MIN_GB * 1024 * 1024))
  avail_gb=$((avail_kb / 1024 / 1024))
  # 低于 30G 先提示（#1490）：多个会话并行编译一天就能把共享编译缓存撑到 100G，等跌破下限再清就挡开工了。
  WARN_GB=30
  if [ "$avail_kb" -ge "$need_kb" ]; then
    ok "磁盘：剩余 ${avail_gb}G（要求 ≥ ${MIN_GB}G）"
    if [ "$avail_gb" -lt "$WARN_GB" ]; then
      warn "磁盘：剩余不到 ${WARN_GB}G，先清共享编译缓存：just cleanup-local --cache --apply（要 cargo-sweep：cargo install cargo-sweep --locked）"
    fi
  else
    bad "磁盘：剩余 ${avail_gb}G，低于 ${MIN_GB}G"
    fix "先清共享编译缓存：just cleanup-local --cache --apply（要 cargo-sweep：cargo install cargo-sweep --locked）" \
      "再清本机 worktree 与构建产物：just cleanup-local（默认只预览，--apply 才删）" \
      "有未推送提交或未提交改动的 worktree 先处理，别直接删"
  fi
fi

# ── 6b. 共享编译缓存（#1375；只报不判）────────────────────────────────
CACHE_LIB="$(dirname "$0")/../e3/lib/dev-cache.sh"
if [ -f "$CACHE_LIB" ]; then
  # shellcheck source=../e3/lib/dev-cache.sh
  . "$CACHE_LIB"
  cache_env="$(dev_cache_env_file "$MAIN_ROOT" 2>/dev/null)"
  if [ -n "$cache_env" ] && [ -f "$cache_env" ]; then
    ok "编译缓存：共享（$(dev_cache_value CARGO_TARGET_DIR "$MAIN_ROOT")，配置 ${cache_env}）"
    if [ -n "${CARGO_TARGET_DIR:-}" ] && [ "$CARGO_TARGET_DIR" != "$(dev_cache_value CARGO_TARGET_DIR "$MAIN_ROOT")" ]; then
      warn "编译缓存：当前环境的 CARGO_TARGET_DIR=${CARGO_TARGET_DIR} 与共享配置不同，以环境为准"
    fi
  else
    warn "编译缓存：还没有共享配置，每个卡目录各编一份（just start 会自动建；或跑 tools/e3/dev cache）"
  fi
  old_targets="$(find "$(dirname "$MAIN_ROOT")/$(basename "$MAIN_ROOT")-wt" -mindepth 2 -maxdepth 2 -name target -type d 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${old_targets:-0}" -gt 0 ]; then
    warn "编译缓存：${old_targets} 个卡目录里还留着各自的 target/（共享缓存之前编的）；清理前 lsof +D 核实没人在用"
  fi
fi

# ── 7. 私仓（只报模式，不算失败）─────────────────────────────────────
PRIVATE_DIR="$(dirname "$MAIN_ROOT")/private"
if [ -d "$PRIVATE_DIR" ]; then
  ok "私仓：完整模式（${PRIVATE_DIR}）"
else
  warn "私仓：协作者模式（没有 ${PRIVATE_DIR}）：不写不公开内容；遇到要写私仓的活，just stuck <号> \"需要写私仓，本机是协作者模式\""
fi

# ── 8. 在线设备（只列，不判失败）─────────────────────────────────────
if [ -n "${PPASS_DOCTOR_SKIP_DEVICES:-}" ]; then
  :
elif command -v adb >/dev/null 2>&1 || { command -v xcrun >/dev/null 2>&1 && xcrun --find devicectl >/dev/null 2>&1; }; then
  echo "  ℹ 在线设备（只列，不判失败；接在哪台机器是动态的）："
  if command -v adb >/dev/null 2>&1; then
    printf '      adb:\n'
    adb devices -l 2>&1 | head -12 | sed -e 's/^/        /'
  else
    printf '      adb: 未安装\n'
  fi
  if command -v xcrun >/dev/null 2>&1 && xcrun --find devicectl >/dev/null 2>&1; then
    printf '      devicectl:\n'
    xcrun devicectl list devices 2>&1 | head -12 | sed -e 's/^/        /'
  else
    printf '      devicectl: 未安装\n'
  fi
else
  warn "在线设备：本机没有 adb / devicectl，跳过（只列不判失败）"
fi

# ── 9. 设备归属与闲置模拟器（#1378；只列，不判失败）─────────────────────────
if [ -z "${PPASS_DOCTOR_SKIP_DEVICES:-}" ] && [ -x /usr/bin/lockf ]; then
  echo "  ℹ 设备归属（tools/e3/lock status；有主人的设备别人取不到锁）："
  bash "$(dirname "$0")/../e3/lock" status 2>&1 | sed -e 's/^/      /'
fi
if [ -z "${PPASS_DOCTOR_SKIP_DEVICES:-}" ] && command -v xcrun >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
  idle="$(bash "$(dirname "$0")/../ios/sim.sh" idle 10 2>/dev/null)"
  if [ -n "$idle" ]; then
    warn "模拟器开着没人用（谁开谁关；确认不是你的会话在用再关：xcrun simctl shutdown <UDID>）："
    printf '%s\n' "$idle" | sed -e 's/^/      /'
  fi
fi

echo
if [ "$FAIL" -ne 0 ]; then
  printf '✗ doctor 没通过：%s 项必需条件没满足。修好再开工，别带病继续。\n' "$FAIL"
  exit 1
fi
printf '✅ doctor 通过：可以开工。\n'
