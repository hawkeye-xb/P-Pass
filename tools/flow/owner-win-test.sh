#!/usr/bin/env bash
# batch-verify 的 Windows 一步：把当前批次 HEAD 送到 Windows 回归机的专用克隆里，
# 在主人交互会话里（临时计划任务，tools/flow/owner-win-run.ps1）跑 Rust 测试。
#
# 为什么不直接 ssh 跑：OpenSSH 会话的令牌是网络登录，命名管道 DACL 与 ACL 类测试在那里
# 会红或挂死（交互会话下同一份构建全过），结论不可信。
#
# 本机配置 ~/.config/ppass/owner.env（不进 git；PPASS_OWNER_ENV 可改路径）：
#   OWNER_WIN_HOST=<ssh 主机别名>
#   OWNER_WIN_CLONE=<Windows 上 owner 专用的仓库克隆，如 C:\src\P-Pass-owner；不要用别人在用的克隆>
#   OWNER_WIN_WORK=<临时目录，如 C:\pp-owner>
#   OWNER_WIN_TEST_CMD=<可选，默认 cargo nextest run --workspace>
#
# 退出码：0 通过 / 1 测试红 / 3 没配置（算「未覆盖」）/ 4 判定不了（送不过去、任务没跑起来）
# 用法：owner-win-test.sh <日志文件>

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG="${1:?用法：owner-win-test.sh <日志文件>}"
ENV_FILE="${PPASS_OWNER_ENV:-${HOME}/.config/ppass/owner.env}"
: >"$LOG"
note() { printf '%s\n' "$*" | tee -a "$LOG" >&2; }

[ -f "$ENV_FILE" ] || { note "未配置 ${ENV_FILE}：Windows 端未覆盖"; exit 3; }
# shellcheck disable=SC1090
. "$ENV_FILE"
[ -n "${OWNER_WIN_HOST:-}" ] && [ -n "${OWNER_WIN_CLONE:-}" ] && [ -n "${OWNER_WIN_WORK:-}" ] ||
  { note "${ENV_FILE} 缺 OWNER_WIN_HOST / OWNER_WIN_CLONE / OWNER_WIN_WORK：Windows 端未覆盖"; exit 3; }
CMD="${OWNER_WIN_TEST_CMD:-cargo nextest run --workspace}"

# 有 ppf-decoder 这个 bin 就先构建它：daemon 的测试要拉起它，裸 cargo test 不会顺带构建。
pkg="$(cargo metadata --no-deps --format-version 1 2>/dev/null | python3 -c '
import json, sys
for p in json.load(sys.stdin)["packages"]:
    for t in p["targets"]:
        if t["name"] == "ppf-decoder" and "bin" in t["kind"]:
            print(p["name"]); sys.exit()
' 2>/dev/null)"
[ -z "$pkg" ] || CMD="cargo build -p ${pkg} --bin ppf-decoder && ${CMD}"

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
scp -q -o BatchMode=yes "${tmp}/batch.bundle" "${HERE}/owner-win-run.ps1" "${OWNER_WIN_HOST}:${work_fwd}/" >>"$LOG" 2>&1 ||
  { note "scp 到 ${OWNER_WIN_HOST} 失败"; exit 4; }

got="$(ssh_ps "Set-Location '${OWNER_WIN_CLONE}'; git fetch -q origin main; git fetch -q '${OWNER_WIN_WORK}\\batch.bundle' '+${ref}:${ref}'; git checkout -q --detach '${ref}'; git rev-parse HEAD" 2>>"$LOG" | tr -d '\r' | tail -1)"
[ "$got" = "$head_sha" ] || { note "Windows 克隆检出的是「${got}」，不是批次 HEAD ${head_sha}"; exit 4; }
note "Windows 克隆已检出 ${head_sha}，在交互会话里跑：${CMD}"

ssh -o BatchMode=yes "$OWNER_WIN_HOST" \
  "powershell -NoProfile -ExecutionPolicy Bypass -File \"${OWNER_WIN_WORK}\\owner-win-run.ps1\" -Workdir \"${OWNER_WIN_WORK}\" -Command \"cd /d ${OWNER_WIN_CLONE} && set CARGO_INCREMENTAL=0&& set CARGO_BUILD_JOBS=4&& ${CMD}\"" \
  2>&1 | tr -d '\r' >>"$LOG"
rc="$(sed -n 's/^PPASS_EXIT=//p' "$LOG" | tail -1)"
case "$rc" in
  0) note "Windows 测试通过"; exit 0 ;;
  '' | none) note "Windows 计划任务没跑完或没跑起来（主人没登录桌面？超时？），判定不了"; exit 4 ;;
  *) note "Windows 测试红（退出码 ${rc}）"; exit 1 ;;
esac
