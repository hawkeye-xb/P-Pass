#!/usr/bin/env bash
# UPD-15（#685）：**产物名的唯一真相**。
#
#   规则（一条）：`P-Pass_<该端版本号>_<平台/架构>.<扩展名>`
#     - Android : P-Pass_0.9.0_android.apk
#     - macOS   : P-Pass_0.9.1_macos-arm64.dmg / .app.tar.gz（#539 起不再出 .zip）
#     - Windows : P-Pass_<desktop>_x64-setup.exe（Tauri NSIS 自带，同规则，本脚本不管）
#
#   版本号不在这里算 —— 一律走 `tools/release-version.sh <platform>`：
#   正式 tag 取 `release/versions.json` 该端的号；`-test.` tag 取 tag 名。
#   ⇒ 产物名 / 更新清单里的 url / 镜像下载文件名 全由这一个函数派生，
#     不存在「三处各写一遍」的漂移。
#
# 用法：
#   tools/artifact-names.sh <key>        # 打印单个名字
#   tools/artifact-names.sh --json       # 打印全部（给脚本/校验用）
# keys: android-apk android-apk-unsigned macos-dmg macos-updater sha256-macos
#
# ⚠️ macOS 自带 bash 3.2：不许用关联数组（declare -A）——用 case。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

A="$(tools/release-version.sh android)"
D="$(tools/release-version.sh desktop)"

name_of() {
  case "$1" in
    android-apk)          echo "P-Pass_${A}_android.apk" ;;
    android-apk-unsigned) echo "P-Pass_${A}_android-unsigned.apk" ;;
    macos-dmg)      echo "P-Pass_${D}_macos-arm64.dmg" ;;
    macos-updater)  echo "P-Pass_${D}_macos-arm64.app.tar.gz" ;;
    sha256-macos)   echo "SHA256SUMS-macos-arm64" ;;
    *) return 1 ;;
  esac
}

if [ "${1:-}" = "--json" ]; then
  jq -n --arg a "$A" --arg d "$D" \
    --arg apk "$(name_of android-apk)" \
    --arg apku "$(name_of android-apk-unsigned)" \
    --arg dmg "$(name_of macos-dmg)" \
    --arg upd "$(name_of macos-updater)" \
    '{android:$a, desktop:$d, names:{"android-apk":$apk,"android-apk-unsigned":$apku,"macos-dmg":$dmg,"macos-updater":$upd}}'
  exit 0
fi

if ! out="$(name_of "${1:-}")"; then
  echo "usage: $0 <android-apk|android-apk-unsigned|macos-dmg|macos-updater|sha256-macos|--json>" >&2
  exit 1
fi
echo "$out"
