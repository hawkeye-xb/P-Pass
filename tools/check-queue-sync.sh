#!/usr/bin/env bash
# Enforces that docs/QUEUE.md stays in sync with cards/.
#
# Two directions, both real drift modes seen in practice (2026-08-27 audit):
#   1. Forward — every card sitting in cards/ (root, i.e. not yet done/
#      backlog/) must be mentioned somewhere in docs/QUEUE.md. A card that
#      exists but isn't indexed is invisible to whoever is dispatching work
#      (this is exactly how MOB-43/NET-02 went missing from the old index).
#   2. Reverse — every `cards/...md` link written in docs/QUEUE.md must
#      point at a file that still exists. A card that got archived/renamed
#      but whose QUEUE.md row wasn't updated is a dangling promise.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# QUEUE_FILE 仅供 tools/test-queue-archive-gate.sh 注入变异副本做反证；默认真文件
QUEUE="${QUEUE_FILE:-$ROOT/docs/QUEUE.md}"
FAIL=0

echo "==> queue-sync 1/2: every root card must appear in docs/QUEUE.md"

for f in "$ROOT"/cards/*.md; do
  base="$(basename "$f")"
  case "$base" in
    README.md|TEMPLATE.md) continue ;;
  esac
  id="$(echo "$base" | grep -oE '^[A-Za-z0-9]+-[0-9]+' || true)"
  if [ -z "$id" ]; then
    echo "   SKIP (no ID prefix, eyeball it): ${base}"
    continue
  fi
  if ! grep -q "${id}" "$QUEUE"; then
    echo "   FAIL missing-from-queue: ${id} (${base}) 在 cards/ 根目录，但 docs/QUEUE.md 没提到它"
    FAIL=1
  fi
done

if [ "$FAIL" -eq 0 ]; then
  echo "   ✅ 根目录卡全部在 QUEUE.md 里"
fi

echo "==> queue-sync 2/2: docs/QUEUE.md 里的卡链接不许悬空"

# Extract every relative link that points at a card file, e.g. (../cards/FOO.md)
LINKS="$(grep -oE '\(\.\./cards/[A-Za-z0-9._-]+\.md\)' "$QUEUE" | tr -d '()' || true)"
while IFS= read -r link; do
  [ -z "$link" ] && continue
  target="$ROOT/docs/${link}"
  if [ ! -f "$target" ]; then
    echo "   FAIL dangling-link: docs/QUEUE.md references ${link} - file does not exist"
    FAIL=1
  fi
done <<< "$LINKS"

if [ "$FAIL" -eq 0 ]; then
  echo "   ✅ QUEUE.md 里没有悬空的卡链接"
fi

echo "==> queue-sync 3/3: 归档出口——历史不许回到待办队列"

# 2026-09-16 归档出口门禁。三条断言，各自针对一个真实漂移模式：
#   a. 分区集合固定 —— 原「五、已完成 / 已归档」分区曾长到 45 行 / 14.1KB，
#      是 QUEUE.md 最大的一块，而本文件头部自己写着"只写跟现在有关的"。
#      分区增删改名必须是一次显式提交（同时改本脚本），不能悄悄长出来。
#   b. 没有分区标题含「已归档」—— 历史账本是 PROGRESS.md / ROADMAP.md，
#      不是待办队列。
#   c. 活分区（一~四）不许出现指向 cards/done/ 的行 —— 完成的卡不许占
#      待办分区的行。分区七（拆卡索引）和八（backlog）可以引用 done 卡，
#      那是引用不是登记，故不在此列。
if ! python3 - "$QUEUE" <<'PYGATE'
import re, sys

queue = sys.argv[1]
lines = open(queue, encoding="utf-8").read().split("\n")
heads = [(i, l) for i, l in enumerate(lines) if l.startswith("## ")]

EXPECTED = ["〇", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
LIVE = {"一", "二", "三", "四"}

def num(h):
    m = re.match(r"## ([〇一二三四五六七八九十]+)、", h)
    return m.group(1) if m else None

got = [num(h) for _, h in heads]
bad = False

if got != EXPECTED:
    print(f"   FAIL section-drift: 分区序号集合变了\n     期望 {EXPECTED}\n     实际 {got}")
    print("     分区增删/改名要连同 tools/check-queue-sync.sh 的 EXPECTED 一起显式改。")
    bad = True

for _, h in heads:
    if "已归档" in h:
        print(f"   FAIL archive-section-returned: {h.strip()}")
        print("     历史账本是 docs/PROGRESS.md / docs/ROADMAP.md，不是待办队列。")
        bad = True

bounds = [i for i, _ in heads] + [len(lines)]
for (start, head), end in zip(heads, bounds[1:]):
    n = num(head)
    if n not in LIVE:
        continue
    for off, line in enumerate(lines[start:end]):
        if "../cards/done/" in line:
            print(f"   FAIL done-card-in-live-section: 行 {start + off + 1}（{head.strip()}）")
            print("     已归档的卡不许占活分区的行——先把行删掉，账留在 PROGRESS.md。")
            bad = True

if bad:
    sys.exit(1)
print("   ✅ 分区集合固定、无已归档分区、活分区无 done 卡登记")
PYGATE
then
  FAIL=1
fi

if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "docs/QUEUE.md 与 cards/ 不同步，见上方——先手动改齐再提交。"
  exit 1
fi

echo "ok: docs/QUEUE.md 与 cards/ 同步"
