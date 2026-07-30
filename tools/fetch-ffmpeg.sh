#!/usr/bin/env bash
# Fetch a static ffmpeg binary into tools/ffmpeg/ for machines without one.
# media-codec discovery order: PPF_FFMPEG env → <exe_dir>/tools/ffmpeg →
# PATH. This script serves dev machines and the future bundling step
# (T-071 release pipeline pins exact versions + checksums there).
#
# Usage: tools/fetch-ffmpeg.sh [dest_dir]   (default: tools/ffmpeg)
set -euo pipefail

DEST="${1:-$(dirname "$0")/ffmpeg}"
mkdir -p "$DEST"

if command -v ffmpeg >/dev/null 2>&1; then
  echo "ffmpeg already on PATH ($(command -v ffmpeg)) — nothing to do."
  echo "Pass a dest dir and delete this check if you want a local copy anyway."
  exit 0
fi

OS="$(uname -s)"
ARCH="$(uname -m)"
case "$OS" in
  Darwin)
    # evermeet.cx serves the latest static macOS build (x86_64; runs on
    # Apple Silicon via Rosetta — fine for a dev fallback).
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
    URL="https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-${JV_ARCH}-static.tar.xz"
    curl -fL "$URL" -o "$DEST/ffmpeg.tar.xz"
    tar -xJf "$DEST/ffmpeg.tar.xz" --strip-components=1 -C "$DEST" --wildcards '*/ffmpeg'
    rm "$DEST/ffmpeg.tar.xz"
    ;;
  MINGW*|MSYS*|CYGWIN*)
    URL="https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
    curl -fL "$URL" -o "$DEST/ffmpeg.zip"
    unzip -jo "$DEST/ffmpeg.zip" '*/bin/ffmpeg.exe' -d "$DEST"
    rm "$DEST/ffmpeg.zip"
    ;;
  *)
    echo "unsupported OS: $OS" >&2; exit 1 ;;
esac

chmod +x "$DEST"/ffmpeg* 2>/dev/null || true
"$DEST"/ffmpeg -version | head -1
echo "ffmpeg installed at $DEST — set PPF_FFMPEG=$DEST/ffmpeg or add it to PATH."
