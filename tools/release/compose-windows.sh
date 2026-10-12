#!/usr/bin/env bash
# #788②：release.yml · finalize-manifest-windows ·「Compose Windows manifest」。
#
# Windows 与 macOS 同一套标准 Tauri 更新：一份**只含本端条目**的分端清单
# manifest-windows.json，顶层 version = 本端版本号（tools/release-version.sh desktop），
# 下载链接指向本 release 的 NSIS 安装包（Tauri v2 的 Windows 更新包就是安装包本身）。
# 组装用同一个 make-update-manifest.mjs；签名在下一步（tools/release/sign-desktop.sh）。
#
# 输入（显式）：
#   TAG          本次发布的 tag（job env）
#   RELEASE_TAG  tools/release-version.sh 判 test / 正式线用（workflow 顶层 env）
#   artifacts/windows-x64-installer/P-Pass_*_x64-setup.exe
# 输出：artifacts/manifest-windows.json（signature 为空，待签）
# Windows lane 成功、安装包却不在 ⇒ ::error:: 并退出 1（绝不发半份清单）。
set -euo pipefail
: "${TAG:?TAG 未设置（job env）}"
: "${RELEASE_TAG:?RELEASE_TAG 未设置（workflow 顶层 env）}"
cd "$(dirname "$0")/../.."

EXE=$(find artifacts/windows-x64-installer -maxdepth 1 -name 'P-Pass_*_x64-setup.exe' 2>/dev/null | head -1 || true)
[ -n "$EXE" ] || { echo "::error::Windows lane 成功但 P-Pass_*_x64-setup.exe 不在——拒绝写半份清单"; exit 1; }

# 与其它分端清单同口径：恒指 GitHub 直链（R2 的改写在 mirror-latest.yml 里做）。
ASSET_BASE="https://github.com/hawkeye-xb/P-Pass/releases/download/${TAG}"
node tools/make-update-manifest.mjs \
  --tag "$TAG" --notes-dir release/notes \
  --asset-base "$ASSET_BASE" \
  --asset windows-x86_64="$EXE" \
  --version "$(tools/release-version.sh desktop)" \
  --only windows-x86_64 --out artifacts/manifest-windows.json
