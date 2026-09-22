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
# ── 供应链口径：三条分支全部钉死版本 + 校验和 ─────────────────────────
# SEC-06 (#252) 钉了 Windows，SEC-08 (#363) 补上 macOS 与 Linux。
# 在此之前三条分支都是**滚动地址**（gyan.dev / evermeet getrelease /
# johnvansickle release-*-static）：没有版本号、没有校验和，每次都拉一个
# 「当时最新」的可执行文件下来并执行它。与本仓「action 全 pin 40 位 SHA、
# actionlint 下载都要 sha256sum -c」的口径直接冲突。
#
# 现在的口径，三条分支一致：
#   1. URL 必须**带版本号且不可变**（滚动地址一律不许用）；
#   2. 下载后比对写死的 SHA256，不符即删文件并非零退出（verify_sha256）；
#   3. 写进本仓的每个 SHA256 都是**本地真下载实算核对过**再抄进来的 ——
#      发布方自报的校验和只证明「和发布方说的一致」，钉进本仓才是真正的
#      冻结点（和 pin action SHA 是同一个道理）。
#
# 三条分支的来源不同，原因见各分支注释：
#   Windows / Linux → BtbN/FFmpeg-Builds，同一个不可变 tag、同一个
#                     checksums.sha256、同一个 ffmpeg 版本，LGPL 构建。
#   macOS           → evermeet.cx，因为 **BtbN 不出 macOS 构建**。
#
# 👉 升级版本时：改 tag/版本号/文件名/SHA256，**每条改动的分支都要重跑
#    一次反证**（把 SHA256 改错一位 → 本脚本必须非零退出）。
set -euo pipefail

# ── Windows + Linux：BtbN/FFmpeg-Builds ───────────────────────────────
# `autobuild-*` 是打完就不再变的 tag（**`latest` 是滚动的，不许用**）。
# asset 由 GitHub Releases 托管，对 CI runner 出口 IP 不限流 —— gyan.dev
# 当初正是对 runner 返 503 才暴露出这条 lane 的脆弱（#252）。
# 选 `lgpl` 而非 `gpl`：该构建 `--disable-libx264 --disable-libx265
# --disable-libxvid`，不含 GPL 组件，与 BUILD-08 给 libheif 选 `[core]`
# 摘掉 x265 是同一个取舍。
FFMPEG_BTBN_TAG="autobuild-2026-09-20-13-11"
FFMPEG_BTBN_VER="n9.0.2-3-ga5923073bf"

FFMPEG_WIN_ZIP="ffmpeg-${FFMPEG_BTBN_VER}-win64-lgpl-9.0.zip"
FFMPEG_WIN_SHA256="ec1706ea5c63a73030e485ec6954f0d6a672508c9548a1c5ed07c85c90ee4ef3"

FFMPEG_LINUX_AMD64_TAR="ffmpeg-${FFMPEG_BTBN_VER}-linux64-lgpl-9.0.tar.xz"
FFMPEG_LINUX_AMD64_SHA256="f22b97b959e529204d82c72815d6889bba083da11b145ea1d1ee65ade88302b1"

FFMPEG_LINUX_ARM64_TAR="ffmpeg-${FFMPEG_BTBN_VER}-linuxarm64-lgpl-9.0.tar.xz"
FFMPEG_LINUX_ARM64_SHA256="108386e50fab205abf341f87d532df3edbf4a9b56e69befc6b68401be4567701"

# ── macOS：evermeet.cx ────────────────────────────────────────────────
# BtbN **不出 macOS 构建**（该 release 只有 win64/winarm64/linux64/
# linuxarm64），所以 macOS 只能另找来源。
# evermeet 的 `getrelease/zip` 是滚动地址，**但它同时提供带版本号的固定
# 地址** `https://evermeet.cx/ffmpeg/ffmpeg-<ver>.zip`（由
# `https://evermeet.cx/ffmpeg/info/ffmpeg/release` 这个 JSON 接口给出），
# 钉的就是后者。版本 9.0.2 与上面 BtbN 的 n9.0.2 对齐，非巧合而是刻意选的。
#
# ⚠️ **许可不对称，必须知情**：evermeet 的构建是 **GPL** 的
# （二进制里实测含 `--enable-gpl --enable-libx264 --enable-libx265`），
# 而 Windows/Linux 用的 BtbN 是 LGPL。这里接受这个不对称，理由：
#   - 本仓只把 ffmpeg 当**外部命令执行**（`Command::new(ffmpeg)`），不链接
#     它、不分发它；GPL 的义务附着在分发与链接上，不附着在「运行一个工具」。
#   - **产品从不捆绑 ffmpeg** —— release.yml 与各打包脚本对 ffmpeg 零引用，
#     用户机器上没有 ffmpeg 时由 media-codec::ql_fallback 的
#     video_thumbs_survive_a_machine_without_ffmpeg 守着降级路径。
# 🔴 **重估触发条件**：哪天真要把 ffmpeg 捆进 macOS 安装包（MOB-74 菜单里
#    的方案 A），这个 GPL 选择**必须在发版之前重新评估**，否则就是带着
#    GPL 组件分发。那一刻请回到本注释。
FFMPEG_MAC_VER="9.0.2"
FFMPEG_MAC_SHA256="4acc0be580f9b2788029eb7bd4d645ff87968911b0a62aeeb3940d42d54558d5"

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

# --retry 只兜网络抖动；它兜不住校验和不符（那是 verify_sha256 的事，且不重试）。
fetch() {
  curl -fL --retry 3 --retry-delay 5 --retry-all-errors "$1" -o "$2"
}

# PATH 上已有 ffmpeg 就不折腾 —— 但 CI 必须绕开这条。
# 理由：这条早退意味着「runner 镜像哪天自带了 ffmpeg，CI 就会静默改用那个
# 未经本仓校验的二进制」，钉版本+校验和的努力当场归零（而且没人会发现）。
# 所以 ci-rust.yml 里设 PPF_FFMPEG_FORCE_FETCH=1，CI 永远用钉死的那一个。
if [ -z "${PPF_FFMPEG_FORCE_FETCH:-}" ] && command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg already on PATH ($(command -v ffmpeg)) — nothing to do."
  echo "Set PPF_FFMPEG_FORCE_FETCH=1 to fetch the pinned build anyway."
  exit 0
fi

# 这两个 override **只给测试用**：本脚本要钉三个平台的产物，而任何一台开发机
# 只能原生跑其中一条分支。有了它们才能在一台机器上把三条分支的「下载 + 校验
# + 解包」都验一遍（#363 的反证就是这么做的）。
# 它们不削弱校验：override 只决定去取哪一个产物，取到的东西照样要过
# verify_sha256。最后那步 `ffmpeg -version` 在跨平台取件时必然失败（拿 Linux
# 的 ELF 在 Windows 上跑不动），那是预期的，不代表校验没通过。
OS="${PPF_FFMPEG_OS_OVERRIDE:-$(uname -s)}"
ARCH="${PPF_FFMPEG_ARCH_OVERRIDE:-$(uname -m)}"
case "$OS" in
  Darwin)
    URL="https://evermeet.cx/ffmpeg/ffmpeg-${FFMPEG_MAC_VER}.zip"
    echo "fetching pinned ffmpeg: ffmpeg-${FFMPEG_MAC_VER}.zip (evermeet.cx)"
    fetch "$URL" "$DEST/ffmpeg.zip"
    verify_sha256 "$DEST/ffmpeg.zip" "$FFMPEG_MAC_SHA256"
    # 该 zip 根下就是单个 `ffmpeg`，没有目录前缀。
    unzip -o "$DEST/ffmpeg.zip" -d "$DEST"
    rm "$DEST/ffmpeg.zip"
    ;;
  Linux)
    case "$ARCH" in
      x86_64)  TAR="$FFMPEG_LINUX_AMD64_TAR"; SHA="$FFMPEG_LINUX_AMD64_SHA256" ;;
      aarch64) TAR="$FFMPEG_LINUX_ARM64_TAR"; SHA="$FFMPEG_LINUX_ARM64_SHA256" ;;
      *) echo "unsupported Linux arch: $ARCH" >&2; exit 1 ;;
    esac
    URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/${FFMPEG_BTBN_TAG}/${TAR}"
    echo "fetching pinned ffmpeg: $TAR (tag $FFMPEG_BTBN_TAG)"
    fetch "$URL" "$DEST/ffmpeg.tar.xz"
    verify_sha256 "$DEST/ffmpeg.tar.xz" "$SHA"
    # ⚠️ BtbN 的布局是 `<dir>/bin/ffmpeg`，**不是** johnvansickle 的
    # `<dir>/ffmpeg` —— 所以 strip 2 层且路径含 bin/。换源时最容易漏这条。
    tar -xJf "$DEST/ffmpeg.tar.xz" --strip-components=2 -C "$DEST" --wildcards '*/bin/ffmpeg'
    rm "$DEST/ffmpeg.tar.xz"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/${FFMPEG_BTBN_TAG}/${FFMPEG_WIN_ZIP}"
    echo "fetching pinned ffmpeg: $FFMPEG_WIN_ZIP (tag $FFMPEG_BTBN_TAG)"
    fetch "$URL" "$DEST/ffmpeg.zip"
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
