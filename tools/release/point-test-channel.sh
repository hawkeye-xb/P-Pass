#!/usr/bin/env bash
# REL-07：test 通道指针——把本次**已组装/签名**的清单原样覆盖进固定的滚动 prerelease
# `test-channel`（同 neovim 的 nightly tag）。客户端只读 releases/download/test-channel/<清单>
# 这一个静态文件：不调 GitHub API → 没有匿名限流、不需要 GH_TOKEN。清单里的下载链接仍指向
# 版本化 release（${TAG}）的资产。
#
# 每一端一份清单（#788②，与正式版的分端清单一一对应）：
#   manifest.json          Android（upload-android；老格式，Android 与 update Worker 读它）
#   manifest-windows.json  Windows（finalize-manifest-windows；Windows test 包的插件 endpoint）
# 各端只覆盖自己那份，互不等待。
#
# 用法：tools/release/point-test-channel.sh <本次清单文件>（通道里用同一个文件名）
# 输入：TAG（job env）、GITHUB_REPOSITORY；gh 已登录（GH_TOKEN）。
#
# 不变量：
#   - 本次 release 还是 draft ⇒ 不移动指针（清单里的下载链接对客户端是 404）。
#   - 重跑旧 tag 不许把指针往回拨：通道里同名清单已是更新版本就跳过。
set -euo pipefail
: "${TAG:?TAG 未设置（job env）}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY 未设置}"
SRC="${1:?用法：point-test-channel.sh <清单文件>}"
NAME=$(basename "$SRC")
CH=test-channel

[[ "$TAG" == *-test.* ]] || { echo "::error::只有 test tag 才能移动 test-channel 指针（本次 ${TAG}）"; exit 1; }
[ -s "$SRC" ] || { echo "::error::${SRC} 不在或为空——拒绝把空清单写进 test-channel"; exit 1; }

if [ "$(gh release view "$TAG" --json isDraft -q .isDraft)" = "true" ]; then
  echo "::notice::${TAG} 仍是 draft，下载链接对客户端不可达——不移动 test-channel 的 ${NAME}"
  exit 0
fi

if ! gh release view "$CH" >/dev/null 2>&1; then
  NOTES="${RUNNER_TEMP:-/tmp}/ch-notes.md"
  printf '%s\n' \
    "固定通道指针，勿删。test 通道客户端与 update Worker 只读本 release 里的各端清单；" \
    "内容随每次 test 发布覆盖（release.yml · REL-07），下载链接指向对应版本的 release。" \
    "Fixed channel pointer - do not delete. Overwritten by every test release." > "$NOTES"
  gh release create "$CH" --prerelease --latest=false --target "$(git rev-parse HEAD)" \
    --title "test channel (rolling pointer)" --notes-file "$NOTES"
fi

NEW=$(node -p 'require(process.argv[1]).version' "$(cd "$(dirname "$SRC")" && pwd)/$(basename "$SRC")")
CUR=""
CUR_FILE="${RUNNER_TEMP:-/tmp}/ch-current-${NAME}"
if gh release download "$CH" -p "$NAME" -O "$CUR_FILE" 2>/dev/null; then
  CUR=$(node -p 'require(process.argv[1]).version' "$CUR_FILE")
fi
if [ -n "$CUR" ] && [ "$CUR" != "$NEW" ] && \
   [ "$(printf '%s\n%s\n' "$CUR" "$NEW" | sort -V | tail -n1)" = "$CUR" ]; then
  echo "test-channel 的 ${NAME} 已指向更新的 ${CUR}（本次 ${NEW}）——不回拨"
  exit 0
fi
gh release upload "$CH" "$SRC" --clobber
echo "test-channel/${NAME} → ${NEW}: https://github.com/${GITHUB_REPOSITORY}/releases/download/${CH}/${NAME}"
