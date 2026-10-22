#!/usr/bin/env bash
# #1121：生成一对更新签名密钥，并把私钥存进 GitHub secret——**由仓库所有者本人运行**。
#
# 用法：tools/release/new-update-key.sh test
#   1. 用 lockfile 安装的 tauri signer 生成密钥对（空密码，与 CI 非交互签名一致）；
#      私钥写到 ~/.ppass-update-keys/（0700 目录、0600 文件），不进仓库、不打印。
#   2. `gh secret set UPDATE_SIGNING_KEY_TEST`（从文件读入，不经命令行参数、不进 shell 历史）。
#   3. 公钥写到 release/update-keys/test.pub——之后提交它：桌面与 Android 的 test 构建
#      从这里内置 test 公钥。
#   之后把私钥备份进密码管理器，再删掉本地文件（见 docs/runbook/update-signing-keys.md）。
#
# 只生成 test 通道的密钥。正式通道的密钥更换要走轮换流程（旧密钥签发携带新公钥的
# 过渡版本），不能直接替换，见同一份 runbook。
set -euo pipefail
[ "${1:-}" = "test" ] || { echo "用法：$0 test（正式密钥的更换见 docs/runbook/update-signing-keys.md 的轮换流程）" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PUB_OUT="$ROOT/release/update-keys/test.pub"
SECRET=UPDATE_SIGNING_KEY_TEST

DIR="$HOME/.ppass-update-keys"
mkdir -p "$DIR" && chmod 700 "$DIR"
KEY="$DIR/test-$(date +%Y%m%d-%H%M%S).key"
[ ! -e "$KEY" ] || { echo "FATAL: $KEY 已存在" >&2; exit 1; }

CI=true "$ROOT/tools/release/signer.sh" generate -w "$KEY" -p "" --ci >/dev/null
chmod 600 "$KEY"
[ -s "$KEY" ] && [ -s "$KEY.pub" ] || { echo "FATAL: 密钥生成失败" >&2; exit 1; }

# 私钥从文件进 secret：不经命令行参数（ps 看得到）、不经终端回显。
(cd "$ROOT" && gh secret set "$SECRET" <"$KEY")

mkdir -p "$(dirname "$PUB_OUT")"
cp "$KEY.pub" "$PUB_OUT"
echo "✓ 私钥已存入 secret ${SECRET}；本地副本：${KEY}（备份进密码管理器后删除）"
echo "✓ 公钥已写到 release/update-keys/test.pub——提交它，test 构建才会内置这把公钥"
