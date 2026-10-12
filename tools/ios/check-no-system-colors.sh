#!/usr/bin/env bash
# #344：iOS App 源码里禁止 SwiftUI / UIKit 默认库色——颜色一律走 PPColor（由 tokens.json 生成）。
#
#   tools/ios/check-no-system-colors.sh [目录，默认 apps/ios/PPass]
#
# 拦的写法（命中即红，输出文件:行）：
#   Color.red / Color.blue / Color.primary / Color.accentColor …   具名系统色
#   .foregroundStyle(.blue) / .tint(.green) / .background(.gray) …  形状样式简写
#   Color(.systemXxx) / UIColor.systemXxx / UIColor.label …         UIKit 动态系统色
# 不拦：Color.clear（透明不是颜色选择）、生成文件 Tokens.generated.swift（它就是 token 本身）。
# 文字级门禁，只防「顺手写了个 .blue」；色值是否对，靠 DesignTokensTests 与截图人读。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="${1:-$ROOT/apps/ios/PPass}"

NAMES='red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|gray|grey|black|white|primary|secondary|accentColor'
PATTERN="Color\\.(${NAMES})\\b|\\.(tint|foregroundColor|foregroundStyle|background|fill|stroke|border|overlay|accentColor|listRowBackground|scrollContentBackground)\\(\\.(${NAMES})\\b|Color\\(\\.(system|label|secondaryLabel|tertiaryLabel)|UIColor\\.(system[A-Za-z]*|label|secondaryLabel|tertiaryLabel|link|tintColor)\\b"

hits=$(grep -rnE --include='*.swift' "$PATTERN" "$DIR" | grep -v 'Tokens.generated.swift' || true)
if [ -n "$hits" ]; then
  echo "✗ 用了系统默认色（颜色一律走 PPColor，见 apps/ios/PPass/Design/Tokens.generated.swift）：" >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi
echo "ok: ${DIR#"$ROOT"/} 里没有系统默认色"
