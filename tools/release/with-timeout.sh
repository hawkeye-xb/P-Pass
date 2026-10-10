#!/usr/bin/env bash
# #772：给发布链里可能挂住的外部命令加墙钟上限，超时说清是哪一步，可选重试。
#
# 用法：tools/release/with-timeout.sh <步骤名> <秒> <最多尝试次数> -- <命令...>
#   - 命令在上限内结束：原样透传它的退出码（失败不重试——那是真失败，不是挂住）。
#   - 超过上限：先 TERM 再 KILL 命令及其子进程，打印
#     「TIMEOUT: 「<步骤名>」超过 <秒>s 没有返回（第 i/n 次）」；还有次数就重跑，
#     用完以 124 退出（与 coreutils timeout 同一个退出码）。
#   - 命令的 stdin 照常可用（heredoc 喂给 osascript 也行）。
#
# 为什么自己写：macOS runner 没有 `timeout`（coreutils 的 gtimeout 不保证装着），
# 而 v2026.10.3 实发时 `codesign --timestamp` 挂了 14 分钟，job 本身又没有
# timeout-minutes，要等 GitHub 默认的 6 小时才会被杀。
#
# 只用 bash 3.2 有的东西（macOS 自带 bash 就是 3.2）。
set -uo pipefail

if [ "$#" -lt 4 ] || [ "$4" != "--" ]; then
  echo "usage: $0 <step-name> <seconds> <attempts> -- <command...>" >&2
  exit 2
fi
name="$1"; limit="$2"; attempts="$3"; shift 4

# 非交互 shell 里后台命令的 stdin 默认被换成 /dev/null；先把真 stdin 存到 fd 3。
exec 3<&0

kill_tree() {
  local sig="$1" pid="$2"
  pkill "-$sig" -P "$pid" 2>/dev/null
  kill "-$sig" "$pid" 2>/dev/null
}

attempt=1
while :; do
  "$@" <&3 3<&- &
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
  if [ "$timed_out" -eq 1 ]; then
    echo "TIMEOUT: 「$name」超过 ${limit}s 没有返回（第 $attempt/$attempts 次）" >&2
    if [ "$attempt" -lt "$attempts" ]; then
      attempt=$((attempt + 1))
      echo "         重试「$name」" >&2
      continue
    fi
    exit 124
  fi
  wait "$pid"
  rc=$?
  [ "$rc" -eq 0 ] || echo "FAILED: 「$name」退出码 $rc" >&2
  exit "$rc"
done
