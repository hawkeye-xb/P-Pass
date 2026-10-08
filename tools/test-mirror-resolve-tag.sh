#!/usr/bin/env bash
# UPD-18（#706）：tools/mirror-resolve-tag.sh 的判定测试。
#
# 用 stub gh 喂 release 列表，三种触发事件 × {test tag, stable tag} ×
# {test 发在 stable 之前 / 之后} 全跑一遍。核心断言只有一句话：
# **test tag 永远不许走到「镜像」那一支**——走到了，R2 上 stable 的下载包和
# 更新清单就会被 test 覆盖。
#
# 反证：`tools/test-mirror-resolve-tag.sh <另一份判定脚本>` 拿任意实现来跑
# （例如 #706 之前内嵌在 YAML 里的那段），test 用例必须红。
#
# 用法: tools/test-mirror-resolve-tag.sh [被测脚本]
# 退出码: 0 全过 / 1 有失败

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${1:-$HERE/mirror-resolve-tag.sh}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

# ── stub gh：只实现判定脚本用到的两条子命令，数据取自 $STUB_RELEASES ──
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
q=""; args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [ "${args[$i]}" = "-q" ] && q="${args[$((i + 1))]}"
done
case "$1 $2" in
  "release view")
    tag="$3"
    jq -e --arg t "$tag" 'any(.[]; .tagName == $t)' "$STUB_RELEASES" >/dev/null || {
      echo "release not found" >&2; exit 1; }
    jq -r --arg t "$tag" ".[] | select(.tagName == \$t) | $q" "$STUB_RELEASES"
    ;;
  "release list")
    jq -r "[.[] | select(.isDraft | not)] | $q" "$STUB_RELEASES"
    ;;
  *) echo "stub gh: unsupported $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$TMP/bin/gh"

# release 列表夹具
cat > "$TMP/test-after.json" <<'EOF'
[{"tagName":"v2026.10.2","publishedAt":"2026-10-05T13:13:57Z","isDraft":false},
 {"tagName":"v0.9.3-test.1","publishedAt":"2026-10-08T01:00:00Z","isDraft":false},
 {"tagName":"test-channel","publishedAt":"2026-10-08T01:00:05Z","isDraft":false}]
EOF
cat > "$TMP/test-before.json" <<'EOF'
[{"tagName":"v0.9.3-test.1","publishedAt":"2026-10-04T01:00:00Z","isDraft":false},
 {"tagName":"v2026.10.2","publishedAt":"2026-10-05T13:13:57Z","isDraft":false}]
EOF
cat > "$TMP/stable-older.json" <<'EOF'
[{"tagName":"v2026.10.1","publishedAt":"2026-10-05T01:20:10Z","isDraft":false},
 {"tagName":"v2026.10.2","publishedAt":"2026-10-05T13:13:57Z","isDraft":false},
 {"tagName":"v2026.10.3","publishedAt":"2026-10-09T00:00:00Z","isDraft":true}]
EOF

# 跑一次判定，回显「mirror:<tag>」或「skip」
decide() { # fixture event tag
  local out="$TMP/out"
  : > "$out"
  local in_tag="" rel_tag="" run_ref=""
  case "$2" in
    workflow_dispatch) in_tag="$3" ;;
    release) rel_tag="$3" ;;
    workflow_run) run_ref="$3" ;;
  esac
  PATH="$TMP/bin:$PATH" STUB_RELEASES="$TMP/$1" GITHUB_OUTPUT="$out" GITHUB_REPOSITORY=hawkeye-xb/P-Pass \
    EVENT="$2" INPUT_TAG="$in_tag" RELEASE_TAG="$rel_tag" RUN_REF="$run_ref" \
    bash "$SUT" >/dev/null 2>&1 || { echo "error"; return; }
  if grep -q '^skip=true$' "$out"; then echo skip
  else echo "mirror:$(sed -n 's/^tag=//p' "$out")"; fi
}

expect() { # want fixture event tag label
  local got
  got="$(decide "$2" "$3" "$4")"
  if [ "$got" = "$1" ]; then
    printf '  ✅ %-62s → %s\n' "$5" "$got"; PASS=$((PASS + 1))
  else
    printf '  ❌ %-62s → 期望 %s，实得 %s\n' "$5" "$1" "$got"; FAIL=$((FAIL + 1))
  fi
}

echo "==> 1. test tag 一律不镜像（核心红线）"
for ev in workflow_run release workflow_dispatch; do
  expect skip test-after.json  "$ev" v0.9.3-test.1 "test tag 发在 stable 之后 · $ev"
  expect skip test-before.json "$ev" v0.9.3-test.1 "test tag 发在 stable 之前 · $ev"
done

echo "==> 2. stable 判「最新」时不被 test tag 挤掉"
expect mirror:v2026.10.2 test-after.json  workflow_run v2026.10.2 "test 之后重跑 stable · workflow_run"
expect mirror:v2026.10.2 test-after.json  release      v2026.10.2 "test 之后重跑 stable · release"
expect mirror:v2026.10.2 test-before.json workflow_run v2026.10.2 "test 在前、stable 最新 · workflow_run"

echo "==> 3. 原有语义不变"
expect skip              stable-older.json workflow_run v2026.10.1 "旧 stable 不覆盖新 stable"
expect mirror:v2026.10.1 stable-older.json workflow_dispatch v2026.10.1 "dispatch 可手动补镜像旧 stable"
expect skip              stable-older.json release v2026.10.3 "draft 跳过"
expect skip              stable-older.json workflow_run v2026.10.9 "release 还没建 ⇒ 跳过"
expect skip              stable-older.json workflow_run main "非 v* ref 跳过"

echo
echo "通过 $PASS / 失败 $FAIL"
[ "$FAIL" -eq 0 ]
