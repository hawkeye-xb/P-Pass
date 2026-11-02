#!/usr/bin/env bash
# batch-verify 的 Windows 一步：把当前批次 HEAD 送到 Windows 回归机的专用克隆里，
# 在主人交互会话里（临时计划任务，tools/flow/owner-win-run.ps1）跑对照表
# （tools/flow/ci-local-map.tsv）里 where=win 且 gate 判定要跑的全部步骤。
#
# 为什么不直接 ssh 跑：OpenSSH 会话的令牌是网络登录，命名管道 DACL 与 ACL 类测试在那里
# 会红或挂死（交互会话下同一份构建全过），结论不可信。
#
# 本机配置 ~/.config/ppass/owner.env（不进 git；PPASS_OWNER_ENV 可改路径）：
#   OWNER_WIN_HOST=<ssh 主机别名>
#   OWNER_WIN_CLONE=<Windows 上 owner 专用的仓库克隆，如 C:\src\P-Pass-owner；不要用别人在用的克隆>
#   OWNER_WIN_WORK=<临时目录，如 C:\pp-owner>
#
# 编译限 CARGO_BUILD_JOBS=4、CARGO_INCREMENTAL=0；PATH 最前加 rust-toolchain.toml 锁定版本的工具链 bin。
# 日志里每步前有 PPASS_STEP=<步骤>，红了有 PPASS_FAILED_STEP=<步骤>。
#
# 退出码：0 通过 / 1 测试红 / 3 没配置（算「未覆盖」）/ 4 判定不了（送不过去、任务没跑起来）
#         / 5 对照表判定没有要在 Windows 跑的步骤
# 用法：owner-win-test.sh <日志文件> [--base <ref>]

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="${1:?用法：owner-win-test.sh <日志文件>}"
ENV_FILE="${PPASS_OWNER_ENV:-${HOME}/.config/ppass/owner.env}"
: >"$LOG"
note() { printf '%s\n' "$*" | tee -a "$LOG" >&2; }

BASE=""
[ "${2:-}" = "--base" ] && BASE="${3:-}"

# 步骤取自对照表，gate 与 CI 同一口径；@PPF_DECODER@ 已替换成 ppf-decoder 的构建（daemon 测试要它）。
plan="$(python3 "${HERE}/ci-local-map.py" plan --map "${PPASS_CI_LOCAL_MAP:-${HERE}/ci-local-map.tsv}" \
  --where win ${BASE:+--base "$BASE"} 2>>"$LOG")" || { note "对照表取 Windows 步骤失败"; exit 4; }
toolchain="$(sed -n 's/^channel *= *"\(.*\)"/\1/p' rust-toolchain.toml 2>/dev/null | head -1)"
script_cmd() { # 生成 cmd 脚本：每步一个新的 cmd /c，cd 不串到下一步；红了立刻停
  printf '@echo off\r\n'
  printf 'set CARGO_INCREMENTAL=0\r\nset CARGO_BUILD_JOBS=4\r\n'
  [ -z "$toolchain" ] || printf 'set PATH=%%USERPROFILE%%\\.rustup\\toolchains\\%s-x86_64-pc-windows-msvc\\bin;%%PATH%%\r\n' "$toolchain"
  printf '%s\n' "$plan" | while IFS=$'\t' read -r kind name cmd; do
    [ "$kind" = RUN ] || continue
    printf 'cd /d %s\r\necho PPASS_STEP=%s\r\ncmd /c "%s"\r\n' "$OWNER_WIN_CLONE" "$name" "$cmd"
    printf 'if errorlevel 1 (echo PPASS_FAILED_STEP=%s& exit /b 1)\r\n' "$name"
  done
  printf 'exit /b 0\r\n'
}
if ! printf '%s\n' "$plan" | grep -q '^RUN'; then
  note "对照表判定这次没有要在 Windows 跑的步骤"
  printf '%s\n' "$plan" | grep '^SKIP' >>"$LOG"
  exit 5
fi

[ -f "$ENV_FILE" ] || { note "未配置 ${ENV_FILE}：Windows 端未覆盖"; exit 3; }
# shellcheck disable=SC1090
. "$ENV_FILE"
[ -n "${OWNER_WIN_HOST:-}" ] && [ -n "${OWNER_WIN_CLONE:-}" ] && [ -n "${OWNER_WIN_WORK:-}" ] ||
  { note "${ENV_FILE} 缺 OWNER_WIN_HOST / OWNER_WIN_CLONE / OWNER_WIN_WORK：Windows 端未覆盖"; exit 3; }

head_sha="$(git rev-parse HEAD)"
ref="refs/ppass-owner/verify"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
git update-ref "$ref" HEAD
if ! git bundle create "${tmp}/batch.bundle" "$ref" ^origin/main >>"$LOG" 2>&1; then
  git update-ref -d "$ref"
  note "打包批次提交失败"
  exit 4
fi
git update-ref -d "$ref"

ssh_ps() { ssh -o BatchMode=yes -o ConnectTimeout=15 "$OWNER_WIN_HOST" "powershell -NoProfile -ExecutionPolicy Bypass -Command \"$1\""; }
ssh_ps "New-Item -ItemType Directory -Force '${OWNER_WIN_WORK}' | Out-Null" >>"$LOG" 2>&1 ||
  { note "ssh ${OWNER_WIN_HOST} 不通"; exit 4; }
work_fwd="$(printf '%s' "$OWNER_WIN_WORK" | tr '\\' '/')"
script_cmd >"${tmp}/owner-steps.cmd"
scp -q -o BatchMode=yes "${tmp}/batch.bundle" "${tmp}/owner-steps.cmd" "${HERE}/owner-win-run.ps1" "${OWNER_WIN_HOST}:${work_fwd}/" >>"$LOG" 2>&1 ||
  { note "scp 到 ${OWNER_WIN_HOST} 失败"; exit 4; }

got="$(ssh_ps "Set-Location '${OWNER_WIN_CLONE}'; git fetch -q origin main; git fetch -q '${OWNER_WIN_WORK}\\batch.bundle' '+${ref}:${ref}'; git checkout -q --detach '${ref}'; git rev-parse HEAD" 2>>"$LOG" | tr -d '\r' | tail -1)"
[ "$got" = "$head_sha" ] || { note "Windows 克隆检出的是「${got}」，不是批次 HEAD ${head_sha}"; exit 4; }
note "Windows 克隆已检出 ${head_sha}，在交互会话里跑：$(printf '%s\n' "$plan" | awk -F'\t' '$1=="RUN"{printf "%s ", $2}')"

ssh -o BatchMode=yes "$OWNER_WIN_HOST" \
  "powershell -NoProfile -ExecutionPolicy Bypass -File \"${OWNER_WIN_WORK}\\owner-win-run.ps1\" -Workdir \"${OWNER_WIN_WORK}\" -ScriptFile \"${OWNER_WIN_WORK}\\owner-steps.cmd\"" \
  2>&1 | tr -d '\r' >>"$LOG"
rc="$(sed -n 's/^PPASS_EXIT=//p' "$LOG" | tail -1)"
case "$rc" in
  0) note "Windows 测试通过"; exit 0 ;;
  '' | none) note "Windows 计划任务没跑完或没跑起来（主人没登录桌面？超时？），判定不了"; exit 4 ;;
  *) note "Windows 测试红（退出码 ${rc}，步骤 $(sed -n 's/^PPASS_FAILED_STEP=//p' "$LOG" | tail -1)）"; exit 1 ;;
esac
