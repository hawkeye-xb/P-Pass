#!/usr/bin/env bash
# macOS：按 tools/codec-deps.env 的固定版本，从源码编译 libde265 + libheif（只编解码）。
#
# 用法：tools/build-codecs-macos.sh <prefix>
# 结果：<prefix>/lib/{libde265,libheif}*.dylib 与 <prefix>/lib/pkgconfig/*.pc。
#       之后 `PKG_CONFIG_PATH=<prefix>/lib/pkgconfig cargo build` 即链接到这里。
#
# 为什么不用 brew：brew 装到的是构建当天的版本，追溯不了；brew 的 libheif 还连带
# x265、libaom、libvmaf、libsharpyuv，打包脚本会把它们一起拷进包里。
#
# 约束：
#   - install name 是 <prefix>/lib 下的绝对路径（不用 @rpath），tools/bundle-macos.sh
#     按绝对路径收集并改写成 @executable_path/lib。
#   - 不让 cmake 搜 /opt/homebrew、/usr/local：本机或 runner 上的 brew 库不许混进来。
#   - 最低系统版本取 tauri.conf.json 的 bundle.macOS.minimumSystemVersion，与外层 App 一致。
#   - <prefix>/.complete 存在且记录的配置一致就直接返回（给 CI 缓存用）。
set -euo pipefail

[ "$#" -eq 1 ] || { echo "usage: $0 <prefix>" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=codec-deps.env
. "$ROOT/tools/codec-deps.env"

mkdir -p "$1"
PREFIX="$(cd "$1" && pwd)"
MIN_OS="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["bundle"]["macOS"]["minimumSystemVersion"])' \
  "$ROOT/apps/desktop/src-tauri/tauri.conf.json")"
STAMP="libheif=$LIBHEIF_VERSION libde265=$LIBDE265_VERSION macos=$MIN_OS script=$(shasum -a 256 "$0" | cut -c1-16)"

if [ -f "$PREFIX/.complete" ] && [ "$(cat "$PREFIX/.complete")" = "$STAMP" ]; then
  echo "codecs 已就绪（$STAMP）：$PREFIX"
  exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/codecs-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
rm -rf "${PREFIX:?}"/{lib,include,share,bin,.complete}

fetch() { # <url> <sha256> <out>
  curl -fsSL --retry 3 --connect-timeout 20 --max-time 300 -o "$3" "$1"
  echo "$2  $3" | shasum -a 256 -c - >/dev/null \
    || { echo "FATAL: $3 的 SHA-256 与 codec-deps.env 不符" >&2; exit 1; }
}
fetch "https://github.com/strukturag/libde265/releases/download/v$LIBDE265_VERSION/libde265-$LIBDE265_VERSION.tar.gz" \
  "$LIBDE265_SHA256" "$WORK/libde265.tar.gz"
fetch "https://github.com/strukturag/libheif/releases/download/v$LIBHEIF_VERSION/libheif-$LIBHEIF_VERSION.tar.gz" \
  "$LIBHEIF_SHA256" "$WORK/libheif.tar.gz"
tar -xzf "$WORK/libde265.tar.gz" -C "$WORK"
tar -xzf "$WORK/libheif.tar.gz" -C "$WORK"

JOBS="$(sysctl -n hw.ncpu)"
COMMON=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
  -DCMAKE_INSTALL_LIBDIR=lib
  -DCMAKE_INSTALL_NAME_DIR="$PREFIX/lib"
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_OS"
  -DCMAKE_PREFIX_PATH="$PREFIX"
  -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local"
  -DCMAKE_FIND_FRAMEWORK=LAST
  -DBUILD_SHARED_LIBS=ON
)

# libde265：只要库本身；dec265 / 编码器 / SDL 都不编。
cmake -S "$WORK/libde265-$LIBDE265_VERSION" -B "$WORK/b-de265" "${COMMON[@]}" \
  -DENABLE_DECODER=OFF -DENABLE_ENCODER=OFF -DENABLE_SDL=OFF \
  -DENABLE_SHERLOCK265=OFF -DENABLE_INTERNAL_DEVELOPMENT_TOOLS=OFF -DWITH_FUZZERS=OFF
cmake --build "$WORK/b-de265" -j "$JOBS"
cmake --install "$WORK/b-de265"

# libheif：只开 libde265 解码，且直接编进库里（不走插件）；其余编解码器全部显式关掉。
OFF=(X265 X264 KVAZAAR UVG266 VVDEC VVENC OpenH264_DECODER DAV1D AOM_DECODER AOM_ENCODER
     SvtEnc RAV1E JPEG_DECODER JPEG_ENCODER OpenJPEG_ENCODER OpenJPEG_DECODER FFMPEG_DECODER
     OPENJPH_ENCODER)
HEIF_ARGS=(-DWITH_LIBDE265=ON -DWITH_LIBDE265_PLUGIN=OFF -DENABLE_PLUGIN_LOADING=OFF)
for k in "${OFF[@]}"; do HEIF_ARGS+=("-DWITH_$k=OFF" "-DWITH_${k}_PLUGIN=OFF"); done
HEIF_ARGS+=(-DWITH_LIBSHARPYUV=OFF -DWITH_HEADER_COMPRESSION=OFF -DWITH_UNCOMPRESSED_CODEC=OFF
            -DWITH_GDK_PIXBUF=OFF -DWITH_EXAMPLES=OFF -DBUILD_TESTING=OFF
            -DBUILD_DOCUMENTATION=OFF -DWITH_FUZZERS=OFF)
# 编解码器清单是 cmake message() 打的，走 stderr。
cmake -S "$WORK/libheif-$LIBHEIF_VERSION" -B "$WORK/b-heif" "${COMMON[@]}" "${HEIF_ARGS[@]}" 2>&1 \
  | tee "$WORK/heif-configure.log"
# 找不到 libde265 时 libheif 不报错，只是编出一个解不了 HEIC 的库——这里直接判红。
grep -E 'libde265 HEVC decoder +: +\+ built-in' "$WORK/heif-configure.log" >/dev/null \
  || { echo "FATAL: libheif 配置里 libde265 解码器不是 built-in" >&2; exit 1; }
cmake --build "$WORK/b-heif" -j "$JOBS"
cmake --install "$WORK/b-heif"

# 编出来的 libheif 必须链接到这里的 libde265，而不是别处的。
heif_dylib="$PREFIX/lib/libheif.1.dylib"
otool -L "$heif_dylib" | grep -F "$PREFIX/lib/libde265" >/dev/null \
  || { echo "FATAL: $heif_dylib 没有链接到 $PREFIX/lib 下的 libde265" >&2; otool -L "$heif_dylib" >&2; exit 1; }

echo "$STAMP" > "$PREFIX/.complete"
echo "codecs 编译完成（$STAMP）：$PREFIX"
otool -L "$heif_dylib"
