#!/usr/bin/env bash
# Fetch a static ffmpeg binary into tools/ffmpeg/ for machines without one.
# media-codec discovery order: PPF_FFMPEG env → <exe_dir>/tools/ffmpeg →
# PATH. This script serves dev machines and the Windows CI lane
# (ci-rust.yml `test (windows)`; the Linux lane uses apt instead).
#
# Usage: tools/fetch-ffmpeg.sh [dest_dir]   (default: tools/ffmpeg)
#   PPF_FFMPEG_FORCE_FETCH=1  ignore any ffmpeg already on PATH and fetch the
#                             verified build anyway (CI uses this — see below).
#
# ── 供应链口径 ──────────────────────────────────────────────────────────
# SEC-06 (#252) 之前三条分支都是**无版本、无校验**的滚动地址（gyan.dev /
# evermeet getrelease / johnvansickle release-*-static），每次拉一个「当时
# 最新」的可执行文件下来就执行。SEC-06 / SEC-08 (#363) 把三条都改成「钉死
# 不可变 tag + 本仓写死的 SHA256」。
#
# #700 起 Windows / Linux 改了口径，macOS 不变：
#   Windows / Linux → BtbN 的**固定地址** `releases/download/latest/
#                     ffmpeg-n9.0-latest-*-lgpl-9.0.*`：锁死 9.0 这条
#                     release 分支（只进 bug 修复，不跳大版本），校验用
#                     **同一个 release 里官方的 checksums.sha256**。
#   macOS           → evermeet.cx 带版本号的固定地址 + 本仓写死的 SHA256
#                     （BtbN 不出 macOS 构建；evermeet 的版本地址不会过期）。
#
# 为什么 Windows / Linux 不再钉 autobuild tag（#700）：BtbN 的 autobuild
# tag 只保留约 14 天，旧 tag 会被**删除**。钉死 tag 等于给 CI 埋一个两周
# 一次的定时炸弹——2026-09-20 那个 tag 在 10-05 被删，`test (windows)`
# 当场每次都红在 404 上；换上去的 10-05 tag 预计 10-19 前后同样消失。
#
# 这个口径**放松了什么、没放松什么**（验收人 2026-10-10 拍板接受）：
#   - 仍然 fail-closed：拿不到官方校验和、或文件与之不符，一律删文件 +
#     非零退出，绝不「校验不了就先用着」。能挡住传输损坏、截断、CDN 投毒。
#   - 放松的是「冻结点」：校验和来自发布方而不是本仓，所以挡不住 BtbN 本身
#     被攻破后连同 checksums 一起换包；内容也会随 9.0 分支的修复版更新。
#     这里只在 CI 上把 ffmpeg 当外部工具跑缩略图测试，产品从不捆绑它，
#     接受这个取舍。
#
# 👉 升级大版本时：改 FFMPEG_BTBN_BRANCH（n9.0 → nX.Y）和文件名里的
#    lgpl-X.Y；macOS 那条 evermeet 版本与之保持同一大版本。改完把官方
#    checksum 那一行改错一位跑一次反证 → 本脚本必须非零退出。
set -euo pipefail

# ── Windows + Linux：BtbN/FFmpeg-Builds ───────────────────────────────
# `latest` 这个 release 每天重建，但其中 `ffmpeg-<分支>-latest-*` 的文件名
# **永远存在**——这就是 BtbN 给 CI 用的固定地址（口径见文件头）。
#
# asset 由 GitHub Releases 托管，对 CI runner 出口 IP 不限流 —— gyan.dev
# 当初正是对 runner 返 503 才暴露出这条 lane 的脆弱（#252）。
# 选 `lgpl` 而非 `gpl`：该构建 `--disable-libx264 --disable-libx265
# --disable-libxvid`，不含 GPL 组件，与 BUILD-08 给 libheif 选 `[core]`
# 摘掉 x265 是同一个取舍。
FFMPEG_BTBN_BASE="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest"
FFMPEG_BTBN_BRANCH="n9.0"

FFMPEG_WIN_ZIP="ffmpeg-${FFMPEG_BTBN_BRANCH}-latest-win64-lgpl-9.0.zip"
FFMPEG_LINUX_AMD64_TAR="ffmpeg-${FFMPEG_BTBN_BRANCH}-latest-linux64-lgpl-9.0.tar.xz"
FFMPEG_LINUX_ARM64_TAR="ffmpeg-${FFMPEG_BTBN_BRANCH}-latest-linuxarm64-lgpl-9.0.tar.xz"

# ── macOS：evermeet.cx ────────────────────────────────────────────────
# BtbN **不出 macOS 构建**（该 release 只有 win64/winarm64/linux64/
# linuxarm64），所以 macOS 只能另找来源。
# evermeet 的 `getrelease/zip` 是滚动地址，**但它同时提供带版本号的固定
# 地址** `https://evermeet.cx/ffmpeg/ffmpeg-<ver>.zip`（由
# `https://evermeet.cx/ffmpeg/info/ffmpeg/release` 这个 JSON 接口给出），
# 钉的就是后者。大版本 9.0 与上面 BtbN 的 n9.0 分支对齐，是刻意选的。
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
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

verify_sha256() {
  local file="$1" expected="$2" actual=""
  actual="$(sha256_of "$file")"
  if [ -z "$actual" ]; then
    echo "no sha256 tool (sha256sum/shasum) available —— 拒绝使用未校验的下载" >&2
    rm -f "$file"
    exit 1
  fi
  if [ "$actual" != "$expected" ]; then
    echo "SHA256 MISMATCH —— 下载物与期望的校验和不符，已删除并中止：" >&2
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

# BtbN：下载 asset + 同一个 release 的官方 checksums.sha256，按文件名取期望值
# 再走 verify_sha256（fail-closed）。
# `latest` 每天重建一次：重建窗口里可能拿到「新文件 + 旧 checksums」（或反过来），
# 所以**两样一起重取一次**再判；第二次仍不符才算真不符。只重试这一种情况——
# 拿不到 checksums 或里面没有这个文件名，直接失败。
fetch_btbn() {
  local asset="$1" out="$2" sums="$DEST/checksums.sha256" expected="" attempt
  for attempt in 1 2; do
    fetch "$FFMPEG_BTBN_BASE/$asset" "$out"
    fetch "$FFMPEG_BTBN_BASE/checksums.sha256" "$sums"
    expected="$(awk -v f="$asset" '$2 == f { print $1 }' "$sums")"
    rm -f "$sums"
    if [ -z "$expected" ]; then
      echo "官方 checksums.sha256 里没有 $asset —— 拒绝使用未校验的下载" >&2
      rm -f "$out"
      exit 1
    fi
    if [ "$attempt" = 1 ] && [ "$(sha256_of "$out")" != "$expected" ]; then
      echo "sha256 与官方 checksums 不符，可能撞上 latest 重建窗口，整组重取一次" >&2
      continue
    fi
    break
  done
  verify_sha256 "$out" "$expected"
}

# PATH 上已有 ffmpeg 就不折腾 —— 但 CI 必须绕开这条。
# 理由：这条早退意味着「runner 镜像哪天自带了 ffmpeg，CI 就会静默改用那个
# 未经本仓校验的二进制」，钉版本+校验和的努力当场归零（而且没人会发现）。
# 所以 ci-rust.yml 里设 PPF_FFMPEG_FORCE_FETCH=1，CI 永远用本脚本校验过的那一个。
if [ -z "${PPF_FFMPEG_FORCE_FETCH:-}" ] && command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg already on PATH ($(command -v ffmpeg)) — nothing to do."
  echo "Set PPF_FFMPEG_FORCE_FETCH=1 to fetch the verified build anyway."
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
      x86_64)  TAR="$FFMPEG_LINUX_AMD64_TAR" ;;
      aarch64) TAR="$FFMPEG_LINUX_ARM64_TAR" ;;
      *) echo "unsupported Linux arch: $ARCH" >&2; exit 1 ;;
    esac
    echo "fetching ffmpeg: $TAR (BtbN latest, branch $FFMPEG_BTBN_BRANCH)"
    fetch_btbn "$TAR" "$DEST/ffmpeg.tar.xz"
    # ⚠️ BtbN 的布局是 `<dir>/bin/ffmpeg`，**不是** johnvansickle 的
    # `<dir>/ffmpeg` —— 所以 strip 2 层且路径含 bin/。换源时最容易漏这条。
    tar -xJf "$DEST/ffmpeg.tar.xz" --strip-components=2 -C "$DEST" --wildcards '*/bin/ffmpeg'
    rm "$DEST/ffmpeg.tar.xz"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    echo "fetching ffmpeg: $FFMPEG_WIN_ZIP (BtbN latest, branch $FFMPEG_BTBN_BRANCH)"
    fetch_btbn "$FFMPEG_WIN_ZIP" "$DEST/ffmpeg.zip"
    unzip -jo "$DEST/ffmpeg.zip" '*/bin/ffmpeg.exe' -d "$DEST"
    rm "$DEST/ffmpeg.zip"
    ;;
  *)
    echo "unsupported OS: $OS" >&2; exit 1 ;;
esac

chmod +x "$DEST"/ffmpeg* 2>/dev/null || true
"$DEST"/ffmpeg -version | head -1
echo "ffmpeg installed at $DEST — set PPF_FFMPEG=$DEST/ffmpeg or add it to PATH."
