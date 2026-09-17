#!/usr/bin/env bash
# SEC-02: 提交身份白名单门禁。
#
# 只有 .github/allowed-identities.txt 里列出的 `Name <email>` 能提交；
# author 与 committer 两个位置都查，name 和 email 都必须逐字符匹配。
#
# 为什么是白名单不是黑名单：黑名单必须把「禁止什么」写进仓库，那串字符
# 本身就成了提交内容——为了防泄漏反而泄漏。白名单只描述允许谁。
#
# 为什么必须在 CI 上（而不是只靠本地 hook）：本地 hook 只能约束装了它的
# 机器。真实发生过的一次越界就来自另一台没装 hook 的机器，本机配置再对
# 也拦不到。服务端门禁是唯一覆盖所有机器的位置。
#
# 用法：
#   tools/check-commit-identity.sh                 # 默认查 origin/main..HEAD
#   tools/check-commit-identity.sh <range>         # 查指定区间
#   ALLOWLIST=path tools/check-commit-identity.sh  # 换白名单文件（测试用）
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
ALLOWLIST="${ALLOWLIST:-$ROOT/.github/allowed-identities.txt}"

if [ ! -f "$ALLOWLIST" ]; then
    echo "✗ 白名单文件不存在: $ALLOWLIST" >&2
    exit 2
fi

# 决定要检查的区间
if [ $# -ge 1 ] && [ -n "$1" ]; then
    RANGE="$1"
elif [ -n "${GITHUB_BASE_REF:-}" ]; then
    # PR：查这个 PR 自己引入的提交
    RANGE="origin/${GITHUB_BASE_REF}..HEAD"
elif [ -n "${IDENTITY_RANGE:-}" ]; then
    RANGE="$IDENTITY_RANGE"
else
    RANGE="origin/main..HEAD"
fi

# 读白名单（去掉注释与空行，去掉行尾空白）
# 不用 mapfile：macOS 自带 bash 是 3.2，没有这个内建；CI 的 bash 5 有，
# 用了就会变成「本地红 CI 绿」的隐身分歧。
ALLOWED=()
while IFS= read -r _line; do
    [ -n "$_line" ] && ALLOWED+=("$_line")
done < <(sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' "$ALLOWLIST")

if [ "${#ALLOWED[@]}" -eq 0 ]; then
    echo "✗ 白名单为空，拒绝放行（空白名单等于门禁失效）" >&2
    exit 2
fi

is_allowed() {
    local ident="$1" a
    for a in "${ALLOWED[@]}"; do
        [ "$ident" = "$a" ] && return 0
    done
    return 1
}

if ! REVS="$(git rev-list "$RANGE" 2>/dev/null)"; then
    echo "✗ 无法解析区间: $RANGE" >&2
    exit 2
fi

if [ -z "$REVS" ]; then
    echo "ok: 区间 $RANGE 内没有提交，无需检查"
    exit 0
fi

n=0
bad=0
while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    n=$((n + 1))
    author="$(git log -1 --format='%an <%ae>' "$sha")"
    committer="$(git log -1 --format='%cn <%ce>' "$sha")"
    for role_ident in "author|$author" "committer|$committer"; do
        role="${role_ident%%|*}"
        ident="${role_ident#*|}"
        if ! is_allowed "$ident"; then
            bad=$((bad + 1))
            echo "✗ ${sha:0:8} 的 $role 不在白名单内：$ident" >&2
            echo "    $(git log -1 --format='%s' "$sha" | cut -c1-70)" >&2
        fi
    done
done <<< "$REVS"

if [ "$bad" -ne 0 ]; then
    cat >&2 <<'MSG'

──────────────────────────────────────────────────────────────
提交被拒：上面列出的身份不在白名单内。

如果这是你自己配置错了（最常见）：
    git config user.name  "<白名单里的 name>"
    git config user.email "<白名单里的 email>"
    git commit --amend --reset-author     # 只改最后一条
  已经推上去的多条，用 git rebase 或 git filter-repo 统一改写后强推。

如果这是一个应当被允许的新身份：
    请在本仓开一个 issue 说明用途，由仓库所有者 @hawkeye-xb 决定是否
    加进 .github/allowed-identities.txt。不要自己顺手加行——白名单变更
    应当是一次独立的、可被审阅的改动。

当前白名单见 .github/allowed-identities.txt
──────────────────────────────────────────────────────────────
MSG
    exit 1
fi

echo "ok: $RANGE 内 $n 个提交的 author/committer 全部在白名单内"
