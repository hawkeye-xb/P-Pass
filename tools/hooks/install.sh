#!/usr/bin/env bash
# 安装 / 自检本地提交拦截。`just setup` 调安装，`just hooks-check` 调 --check。
#
#   tools/hooks/install.sh           安装（可重复执行）
#   tools/hooks/install.sh --check   只检查，没装好就非 0 退出
#   tools/hooks/install.sh --release 若 core.hooksPath 是本拦截的，先解开（给 pre-commit 框架安装让路）
#
# 为什么是 core.hooksPath + 公共目录里的转发器，而不是 pre-commit 框架或 hooksPath=tools/hooks：
#   - pre-commit 框架要本机装 Python 包，agent 外壳里常常没有；git 自己的 hook 机制什么都不用装。
#   - core.hooksPath 是全部 worktree 共用的配置。若直接指向相对路径 tools/hooks，还没合入
#     tools/hooks/ 的旧 worktree 会一个 hook 都不跑（连本机原有的身份白名单 hook 也失效）。
#     转发器放在 git 公共目录里，每个 worktree 都找得到；它先跑原有 hook，再跑 HEAD 里的
#     tools/hooks/<名字>，没有就跳过。新开的 worktree 不用再装。
# 转发器只覆盖「我们自己的 hook ∪ 原 hooks 目录里已有的 hook」。之后在 .git/hooks 里新加
# 别的 hook，要重跑一次本脚本才会被转发。

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OWN_HOOKS="pre-commit commit-msg pre-push"

common="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
dest="${common}/ppass-hooks"
current="$(git config --get core.hooksPath || true)"

hook_names() {
  local n
  for n in $OWN_HOOKS; do echo "$n"; done
  if [ -d "${common}/hooks" ]; then
    for n in "${common}/hooks"/*; do
      [ -f "$n" ] && [ -x "$n" ] || continue
      case "$n" in *.sample) continue ;; esac
      basename "$n"
    done
  fi
}

if [ "${1:-}" = "--check" ]; then
  bad=0
  if [ "$current" != "$dest" ]; then
    echo "✗ core.hooksPath 是「${current:-（未设置）}」，应为「${dest}」" >&2
    bad=1
  fi
  for n in $(hook_names | sort -u); do
    if ! cmp -s "${HERE}/dispatch.sh" "${dest}/${n}" || [ ! -x "${dest}/${n}" ]; then
      echo "✗ 转发器「${dest}/${n}」缺失、不可执行或与 tools/hooks/dispatch.sh 不一致" >&2
      bad=1
    fi
  done
  if ! command -v gh >/dev/null 2>&1; then
    echo "⚠ PATH 里没有 gh：卡分支上的提交会一律被拒（batch/* 不受影响）" >&2
  elif ! gh auth status >/dev/null 2>&1; then
    echo "⚠ gh 未登录：卡分支上的提交会一律被拒（batch/* 不受影响）" >&2
  fi
  if [ "$bad" -ne 0 ]; then
    echo "  修复：just setup（或 tools/hooks/install.sh）" >&2
    exit 1
  fi
  echo "ok: 本地提交拦截已安装（core.hooksPath → ${dest}）"
  exit 0
fi

# pre-commit 框架看到 core.hooksPath 就拒绝安装。`just setup` 先 --release 解开、装框架
# （它写进 <公共目录>/hooks/，转发器照样会先跑它），再重新安装本拦截。
if [ "${1:-}" = "--release" ]; then
  [ "$current" = "$dest" ] && git config --unset core.hooksPath
  exit 0
fi

if [ -n "$current" ] && [ "$current" != "$dest" ]; then
  echo "✗ core.hooksPath 已被设成「${current}」，不覆盖。确认无用后 git config --unset core.hooksPath 再重跑" >&2
  exit 1
fi

mkdir -p "$dest"
for n in $(hook_names | sort -u); do
  cp "${HERE}/dispatch.sh" "${dest}/${n}"
  chmod +x "${dest}/${n}"
done
git config core.hooksPath "$dest"
echo "ok: 本地提交拦截已安装（core.hooksPath → ${dest}；转发：$(hook_names | sort -u | tr '\n' ' ')）"
