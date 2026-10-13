#!/usr/bin/env bash
# #943：iOS App 的颜色只有一个来源——tokens.json 生成的 PPColor（Tokens.generated.swift）。
# 设计语言是品牌基础、与 Android 一致；组件可以原生，颜色不能交给系统。两类写法都拦：
#   A. 色值字面量（Tokens.generated.swift 是唯一允许写字面量的文件）：
#      Color(red: / Color(.sRGB / Color(hex / Color(white: / Color(hue: / UIColor(red: / UIColor(white: / UIColor(hue: /
#      UIColor(hex / #colorLiteral(
#   B. 系统供给的界面颜色 / 表面：
#      Color(uiColor: …)、UIColor.system… / .label / .secondaryLabel … / .white / .black / .gray …、
#      Color.primary / .secondary / .accentColor / .white / .black / .red … 等具名系统色、
#      .foregroundStyle(.primary|.secondary|.tertiary|.quaternary)、.tint(.white) 这类系统样式色，以及 return .secondary / cond ? .red : … 这种省略类型名的写法、
#      .regularMaterial 等系统材质（带系统灰调的表面）。
#      允许：Color.clear、PPColor.*、token 的 opacity 变体。
#      UIKit appearance 里用 UIColor(PPColor.x) 包 token，不命中。
#
#   tools/ios/check-no-color-literals.sh [目录，默认 apps/ios/PPass]
#   tools/ios/check-no-color-literals.sh --self-test     # 反证：往临时目录丢违规写法，门禁必须变红
# 文字级门禁，色值本身对不对靠 DesignTokensTests 与 gen-tokens.py --check。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

LITERAL='Color\(\s*(red|white|hue|hex|\.sRGB|\.displayP3|\.sRGBLinear)\b|UIColor\(\s*(red|white|hue|hex)\b|#colorLiteral\('
NAMED='(Color|UIColor)\.(primary|secondary|accentColor|white|black|gray|grey|red|green|blue|orange|yellow|pink|purple|brown|cyan|mint|teal|indigo|label|secondaryLabel|tertiaryLabel|quaternaryLabel|separator|opaqueSeparator|link|placeholderText|system[A-Za-z]*)\b'
UICOLOR='Color\(\s*uiColor:|UIColor\s*\.\s*(system[A-Za-z]*|label|secondaryLabel|tertiaryLabel|quaternaryLabel|separator|opaqueSeparator|link|placeholderText|white|black|gray|red|green|blue|orange|yellow|clear)\b|UIColor\(\s*\.system'
STYLE='\.(foregroundStyle|foregroundColor|tint|background|fill|stroke|accentColor|listRowBackground|overlay)\(\s*\.(primary|secondary|tertiary|quaternary|quinary|white|black|gray|red|green|blue|orange|yellow|pink|purple|accentColor|tint|separator|fill|background|foreground)\b'
BARE='(return|[?:]|=)\s*\.(primary|secondary|tertiary|quaternary|quinary|white|black|gray|red|green|blue|orange|yellow|pink|purple|accentColor)\b'
MATERIAL='\.(ultraThin|thin|regular|thick|ultraThick|bar)Material\b'
PATTERN="$LITERAL|$NAMED|$UICOLOR|$STYLE|$BARE|$MATERIAL"

scan() {
  grep -rnE --include='*.swift' "$PATTERN" "$1" | grep -v 'Tokens.generated.swift' || true
}

if [ "${1:-}" = "--self-test" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  printf 'import SwiftUI\nlet bad = Color(red: 0.1, green: 0.2, blue: 0.3)\n' > "$TMP/Bad1.swift"
  printf 'import SwiftUI\nlet bad = UIColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 1)\n' > "$TMP/Bad2.swift"
  printf 'import SwiftUI\nlet bad = Color(uiColor: .systemBackground)\n' > "$TMP/Bad3.swift"
  printf 'import SwiftUI\nstruct V: View { var body: some View { Text("x").foregroundStyle(.secondary) } }\n' > "$TMP/Bad4.swift"
  printf 'import SwiftUI\nfunc c() -> Color { return .secondary }\n' > "$TMP/Bad9.swift"
  printf 'import SwiftUI\nlet bad = Color.primary\n' > "$TMP/Bad5.swift"
  printf 'import SwiftUI\nstruct V: View { var body: some View { Text("x").background(.regularMaterial) } }\n' > "$TMP/Bad6.swift"
  printf 'import SwiftUI\nstruct V: View { var body: some View { Text("x").tint(.white) } }\n' > "$TMP/Bad7.swift"
  printf 'import UIKit\nlet bad = UIColor.systemRed\n' > "$TMP/Bad8.swift"
  printf 'import SwiftUI\nstruct V: View { var body: some View { Text("x").foregroundStyle(PPColor.ink).background(Color.clear).tint(PPColor.ink) } }\nlet ok = UIColor(PPColor.paper)\n' > "$TMP/Ok.swift"
  hits=$(scan "$TMP")
  [ "$(printf '%s\n' "$hits" | grep -c 'Bad')" = 9 ] || { echo "✗ 自测失败：违规写法没全被拦住（应 9 个文件）：" >&2; printf '%s\n' "$hits" >&2; exit 1; }
  if printf '%s\n' "$hits" | grep -q 'Ok.swift'; then echo "✗ 自测失败：token 写法被误拦" >&2; exit 1; fi
  echo "ok: 自测通过（9 类违规被拦、token 写法放行）"
  exit 0
fi

DIR="${1:-$ROOT/apps/ios/PPass}"
hits=$(scan "$DIR")
if [ -n "$hits" ]; then
  echo "✗ 出现色值字面量 / 系统颜色（颜色只能用 PPColor，见 apps/ios/PPass/Design/PPStyle.swift）：" >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi
echo "ok: ${DIR#"$ROOT"/} 里没有色值字面量，也没有系统颜色 / 材质"
