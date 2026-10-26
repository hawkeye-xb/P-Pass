#!/usr/bin/env bash
# #1134: DCO（Developer Certificate of Origin）门禁。
#
# 每个提交都必须带一行与 author 一致的签名：
#     Signed-off-by: <author name> <author email>
# 用 `git commit -s` 自动生成。规则与 DCO GitHub App 的默认判定一致：
# name 逐字符匹配，email 不区分大小写；merge 提交不查；author 以 `[bot]`
# 结尾的机器人提交不查（如 dependabot，它们不是在声明原创性）。
#
# 为什么用仓库内脚本而不是装 DCO GitHub App：与 SEC-02 身份门禁同一套
# 写法（脚本 + 反证 + 必过 lane），判据在仓库里可审阅、可本地复现，也不
# 需要给第三方 App 授权。
#
# 用法：
#   tools/check-dco.sh                 # 默认查 origin/main..HEAD
#   tools/check-dco.sh <range>         # 查指定区间
set -euo pipefail

if [ $# -ge 1 ] && [ -n "$1" ]; then
    RANGE="$1"
elif [ -n "${GITHUB_BASE_REF:-}" ]; then
    RANGE="origin/${GITHUB_BASE_REF}..HEAD"
else
    RANGE="origin/main..HEAD"
fi

if ! REVS="$(git rev-list --no-merges "$RANGE" 2>/dev/null)"; then
    echo "✗ 无法解析区间: $RANGE" >&2
    exit 2
fi

if [ -z "$REVS" ]; then
    echo "ok: 区间 $RANGE 内没有需要检查的提交"
    exit 0
fi

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

n=0
skipped=0
bad=0
while IFS= read -r sha; do
    [ -z "$sha" ] && continue
    name="$(git log -1 --format='%an' "$sha")"
    email="$(git log -1 --format='%ae' "$sha")"
    case "$name" in
        *'[bot]')
            skipped=$((skipped + 1))
            continue
            ;;
    esac
    n=$((n + 1))
    ok=0
    # 只认消息末尾 trailer 段里的签名，正文中间随手写的一行不算。
    while IFS= read -r value; do
        case "$value" in
            *' <'*'>') ;;
            *) continue ;;
        esac
        sname="${value% <*}"
        semail="${value##* <}"
        semail="${semail%>}"
        if [ "$sname" = "$name" ] && [ "$(lower "$semail")" = "$(lower "$email")" ]; then
            ok=1
            break
        fi
    done < <(git log -1 --format='%(trailers:key=Signed-off-by,valueonly)' "$sha")
    if [ "$ok" -ne 1 ]; then
        bad=$((bad + 1))
        echo "✗ ${sha:0:8} 缺少与 author 一致的签名：期望 Signed-off-by: $name <$email>" >&2
        echo "    $(git log -1 --format='%s' "$sha" | cut -c1-70)" >&2
    fi
done <<< "$REVS"

if [ "$bad" -ne 0 ]; then
    cat >&2 <<'MSG'

──────────────────────────────────────────────────────────────
DCO check failed: the commits above are not signed off.
DCO 检查未通过：上面的提交缺少 Signed-off-by。

Sign off with `git commit -s`. To fix existing commits on your branch:
用 `git commit -s` 签名。补签分支上已有的提交：
    git rebase --signoff origin/main
    git push --force-with-lease

See CONTRIBUTING.md / 详见 CONTRIBUTING.zh.md
──────────────────────────────────────────────────────────────
MSG
    exit 1
fi

echo "ok: $RANGE 内 $n 个提交均已签名（跳过机器人提交 $skipped 个）"
