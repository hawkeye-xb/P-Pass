#!/usr/bin/env bash
# SEC-02 反证：证明 check-commit-identity.sh 在该红的时候真的红。
#
# 门禁只会「不报错」是没有价值的——必须证明去掉故障条件它变红、加回来
# 它复绿。本脚本在临时仓库里造出各种越界身份，逐条断言退出码。
#
# 六个变异：
#   A 白名单身份                     → 必须绿
#   B author 不在白名单               → 必须红
#   C committer 不在白名单（author 合法）→ 必须红
#   D name 对、email 不对             → 必须红（证明 email 真的在管）
#   E email 对、name 不对             → 必须红（证明 name 真的在管）
#   F 白名单文件为空                  → 必须红（空白名单不得等于放行）
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
CHECK="$ROOT/tools/check-commit-identity.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LIST="$TMP/allow.txt"
cat > "$LIST" <<'EOF'
# 测试用白名单
allowed-user <allowed@example.com>
EOF

REPO="$TMP/repo"
mkdir -p "$REPO"
# --template= 用空模板初始化：否则临时仓库会从 init.templateDir 继承本机
# 的 pre-commit 钩子，而那个钩子正是本脚本要造的「越界身份」的克星——
# 夹具提交会被自己人拦下，测试永远跑不起来。
git -C "$REPO" init -q --template=
# 夹具提交一律 --no-verify：它们是测试数据，不该受本机策略影响。
make_commit() { # author_name author_email committer_name committer_email
    GIT_AUTHOR_NAME="$1" GIT_AUTHOR_EMAIL="$2" \
    GIT_COMMITTER_NAME="$3" GIT_COMMITTER_EMAIL="$4" \
        git -C "$REPO" commit -q --no-verify --allow-empty -m "mutation commit"
}

GIT_AUTHOR_NAME="allowed-user" GIT_AUTHOR_EMAIL="allowed@example.com" \
GIT_COMMITTER_NAME="allowed-user" GIT_COMMITTER_EMAIL="allowed@example.com" \
    git -C "$REPO" commit -q --no-verify --allow-empty -m "base"
BASE="$(git -C "$REPO" rev-parse HEAD)"

run_check() {
    ( cd "$REPO" && ALLOWLIST="$LIST" bash "$CHECK" "$BASE..HEAD" >/dev/null 2>&1 )
}

reset_to_base() { git -C "$REPO" reset -q --hard "$BASE"; }

fail=0
assert() { # assert <名称> <期望退出码>
    local name="$1" want="$2" got=0
    run_check || got=$?
    if [ "$got" -eq "$want" ]; then
        echo "  ✅ $name（退出码 $got，符合期望）"
    else
        echo "  ❌ $name：期望退出码 $want，实际 $got" >&2
        fail=1
    fi
}

echo "==> SEC-02 提交身份门禁反证"

reset_to_base
make_commit "allowed-user" "allowed@example.com" "allowed-user" "allowed@example.com"
assert "A 白名单身份必须绿" 0

reset_to_base
make_commit "intruder" "intruder@example.com" "allowed-user" "allowed@example.com"
assert "B author 越界必须红" 1

reset_to_base
make_commit "allowed-user" "allowed@example.com" "intruder" "intruder@example.com"
assert "C committer 越界必须红" 1

reset_to_base
make_commit "allowed-user" "other@example.com" "allowed-user" "other@example.com"
assert "D name 对 email 错必须红" 1

reset_to_base
make_commit "other-name" "allowed@example.com" "other-name" "allowed@example.com"
assert "E email 对 name 错必须红" 1

reset_to_base
make_commit "allowed-user" "allowed@example.com" "allowed-user" "allowed@example.com"
: > "$LIST"
assert "F 空白名单必须红（不得等于放行）" 2

if [ "$fail" -ne 0 ]; then
    echo "✗ 反证未通过：门禁在该红的时候没红" >&2
    exit 1
fi
echo "ok: 六个变异全部符合期望，门禁判据有效"
