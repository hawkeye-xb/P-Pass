#!/usr/bin/env bash
# #943：iOS App 源码里不得出现色值字面量——颜色只有三个来源：
#   1. 系统语义色（.primary / .secondary / Color(uiColor: .systemBackground) …）
#   2. 品牌 token：PPColor（由 tokens.json 生成，Tokens.generated.swift 是唯一允许写字面量的文件）
#   3. PPTone（PPStyle.swift：用 1、2 组合出的 accent 与含义色，不含字面量）
#
#   tools/ios/check-no-color-literals.sh [目录，默认 apps/ios/PPass]
#   tools/ios/check-no-color-literals.sh --self-test     # 反证：往临时目录丢一个字面量，门禁必须变红
#
# 拦的写法（命中即红，输出文件:行）：
#   Color(red: / Color(.sRGB / Color(hex / Color(white: / Color(hue:
#   UIColor(red: / UIColor(white: / UIColor(hue: / UIColor(hex
#   #colorLiteral(
# 不拦：具名系统色（Color.red 等）——放宽范围见 #943：系统语义色与系统控件样式允许，
# 未登记的自定义颜色（任何字面量）不允许。文字级门禁，色值本身对不对靠 DesignTokensTests 与截图。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

PATTERN='Color\(\s*(red|white|hue|hex|\.sRGB|\.displayP3|\.sRGBLinear)\b|UIColor\(\s*(red|white|hue|hex)\b|#colorLiteral\('

scan() {
  grep -rnE --include='*.swift' "$PATTERN" "$1" | grep -v 'Tokens.generated.swift' || true
}

if [ "${1:-}" = "--self-test" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  printf 'import SwiftUI\nlet bad = Color(red: 0.1, green: 0.2, blue: 0.3)\n' > "$TMP/Bad.swift"
  printf 'import SwiftUI\nlet bad = UIColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)\n' > "$TMP/Bad2.swift"
  printf 'import SwiftUI\nlet ok = Color(uiColor: .systemBackground)\n' > "$TMP/Ok.swift"
  hits=$(scan "$TMP")
  [ "$(printf '%s\n' "$hits" | grep -c 'Bad')" = 2 ] || { echo "✗ 自测失败：字面量没被拦住" >&2; exit 1; }
  if printf '%s\n' "$hits" | grep -q 'Ok.swift'; then echo "✗ 自测失败：系统语义色被误拦" >&2; exit 1; fi
  echo "ok: 自测通过（字面量被拦、系统语义色放行）"
  exit 0
fi

DIR="${1:-$ROOT/apps/ios/PPass}"
hits=$(scan "$DIR")
if [ -n "$hits" ]; then
  echo "✗ 出现色值字面量（颜色走系统语义色 / PPColor / PPTone，见 apps/ios/PPass/Design/PPStyle.swift）：" >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi
echo "ok: ${DIR#"$ROOT"/} 里没有色值字面量"
