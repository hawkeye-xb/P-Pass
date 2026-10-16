#!/usr/bin/env bash
# SEC-15 (#1003)：PR / push 上的 `cargo deny check advisories`，**只在本次改动
# 碰了这棵依赖树时才跑**。
#
# 为什么拆：licenses / bans 只取决于 Cargo.lock，结果不会自己变 ⇒ 留在 PR 硬门禁
# 里照跑。advisories（含 yanked）读的是**外部**的 RustSec 数据库与 crates.io
# 撤回状态，随时间变化 ⇒ 代码一行没改，所有 PR 也会突然全红。实测三次：
# #715（iroh-blobs yank）、#961（rustls 公告）、#1003（zip yank）。
# 这类信号改由 .github/workflows/audit-advisories.yml 每天定时跑、红了开 issue；
# PR 上只在**你自己**动了锁文件或 deny.toml 时查——那时引入的新版本归你负责。
# 这是 cargo-deny 官方 Action README 推荐的拆法。
#
# 判据：<dir>/Cargo.lock 或 <dir>/deny.toml 相对 HEAD^1 有改动 ⇒ 跑。
#   PR 上 HEAD 是 GitHub 生成的合并提交，HEAD^1 = 目标分支当前 tip，所以 diff
#   恰好是本 PR 带来的改动；push 到 main 时 HEAD^1 = 上一个 main 提交。
#   checkout 需要 `fetch-depth: 2` 才拿得到 HEAD^1。
# ⚠️ **fail-closed**：拿不到 HEAD^1（浅克隆、首个提交）或 diff 失败 ⇒ 照跑。
#    判据自己出错时绝不能放行（CI-11 #255 那类 fail-open 的教训）。
#
# 用法：tools/ci-deny-advisories.sh <dir>     （<dir> 相对仓库根，如 . 或 apps/desktop/src-tauri）
# 测试：tools/test-ci-deny-advisories.sh
set -euo pipefail

DIR="${1:?usage: $0 <dir>}"
CARGO="${CARGO:-cargo}"
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT/$DIR"

prefix="${DIR#./}"
prefix="${prefix%/}"
if [ -z "$prefix" ] || [ "$prefix" = "." ]; then
  paths=(Cargo.lock deny.toml)
else
  paths=("$prefix/Cargo.lock" "$prefix/deny.toml")
fi

run=1
reason=""
if ! git -C "$ROOT" rev-parse -q --verify 'HEAD^1^{commit}' >/dev/null; then
  reason="拿不到 HEAD^1（浅克隆或首个提交）——fail-closed，照跑"
elif changed=$(git -C "$ROOT" diff --name-only 'HEAD^1' HEAD -- "${paths[@]}"); then
  if [ -z "$changed" ]; then
    run=0
  else
    reason="本次改动碰了：$(echo "$changed" | tr '\n' ' ')"
  fi
else
  reason="git diff 失败——fail-closed，照跑"
fi

if [ "$run" = 0 ]; then
  echo "::notice::advisories 跳过：本次未改 ${paths[*]}。外部公告/撤回由每日定时任务 audit-advisories 负责（#1003）。"
  exit 0
fi

echo "advisories 要跑：$reason"
exec "$CARGO" deny check advisories
