#!/usr/bin/env bash
# #1121：更新签名唯一使用的工具——tauri signer，从 tools/release/signer/ 的 lockfile 安装。
#
# 签名环境不执行现拉代码（对齐 SLSA）：以前是 `npx -y @tauri-apps/cli@<版本> signer`，
# 只锁了版本号、没有完整性校验，每次签名都从 registry 现拉。现在：
#   - 依赖面只有 @tauri-apps/cli 一个包（tools/release/signer/package.json）；
#   - `--frozen-lockfile`：按 lockfile 里的 integrity 哈希校验，lockfile 不符即失败；
#   - `--ignore-scripts`：不跑任何安装脚本；
#   - 包管理器本身也锁哈希：经 corepack 运行 pnpm，corepack 按 package.json 的
#     packageManager（pnpm@<版本>+sha512.<哈希>）校验下载的 pnpm，对不上即失败。
# 用法：tools/release/signer.sh <tauri signer 的参数…>（如 sign -f <key> -p "" <file>）
set -euo pipefail
DIR="$(cd "$(dirname "$0")/signer" && pwd)"
if [ ! -x "$DIR/node_modules/.bin/tauri" ]; then
  command -v corepack >/dev/null \
    || { echo "FATAL: 需要 corepack（Node 自带）按 packageManager 的哈希运行 pnpm" >&2; exit 1; }
  (cd "$DIR" && COREPACK_ENABLE_DOWNLOAD_PROMPT=0 corepack pnpm install --frozen-lockfile --ignore-scripts >&2)
fi
exec "$DIR/node_modules/.bin/tauri" signer "$@"
