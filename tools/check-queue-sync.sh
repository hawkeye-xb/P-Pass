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
QUEUE="$ROOT/docs/QUEUE.md"
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

if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "docs/QUEUE.md 与 cards/ 不同步，见上方——先手动改齐再提交。"
  exit 1
fi

echo "ok: docs/QUEUE.md 与 cards/ 同步"
