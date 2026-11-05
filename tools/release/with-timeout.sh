#!/usr/bin/env bash
# #772：给发布链里可能挂住的外部命令加墙钟上限，超时说清是哪一步，可选重试。
#
# 用法：tools/release/with-timeout.sh [--retry-on <ERE>] <步骤名> <秒> <最多尝试次数> -- <命令...>
#   - 命令在上限内结束：原样透传它的退出码（失败不重试——那是真失败，不是挂住）。
#   - 超过上限：先 TERM 再 KILL 命令及其子进程，打印
#     「TIMEOUT: 「<步骤名>」超过 <秒>s 没有返回（第 i/n 次）」；还有次数就重跑，
#     用完以 124 退出（与 coreutils timeout 同一个退出码）。
#   - 命令的 stdin 照常可用（heredoc 喂给 osascript 也行）。
#   - #1438 --retry-on <ERE>（可选）：命令在上限内结束、退出码非 0、且本次 stderr 匹配 <ERE>，
#     才按 PPF_RETRY_DELAYS（默认「5 10 20」秒，个数 = 最多重试次数）退避重试；用完仍命中就透传
#     命令自己的退出码。其它失败照旧立即透传。busy 重试与超时重试分开计数。
#     带它时 stderr 先截到临时文件，命令结束后原样回放（只回放，不改内容）。
#     方案：docs/decisions/2026-11-05-release-hdiutil-busy-retry.md
#
# 为什么自己写：macOS runner 没有 `timeout`（coreutils 的 gtimeout 不保证装着），
# 而 v2026.10.3 实发时 `codesign --timestamp` 挂了 14 分钟，job 本身又没有
# timeout-minutes，要等 GitHub 默认的 6 小时才会被杀。
#
# 只用 bash 3.2 有的东西（macOS 自带 bash 就是 3.2）。
set -uo pipefail

retry_on=""
if [ "${1:-}" = "--retry-on" ]; then
  [ -n "${2:-}" ] || { echo "usage: $0 [--retry-on <ERE>] <step-name> <seconds> <attempts> -- <command...>" >&2; exit 2; }
  retry_on="$2"; shift 2
fi
if [ "$#" -lt 4 ] || [ "$4" != "--" ]; then
  echo "usage: $0 [--retry-on <ERE>] <step-name> <seconds> <attempts> -- <command...>" >&2
  exit 2
fi
name="$1"; limit="$2"; attempts="$3"; shift 4

retry_delays="${PPF_RETRY_DELAYS-5 10 20}"
# shellcheck disable=SC2206  # 有意按空格拆
delays=($retry_delays)
max_retries=${#delays[@]}
retries=0
errf=""
if [ -n "$retry_on" ]; then
  errf="$(mktemp "${TMPDIR:-/tmp}/with-timeout-err.XXXXXX")" || exit 1
  trap 'rm -f "$errf"' EXIT
fi

# 非交互 shell 里后台命令的 stdin 默认被换成 /dev/null；先把真 stdin 存到 fd 3。
exec 3<&0

kill_tree() {
  local sig="$1" pid="$2"
  pkill "-$sig" -P "$pid" 2>/dev/null
  kill "-$sig" "$pid" 2>/dev/null
}

attempt=1
while :; do
  if [ -n "$errf" ]; then
    : > "$errf"
    "$@" <&3 3<&- 2>"$errf" &
  else
    "$@" <&3 3<&- &
  fi
  pid=$!
  waited=0
  timed_out=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$limit" ]; then
      timed_out=1
      kill_tree TERM "$pid"
      sleep 2
      kill_tree KILL "$pid"
      wait "$pid" 2>/dev/null
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  [ -z "$errf" ] || cat "$errf" >&2
  if [ "$timed_out" -eq 1 ]; then
    echo "TIMEOUT: 「${name}」超过 ${limit}s 没有返回（第 $attempt/$attempts 次）" >&2
    if [ "$attempt" -lt "$attempts" ]; then
      attempt=$((attempt + 1))
      echo "         重试「${name}」" >&2
      continue
    fi
    exit 124
  fi
  wait "$pid"
  rc=$?
  if [ "$rc" -ne 0 ] && [ -n "$retry_on" ] && grep -qE -- "$retry_on" "$errf"; then
    if [ "$retries" -lt "$max_retries" ]; then
      delay="${delays[$retries]}"
      retries=$((retries + 1))
      echo "RETRY: 「${name}」退出码 $rc，stderr 命中「${retry_on}」（第 $retries/$max_retries 次重试），${delay}s 后重试" >&2
      sleep "$delay"
      continue
    fi
    echo "FAILED: 「${name}」退出码 $rc，stderr 命中「${retry_on}」，已重试 $max_retries 次仍失败" >&2
    exit "$rc"
  fi
  [ "$rc" -eq 0 ] || echo "FAILED: 「${name}」退出码 $rc" >&2
  exit "$rc"
done
