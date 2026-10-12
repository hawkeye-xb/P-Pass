#!/usr/bin/env bash
# #316：把 assets/i18n/*.json **逐字节**拷进 iOS App（apps/ios/PPass/Resources/i18n/）。
#
#   tools/ios/sync-i18n.sh            # 拷贝（just ios-sync-i18n）
#   tools/ios/sync-i18n.sh --check    # 只比较，不一致 exit 1
#
# 源文件只读不改。源目录里删掉的语言，副本里也删（副本 = 源的镜像）。
# 漂移门禁在 XCTest（I18nDriftTests）里，比的是构建出来的 App bundle；本脚本的 --check
# 是不需要模拟器的快速版本。四个消费者的清单见 apps/ios/PPass/I18n/DiagText.swift。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/assets/i18n"
DST="$ROOT/apps/ios/PPass/Resources/i18n"

if [ "${1:-}" = "--check" ]; then
  # 写死 /usr/bin/diff：已踩过 PATH 上别的工具链自带的 diff 不认 -r、报错却退出 0，--check 因此误报一致。
  if /usr/bin/diff -r "$SRC" "$DST" >/dev/null 2>&1; then
    echo "ok: apps/ios/PPass/Resources/i18n 与 assets/i18n 逐字节一致"
    exit 0
  fi
  echo "✗ apps/ios/PPass/Resources/i18n 与 assets/i18n 不一致——跑 just ios-sync-i18n：" >&2
  /usr/bin/diff -rq "$SRC" "$DST" >&2 || true
  exit 1
fi

mkdir -p "$DST"
rm -f "$DST"/*.json
cp "$SRC"/*.json "$DST"/
echo "synced: $(cd "$DST" && ls *.json | tr '\n' ' ')→ apps/ios/PPass/Resources/i18n/"
