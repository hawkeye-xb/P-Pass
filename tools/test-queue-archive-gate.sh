#!/usr/bin/env bash
# 反证 tools/check-queue-sync.sh 的 3/3 归档出口门禁不是恒真式。
#
# §C.2 要求：故障类判据必须有反证——把故障条件去掉/造出来，判据必须变色。
# 这里对 docs/QUEUE.md 造三种真实漂移模式的变异副本，门禁每次都必须变红；
# 未变异的真文件必须绿。任一条不符即退出非零。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GATE="$ROOT/tools/check-queue-sync.sh"
REAL="$ROOT/docs/QUEUE.md"
TMP="$(mktemp -d /tmp/ppf-queue-gate.XXXX)"
trap 'rm -rf "$TMP"' EXIT
FAIL=0

run_gate() { QUEUE_FILE="$1" bash "$GATE" >"$TMP/out" 2>&1; }

expect() { # expect <期望退出码 pass|fail> <说明> <副本路径>
  local want="$1" desc="$2" file="$3"
  if run_gate "$file"; then got=pass; else got=fail; fi
  if [ "$got" = "$want" ]; then
    echo "   ✅ $desc → $got（符合期望）"
  else
    echo "   ❌ $desc → $got，期望 $want"
    sed 's/^/        /' "$TMP/out"
    FAIL=1
  fi
}

echo "==> 基线：未变异的真 docs/QUEUE.md 必须绿"
expect pass "真文件" "$REAL"

echo "==> 变异 A：长回一个「已归档」分区"
cp "$REAL" "$TMP/a.md"
printf '\n## 十一、已完成 / 已归档（历史）\n\n| 卡 | 结果 |\n|---|---|\n' >> "$TMP/a.md"
expect fail "新增已归档分区" "$TMP/a.md"

echo "==> 变异 B：把一张已归档卡登记进活分区（三、可接队列）"
python3 - "$REAL" "$TMP/b.md" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src, encoding="utf-8").read().split("\n")
i = next(k for k, l in enumerate(lines) if l.startswith("## 三、"))
j = next(k for k, l in enumerate(lines[i:], i) if l.startswith("|---"))
lines.insert(j + 1, "| P1 | [NET-20](../cards/done/NET-20-flow-offer-must-presence-check-before-fetching-bytes.md) | 已归档的卡硬塞进可接队列 | L1 |")
open(dst, "w", encoding="utf-8").write("\n".join(lines))
PY
expect fail "活分区出现 done 卡登记" "$TMP/b.md"

echo "==> 变异 C：删掉一个分区（分区漂移）"
python3 - "$REAL" "$TMP/c.md" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src, encoding="utf-8").read().split("\n")
i = next(k for k, l in enumerate(lines) if l.startswith("## 九、"))
j = next(k for k, l in enumerate(lines[i + 1:], i + 1) if l.startswith("## "))
del lines[i:j]
open(dst, "w", encoding="utf-8").write("\n".join(lines))
PY
expect fail "分区被删" "$TMP/c.md"

echo ""
if [ "$FAIL" -ne 0 ]; then
  echo "反证失败：3/3 门禁没有按预期变色，它可能是恒真式。"
  exit 1
fi
echo "ok: 3/3 归档出口门禁的反证成立（真文件绿，三种漂移全部变红）"
