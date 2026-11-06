#!/usr/bin/env bash
# tools/flow/gate-status.sh（just gate-status）的判据测试。
#
# 假 gh：workflow 列表、开放卡、分支保护都从 $FAKE 目录读；每种情形配一条只去掉触发条件的反证。
# 关联卡只认标题——第 6 条专门盯这个：标题里提到了「workflow」的卡不算某扇具体门的账。
# 用法: tools/test-gate-status.sh    退出码: 0 全过 / 1 有失败

set -uo pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { printf '  ✅ %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  ❌ %s\n' "$1"; FAIL=$((FAIL + 1)); }

mkdir -p "${TMP}/bin" "${TMP}/fake"
cat >"${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *actions/workflows*) cat "${FAKE}/workflows.txt"; exit 0 ;;
  *branches/main/protection*)
    if [ -f "${FAKE}/protection_fail" ]; then printf 'gh: Not Found (HTTP 404)\n' >&2; exit 1; fi
    cat "${FAKE}/checks.txt"; exit 0 ;;
  *"issue list"*)
    if [ -f "${FAKE}/issues_fail" ]; then printf 'gh: HTTP 403\n' >&2; exit 1; fi
    cat "${FAKE}/issues.tsv"; exit 0 ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 99
STUB
chmod +x "${TMP}/bin/gh"

export PATH="${TMP}/bin:${PATH}"
export PPASS_HOOK_REPO="owner/repo"
export FAKE="${TMP}/fake"

SCRIPT="${SRC}/tools/flow/gate-status.sh"
out=""
rc=0
run() {
  out="$(bash "${SCRIPT}" 2>&1)"
  rc=$?
}
reset() {
  : >"${FAKE}/issues.tsv"
  rm -f "${FAKE}/protection_fail" "${FAKE}/issues_fail"
}
has() { case "${out}" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

printf 'gate-status：\n'

# ── 1. 停用项没有卡 → 红 ─────────────────────────────────────────────
reset
printf 'CI Review\nCI Core review\n' >"${FAKE}/workflows.txt"
printf 'identity\ngitleaks\n' >"${FAKE}/checks.txt"
printf '1440\t删除已停用的 CI Core review\tCI Core review 长期 disabled_manually\n' >"${FAKE}/issues.tsv"
run
[ "${rc}" -eq 1 ] && ok "停用项没卡：退出码 1" || bad "停用项没卡：退出码应为 1，实得 ${rc}"
has '✓ CI Core review —— 卡 #1440' && ok "有卡的停用项标出卡号" || bad "有卡的停用项没标出卡号：${out}"
has '✗ CI Review —— 没有开着的卡' && ok "没卡的停用项判红" || bad "没卡的停用项没判红：${out}"
has '2 项：identity · gitleaks' && ok "列出必需检查" || bad "必需检查没列全：${out}"

# ── 2. 反证：给 CI Review 补一张标题带它的卡 → 绿 ────────────────────
printf '1440\t删除已停用的 CI Core review\t-\n1466\t恢复 CI Review：停用期间为什么停、什么条件开\t-\n' >"${FAKE}/issues.tsv"
run
[ "${rc}" -eq 0 ] && ok "反证：停用项都有卡 → 退出码 0" || bad "反证：都有卡时应为 0，实得 ${rc}：${out}"
has '✓ CI Review —— 卡 #1466' && ok "反证：第二个停用项认到卡" || bad "反证：第二个停用项没认到卡：${out}"

# ── 3. 没有停用项 → 绿 ──────────────────────────────────────────────
: >"${FAKE}/workflows.txt"
run
[ "${rc}" -eq 0 ] && ok "没有停用项 → 退出码 0" || bad "没有停用项时应为 0，实得 ${rc}"
has '（没有）' && ok "没有停用项时明说" || bad "没有停用项时没说清：${out}"

# ── 4. 分支保护读不到 → fail-closed ─────────────────────────────────
printf 'CI Review\n' >"${FAKE}/workflows.txt"
touch "${FAKE}/protection_fail"
run
[ "${rc}" -eq 1 ] && ok "读不到分支保护：退出码 1" || bad "读不到分支保护时应为 1，实得 ${rc}"
has '读不到分支保护' && ok "读不到分支保护时明说" || bad "读不到分支保护时没说清：${out}"
rm -f "${FAKE}/protection_fail"

# ── 5. 停用项在、卡列表读不到 → fail-closed ─────────────────────────
touch "${FAKE}/issues_fail"
run
[ "${rc}" -eq 1 ] && ok "读不到卡列表：退出码 1" || bad "读不到卡列表时应为 1，实得 ${rc}"
has '读不到开放卡列表' && ok "读不到卡列表时明说" || bad "读不到卡列表时没说清：${out}"
rm -f "${FAKE}/issues_fail"

# ── 6. 只认标题：提到「workflow」的卡不算某扇具体门的账 ─────────────
printf '1465\t门状态可见：列出被停用的 workflow 与必需检查缺口\t-\n' >"${FAKE}/issues.tsv"
run
[ "${rc}" -eq 1 ] && ok "不相干的卡不算账：退出码 1" || bad "不相干的卡被算成账了，实得 ${rc}：${out}"
has '✗ CI Review —— 没有开着的卡' && ok "不相干的卡不算账：仍判红" || bad "不相干的卡被算成账：${out}"

printf '\ngate-status: %s passed, %s failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
