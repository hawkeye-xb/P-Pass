#!/usr/bin/env bash
# 本地提交拦截的转发器（模板）。tools/hooks/install.sh 把它按 hook 名复制进
# <git 公共目录>/ppass-hooks/，再把 core.hooksPath 指过去。说明见 docs/runbook/local-hooks.md。
#
# 每次触发做两件事，任一失败即拒绝：
#   1. 先跑 <git 公共目录>/hooks/<名字>（设了 core.hooksPath 后 git 不再看那里，
#      本机原有的身份白名单、pre-push 等私有 hook 靠这里接着生效）。
#   2. 再跑**当前 HEAD 里**的 tools/hooks/<名字>（连同它用到的 tools/ci-paths.sh 与
#      .github/core-paths.txt 一起从 HEAD 取）。不读工作区：在工作区里改掉规则或 hook
#      本身再提交，用的仍是改之前那份；而改这些文件本身就是核心改动，会被拦下。
#      HEAD 里没有这个 hook（还没合入 tools/hooks/ 的旧分支）时只做第 1 步。

set -uo pipefail

name="$(basename "$0")"
common="$(git rev-parse --git-common-dir 2>/dev/null)" || {
  echo "✗ P-Pass hook：找不到 git 目录" >&2
  exit 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 从 stdin 读参数的 hook：先存下来，原有 hook 和我们的各喂一份（否则原有 hook 读完就没了）。
# 其它 hook 的 stdin 可能是终端，不能 cat。
case "$name" in
  pre-push | post-rewrite | reference-transaction) cat >"${tmp}/stdin" ;;
  *) : >"${tmp}/stdin" ;;
esac

legacy="${common}/hooks/${name}"
if [ -x "$legacy" ]; then
  "$legacy" "$@" <"${tmp}/stdin" || exit $?
fi

git cat-file -e "HEAD:tools/hooks/${name}" 2>/dev/null || exit 0

mkdir "${tmp}/root"
if ! git archive HEAD tools/hooks tools/ci-paths.sh .github/core-paths.txt | tar -x -C "${tmp}/root"; then
  echo "✗ P-Pass hook：从 HEAD 取 hook 与核心规则失败，按拒绝处理" >&2
  exit 1
fi
PPASS_HOOK_ROOT="${tmp}/root" bash "${tmp}/root/tools/hooks/${name}" "$@" <"${tmp}/stdin"
