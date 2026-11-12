#!/usr/bin/env bash
# 重建审核环境的库位置配置（#1661，幂等，可重跑）。
#
# 用法：sudo infra/review-env/scripts/restore-library-config.sh [数据根，默认 /var/lib/ppass-review]
#
# 复位（换身份/清库）会删掉数据根的内容，`p-pass/.ppf` 库标记与 `p-pass/config.toml`
# 也在其中；没有它们，headless daemon 起来会停在「未配置」，而这台机器没有窗口程序
# 来完成首启向导。install.sh 与人工复位都调用这一份，避免两处写法漂移。
set -euo pipefail

ROOT="${1:-/var/lib/ppass-review}"
PKG="$ROOT/p-pass"

[ "$(id -u)" = "0" ] || { echo "要 root（要建 ${PKG}）" >&2; exit 1; }

# #1253：库标记，daemon 认它判「库在」。
mkdir -p "$PKG/.ppf"
# #1115：库位置的正本是平台 config.toml；已有就不动（可能有人手工改过 data_dir）。
[ -e "$PKG/config.toml" ] || printf 'data_dir = "%s"\n' "$PKG" >"$PKG/config.toml"
echo "库配置就绪：${PKG}（config.toml: $(cat "$PKG/config.toml")）"
