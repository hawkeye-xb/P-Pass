#!/usr/bin/env bash
# 打包后检查桌面包里的 C 编解码库：版本不低于 tools/codec-deps.env 的下限，且不含禁用的库。
# 任何一项读不到、对不上都判失败（找不到证据 = 失败）。
#
# 用法：
#   tools/check-codec-libs.sh macos <目录或 .app>...
#     在给定目录里找全部 Mach-O：
#       - 必须有 libheif*.dylib 与 libde265*.dylib；
#         libheif 版本取 LC_ID_DYLIB 的 current version，并要求库里也有同一版本字符串；
#         libde265 的 current version 是 ABI 号（0.2.x），版本取库里唯一的 x.y.z 字符串
#         （de265_get_version() 返回的那个）。
#       - 文件名与依赖名里不许出现禁用库；依赖只许是包内相对路径或 /usr/lib、/System；
#       - 二进制里不许有 x265 / libaom 编进来时才有的字符串；
#       - 每个 dylib 的最低系统版本不高于 tauri.conf.json 的 minimumSystemVersion。
#   tools/check-codec-libs.sh windows --vcpkg-installed <dir> [--link-output <file>]... <exe>...
#     Windows 是静态链接，exe 里没有可靠的版本号，改看链接进去的东西从哪来：
#       - <dir>/vcpkg/status（vcpkg 安装库）：libheif、libde265 的版本不低于下限，且没装禁用库；
#       - libheif-sys 构建脚本输出的 cargo:rustc-link-lib 行：不许链接禁用库，且确实链接了 heif；
#       - exe 里不许有 x265 / libaom 的字符串。
#
# 环境变量 CODEC_DEPS_ENV 可指向另一份版本文件（自测用）。
# 只用 bash 3.2 有的东西（macOS 自带 bash）。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=codec-deps.env
. "${CODEC_DEPS_ENV:-$ROOT/tools/codec-deps.env}"
: "${LIBHEIF_MIN:?codec-deps.env 缺 LIBHEIF_MIN}" "${LIBDE265_MIN:?codec-deps.env 缺 LIBDE265_MIN}"

# 我们只解 HEIC：只要 libheif + libde265。其余编码器与解码器都不许进包。
FORBIDDEN='x265|x264|aom|dav1d|rav1e|svtav1|kvazaar|openh264|vmaf|sharpyuv|openjp|vvdec|vvenc|uvg266'
# x265 / libaom 被编进来时才会出现的字符串（libheif 的插件名，以及两个库自己的日志前缀）。
# 不用裸 "dav1d"：干净的 libheif 里也有这个词（解码器名表）。
MARKERS='x265 HEVC encoder|x265 \[(info|warning|error)\]|AOMedia AV1|AOMedia Project'

fails=0
bad() { echo "  ❌ $*" >&2; fails=$((fails + 1)); }
ok() { echo "  ✅ $*"; }

# ver_ge A B：A >= B（逐段数字比较，缺的段当 0）。
ver_ge() {
  local a="$1" b="$2" i x y
  local IFS=.
  # shellcheck disable=SC2206
  local A=($a) B=($b)
  for i in 0 1 2 3; do
    x="${A[$i]:-0}"; y="${B[$i]:-0}"
    case "$x$y" in *[!0-9]*) return 1 ;; esac
    [ "$x" -gt "$y" ] && return 0
    [ "$x" -lt "$y" ] && return 1
  done
  return 0
}

check_floor() { # <名字> <实际版本> <下限> <出处>
  if [ -z "$2" ]; then
    bad "$1：读不到版本（$4）"
  elif ver_ge "$2" "$3"; then
    ok "$1 $2 ≥ $3（$4）"
  else
    bad "$1 $2 低于下限 $3（$4）"
  fi
}

# 文件里所有可打印字符串（逐字节切分，不只看 Mach-O 的段——macOS 的 strings 会漏掉段外数据）。
# 接它的 grep 不许用 -q：提前退出会让上游收到 SIGPIPE，pipefail 下整条管道判失败。
raw_strings() { LC_ALL=C tr -c '[:print:]' '\n' < "$1" | grep -v '^$'; }

check_markers() { # <文件>
  local hit
  hit="$(LC_ALL=C grep -a -o -E "$MARKERS" "$1" 2>/dev/null | sort -u | head -3 | tr '\n' ';')"
  [ -z "$hit" ] || bad "$1 里有禁用库的字符串：$hit"
}

# ── macOS ────────────────────────────────────────────────────────────────
macos() {
  [ "$#" -ge 1 ] || { echo "usage: $0 macos <dir>..." >&2; exit 2; }
  local min_os machos f deps d base heif=0 de265=0 v vs minos
  min_os="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["bundle"]["macOS"]["minimumSystemVersion"])' \
    "$ROOT/apps/desktop/src-tauri/tauri.conf.json")"
  machos="$(mktemp)"
  find "$@" -type f | while IFS= read -r f; do
    file -b "$f" | grep 'Mach-O' >/dev/null && echo "$f"
  done > "$machos"
  [ -s "$machos" ] || { bad "$* 里没有 Mach-O 文件"; rm -f "$machos"; return; }
  echo "==> macOS：$(wc -l < "$machos" | tr -d ' ') 个 Mach-O（下限 libheif ≥ $LIBHEIF_MIN、libde265 ≥ $LIBDE265_MIN、minos ≤ $min_os）"

  while IFS= read -r f; do
    base="$(basename "$f")"
    echo "$base" | grep -i -q -E "$FORBIDDEN" && bad "包里有禁用库：$f"
    # dylib 的 otool -L 第一条是它自己的 install name（LC_ID_DYLIB），不算依赖。
    deps="$(otool -L "$f" 2>/dev/null | awk -v id="$(otool -D "$f" 2>/dev/null | awk 'NR==2')" 'NR>1 && $1!=id {print $1}')"
    for d in $deps; do
      basename "$d" | grep -i -q -E "$FORBIDDEN" && bad "$base 依赖禁用库 $d"
      case "$d" in
        @*|/usr/lib/*|/System/*) ;;
        *) bad "$base 依赖包外的库 $d" ;;
      esac
    done
    check_markers "$f"
    case "$base" in
      *.dylib)
        minos="$(otool -l "$f" | awk '/LC_BUILD_VERSION/{b=1} b&&/minos/{print $2; exit}')"
        if [ -z "$minos" ]; then
          bad "$base：读不到 LC_BUILD_VERSION minos"
        elif ! ver_ge "$min_os" "$minos"; then
          bad "$base 的最低系统版本 $minos 高于 App 的 $min_os"
        fi ;;
    esac
    case "$base" in
      libheif*.dylib)
        heif=$((heif + 1))
        v="$(otool -l "$f" | awk '/cmd LC_ID_DYLIB/{b=1} b&&/current version/{print $3; exit}')"
        if [ -n "$v" ] && ! raw_strings "$f" | grep -x -F "$v" >/dev/null; then
          bad "$base：LC_ID_DYLIB 版本 $v 在库里找不到对应的版本字符串"
        fi
        check_floor libheif "$v" "$LIBHEIF_MIN" "$f" ;;
      libde265*.dylib)
        de265=$((de265 + 1))
        vs="$(raw_strings "$f" | grep -E -x '[0-9]+\.[0-9]+\.[0-9]+' | sort -u)"
        if [ "$(printf '%s\n' "$vs" | grep -c .)" -ne 1 ]; then
          bad "$base：版本字符串不唯一或没有（找到：$(echo "$vs" | tr '\n' ' ')）"
        else
          check_floor libde265 "$vs" "$LIBDE265_MIN" "$f"
        fi ;;
    esac
  done < "$machos"
  rm -f "$machos"
  [ "$heif" -gt 0 ] || bad "包里没有 libheif*.dylib"
  [ "$de265" -gt 0 ] || bad "包里没有 libde265*.dylib"
}

# ── Windows ──────────────────────────────────────────────────────────────
windows() {
  local installed="" outputs="" exes="" st name ver f
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --vcpkg-installed) installed="$2"; shift 2 ;;
      --link-output) outputs="$outputs
$2"; shift 2 ;;
      *) exes="$exes
$1"; shift ;;
    esac
  done
  [ -n "$installed" ] || { echo "usage: $0 windows --vcpkg-installed <dir> [--link-output <file>]... <exe>..." >&2; exit 2; }
  st="$installed/vcpkg/status"
  echo "==> Windows（下限 libheif ≥ $LIBHEIF_MIN、libde265 ≥ $LIBDE265_MIN）"
  if [ ! -s "$st" ]; then
    bad "vcpkg 安装库 $st 不存在或为空"
  else
    # status 是 Debian control 格式；每个包一段，Feature: 行属于特性段，跳过。
    # 输出「包名 版本」，只取 Status 为 install ok installed 的主段。
    local pkgs
    pkgs="$(tr -d '\r' < "$st" | awk '
      function flush() { if (p != "" && !feat && inst) print p, v; p=""; v=""; feat=0; inst=0 }
      /^$/ { flush(); next }
      /^Package: / { p=$2 }
      /^Version: / { v=$2 }
      /^Feature: / { feat=1 }
      /^Status: install ok installed/ { inst=1 }
      END { flush() }')"
    echo "$pkgs" | sed 's/^/     /'
    for name in libheif libde265; do
      ver="$(echo "$pkgs" | awk -v n="$name" '$1==n {print $2; exit}')"
      if [ "$name" = libheif ]; then check_floor "$name" "$ver" "$LIBHEIF_MIN" "$st"
      else check_floor "$name" "$ver" "$LIBDE265_MIN" "$st"; fi
    done
    for name in $(echo "$pkgs" | awk '{print $1}' | grep -i -E "$FORBIDDEN"); do
      bad "vcpkg 装了禁用库：$name"
    done
  fi
  local libs n=0
  [ -n "$(echo "$outputs" | tr -d '[:space:]')" ] || bad "没给 --link-output（libheif-sys 构建脚本输出）"
  for f in $outputs; do
    if [ ! -s "$f" ]; then bad "链接指令文件 $f 不存在或为空"; continue; fi
    libs="$(tr -d '\r' < "$f" | sed -n 's/^cargo:rustc-link-lib=//p')"
    if echo "$libs" | grep -q -i heif; then ok "$f 链接了：$(echo "$libs" | tr '\n' ' ')"
    else bad "$f 里没有链接 heif 的指令"; fi
    for name in $(echo "$libs" | grep -i -E "$FORBIDDEN"); do
      bad "$f 链接了禁用库：$name"
    done
  done
  for f in $exes; do
    n=$((n + 1))
    if [ -f "$f" ]; then check_markers "$f"; else bad "$f 不存在"; fi
  done
  [ "$n" -gt 0 ] || bad "没给要检查的 exe"
}

mode="${1:-}"; shift || true
case "$mode" in
  macos) macos "$@" ;;
  windows) windows "$@" ;;
  *) echo "usage: $0 macos <dir>... | windows --vcpkg-installed <dir> [--link-output <file>]... <exe>..." >&2; exit 2 ;;
esac

if [ "$fails" -gt 0 ]; then
  echo "FAIL: 编解码库检查有 $fails 项不通过" >&2
  exit 1
fi
echo "OK: 编解码库检查通过"
