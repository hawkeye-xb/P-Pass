#!/usr/bin/env bash
# Fetch a static ffmpeg binary into tools/ffmpeg/ for machines without one.
# media-codec discovery order: PPF_FFMPEG env → <exe_dir>/tools/ffmpeg →
# PATH. This script serves dev machines and the Windows CI lane
# (ci-rust.yml `test (windows)`; the Linux lane uses apt instead).
#
# Usage: tools/fetch-ffmpeg.sh [dest_dir]   (default: tools/ffmpeg)
#   PPF_FFMPEG_FORCE_FETCH=1  ignore any ffmpeg already on PATH and fetch the
#                             pinned build anyway (CI uses this — see below).
#
# ── SEC-06 (#252)：Windows 分支钉死版本 + 校验和 ────────────────────────
# 原先这里是 `https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip`
# —— 一个**滚动地址**：没有版本号、没有校验和，每次 CI 都拉一个「当时最新」
# 的可执行文件下来并在 runner 上执行它。与本仓「action 全 pin 40 位 SHA」的
# 口径直接冲突。
#
# 它同时还坏了：2026-09-21 实测 gyan.dev 对 GitHub runner 出口 IP 返回 503
# （本机同一 URL 200），`main` 与 PR #358 连续三次全红在这一行。所以换源
# 不只是供应链洁癖，是这条 lane 当时根本跑不起来。
#
# 现在钉在 BtbN/FFmpeg-Builds 的**不可变 tag** 上：
#   - `autobuild-*` 是打完就不再变的 tag（`latest` 是滚动的，**不许用**）；
#   - asset 由 GitHub Releases 托管，对 runner 不限流；
#   - 校验和取自该 release 的 `checksums.sha256`，并**已本地下载实算核对过**
#     一次再抄进来（发布方自报的校验和只证明「和发布方说的一致」，钉进本仓
#     才是真正的冻结点——和 pin action SHA 是同一个道理）。
#   - 选 `lgpl` 而不是 `gpl`：该构建 `--disable-libx264 --disable-libx265
#     --disable-libxvid`，不含 GPL 组件，与 BUILD-08 给 libheif 选 `[core]`
#     摘掉 x265 的取舍一致。
#
# 👉 升级版本时三处一起改：URL 的 tag、文件名、SHA256。改完必须重跑一次
#    反证（把 SHA256 改错一位 → 本脚本必须非零退出）。
FFMPEG_WIN_TAG="autobuild-2026-09-20-13-11"
FFMPEG_WIN_ZIP="ffmpeg-n9.0.2-3-ga5923073bf-win64-lgpl-9.0.zip"
FFMPEG_WIN_SHA256="ec1706ea5c63a73030e485ec6954f0d6a672508c9548a1c5ed07c85c90ee4ef3"

# ── macOS / Linux 两条分支的结论（#252 验收标准 3，不许默默只修 Windows）──
# **本卡不动它们**，理由分两层：
#   - Linux：CI 上**根本不走这个脚本**。ci-rust.yml 的 Linux job 用
#     `apt-get install ffmpeg`，走发行版签名，本卡要解决的「未校验的第三方
#     下载」在那条路上不存在。脚本的 Linux 分支只服务开发机。
#   - macOS：CI 上目前没有 macOS job，同样只服务开发机。
# 两条分支确实仍是滚动地址、无校验和，但它们**不在 CI 路径上**，按红线 1
# （issue 外的活不做）不顺手修。已单独开卡 #363 跟踪 —— 尤其 #278 正在把 macOS
# 编译搬进 PR CI，一旦 macOS 上了 CI 路径，那条分支就变成和 Windows 同级的
# 缺口，必须在那之前收掉。
set -euo pipefail

DEST="${1:-$(dirname "$0")/ffmpeg}"
mkdir -p "$DEST"

# 校验和比对。**fail-closed**：算不出、对不上，一律删文件 + 非零退出，
# 绝不「校验不了就先用着」。
verify_sha256() {
  local file="$1" expected="$2" actual=""
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$file" | cut -d' ' -f1)"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "$file" | cut -d' ' -f1)"
  else
    echo "no sha256 tool (sha256sum/shasum) available —— 拒绝使用未校验的下载" >&2
    rm -f "$file"
    exit 1
  fi
  if [ "$actual" != "$expected" ]; then
    echo "SHA256 MISMATCH —— 下载物与钉死的校验和不符，已删除并中止：" >&2
    echo "  file:     $file" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    rm -f "$file"
    exit 1
  fi
  echo "sha256 verified: $actual"
}

# PATH 上已有 ffmpeg 就不折腾 —— 但 CI 必须绕开这条。
# 理由：这条早退意味着「runner 镜像哪天自带了 ffmpeg，CI 就会静默改用那个
# 未经本仓校验的二进制」，本卡钉版本+校验和的努力当场归零（而且没人会发现）。
# 所以 ci-rust.yml 里设 PPF_FFMPEG_FORCE_FETCH=1，CI 永远用钉死的那一个。
if [ -z "${PPF_FFMPEG_FORCE_FETCH:-}" ] && command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg already on PATH ($(command -v ffmpeg)) — nothing to do."
  echo "Set PPF_FFMPEG_FORCE_FETCH=1 to fetch the pinned build anyway."
  exit 0
fi

OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
  Darwin)
    # evermeet.cx serves the latest static macOS build (x86_64; runs on
    # Apple Silicon via Rosetta — fine for a dev fallback).
    # ⚠️ 滚动地址、无校验和 —— 见文件头「macOS / Linux 结论」。
    URL="https://evermeet.cx/ffmpeg/getrelease/zip"
    curl -fL "$URL" -o "$DEST/ffmpeg.zip"
    unzip -o "$DEST/ffmpeg.zip" -d "$DEST"
    rm "$DEST/ffmpeg.zip"
    ;;
  Linux)
    case "$ARCH" in
      x86_64) JV_ARCH="amd64" ;;
      aarch64) JV_ARCH="arm64" ;;
      *) echo "unsupported Linux arch: $ARCH" >&2; exit 1 ;;
    esac
    # ⚠️ 滚动地址、无校验和 —— 见文件头「macOS / Linux 结论」。
    # CI 不走这里（Linux job 用 apt）。
    URL="https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-${JV_ARCH}-static.tar.xz"
    curl -fL "$URL" -o "$DEST/ffmpeg.tar.xz"
    tar -xJf "$DEST/ffmpeg.tar.xz" --strip-components=1 -C "$DEST" --wildcards '*/ffmpeg'
    rm "$DEST/ffmpeg.tar.xz"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/${FFMPEG_WIN_TAG}/${FFMPEG_WIN_ZIP}"
    echo "fetching pinned ffmpeg: $FFMPEG_WIN_ZIP (tag $FFMPEG_WIN_TAG)"
    # --retry 只兜网络抖动；它兜不住校验和不符（那是下一行的事，且不重试）。
    curl -fL --retry 3 --retry-delay 5 --retry-all-errors "$URL" -o "$DEST/ffmpeg.zip"
    verify_sha256 "$DEST/ffmpeg.zip" "$FFMPEG_WIN_SHA256"
    unzip -jo "$DEST/ffmpeg.zip" '*/bin/ffmpeg.exe' -d "$DEST"
    rm "$DEST/ffmpeg.zip"
    ;;
  *)
    echo "unsupported OS: $OS" >&2; exit 1 ;;
esac

chmod +x "$DEST"/ffmpeg* 2>/dev/null || true
"$DEST"/ffmpeg -version | head -1
echo "ffmpeg installed at $DEST — set PPF_FFMPEG=$DEST/ffmpeg or add it to PATH."
