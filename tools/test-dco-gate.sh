#!/usr/bin/env bash
# #1134 反证：证明 check-dco.sh 在该红的时候真的红。
#
# 在临时仓库里造出各种签名情形，逐条断言退出码：
#   A 签名与 author 一致                    → 必须绿
#   B 没有签名                              → 必须红
#   C 签名的 email 与 author 不同            → 必须红（证明 email 真的在管）
#   D 签名的 name 与 author 不同             → 必须红（证明 name 真的在管）
#   E 签名只在正文中间、不在末尾 trailer 段   → 必须红
#   F email 只差大小写                      → 必须绿（与 DCO App 一致）
#   G 机器人 author（[bot] 结尾）未签名       → 必须绿
#   H 两个提交、其中一个未签名               → 必须红（证明逐个提交都查）
#   I 未签名的 merge 提交 + 已签名的普通提交   → 必须绿（merge 不查）
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
CHECK="$ROOT/tools/check-dco.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

REPO="$TMP/repo"
mkdir -p "$REPO"
# 空模板 + --no-verify：夹具提交是测试数据，不该受本机钩子影响
#（理由同 test-commit-identity-gate.sh）。
git -C "$REPO" init -q --template= -b main

AN="Dev User"
AE="dev@example.com"
commit_as() { # commit_as <author name> <author email> <message>
    GIT_AUTHOR_NAME="$1" GIT_AUTHOR_EMAIL="$2" \
    GIT_COMMITTER_NAME="$1" GIT_COMMITTER_EMAIL="$2" \
        git -C "$REPO" commit -q --no-verify --allow-empty -m "$3"
}

commit_as "$AN" "$AE" "base"
BASE="$(git -C "$REPO" rev-parse HEAD)"

reset_to_base() { git -C "$REPO" checkout -q main; git -C "$REPO" reset -q --hard "$BASE"; }

fail=0
assert() { # assert <名称> <期望退出码>
    local name="$1" want="$2" got=0
    ( cd "$REPO" && bash "$CHECK" "$BASE..HEAD" >/dev/null 2>&1 ) || got=$?
    if [ "$got" -eq "$want" ]; then
        echo "  ✅ ${name}（退出码 ${got}，符合期望）"
    else
        echo "  ❌ ${name}：期望退出码 ${want}，实际 ${got}" >&2
        fail=1
    fi
}

echo "==> #1134 DCO 门禁反证"

reset_to_base
commit_as "$AN" "$AE" "$(printf 'feat: x\n\nSigned-off-by: %s <%s>' "$AN" "$AE")"
assert "A 签名一致必须绿" 0

reset_to_base
commit_as "$AN" "$AE" "feat: x"
assert "B 无签名必须红" 1

reset_to_base
commit_as "$AN" "$AE" "$(printf 'feat: x\n\nSigned-off-by: %s <other@example.com>' "$AN")"
assert "C 签名 email 不同必须红" 1

reset_to_base
commit_as "$AN" "$AE" "$(printf 'feat: x\n\nSigned-off-by: Someone Else <%s>' "$AE")"
assert "D 签名 name 不同必须红" 1

reset_to_base
commit_as "$AN" "$AE" "$(printf 'feat: x\n\nSigned-off-by: %s <%s>\n\nmore body text after it' "$AN" "$AE")"
assert "E 签名不在末尾 trailer 段必须红" 1

reset_to_base
commit_as "$AN" "$AE" "$(printf 'feat: x\n\nSigned-off-by: %s <DEV@Example.com>' "$AN")"
assert "F email 只差大小写必须绿" 0

reset_to_base
commit_as "dependabot[bot]" "49699333+dependabot[bot]@users.noreply.github.com" "chore(ci): bump"
assert "G 机器人提交未签名必须绿" 0

reset_to_base
commit_as "$AN" "$AE" "$(printf 'feat: x\n\nSigned-off-by: %s <%s>' "$AN" "$AE")"
commit_as "$AN" "$AE" "feat: y"
assert "H 两个提交其一未签名必须红" 1

reset_to_base
git -C "$REPO" checkout -q -b side
commit_as "$AN" "$AE" "$(printf 'feat: side\n\nSigned-off-by: %s <%s>' "$AN" "$AE")"
git -C "$REPO" checkout -q main
commit_as "$AN" "$AE" "$(printf 'feat: main\n\nSigned-off-by: %s <%s>' "$AN" "$AE")"
GIT_AUTHOR_NAME="$AN" GIT_AUTHOR_EMAIL="$AE" GIT_COMMITTER_NAME="$AN" GIT_COMMITTER_EMAIL="$AE" \
    git -C "$REPO" merge -q --no-ff --no-verify --no-edit -m "Merge side" side
assert "I 未签名的 merge 提交不查必须绿" 0
git -C "$REPO" branch -q -D side

if [ "$fail" -ne 0 ]; then
    echo "✗ 反证未通过：门禁在该红的时候没红" >&2
    exit 1
fi
echo "ok: 九个变异全部符合期望，门禁判据有效"
