#!/usr/bin/env bash
# tools/check-codec-libs.sh 的反证：合格样本必须通过，每种变异必须失败。
#
# 用法：
#   tools/test-check-codec-libs.sh                        只测 Windows 判据（造的文本样本，任何系统都能跑）
#   tools/test-check-codec-libs.sh --macos <bundle目录>   再拿一份合格的 macOS 包做变异（要在 macOS 上）
#     <bundle目录> = tools/bundle-macos.sh 的输出（含 lib/libheif*.dylib、lib/libde265*.dylib）。
# 只用 bash 3.2 有的东西。
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$ROOT/tools/check-codec-libs.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fails=0
pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1" >&2; fails=$((fails + 1)); }

# expect <pass|fail> <说明> <命令...>
expect() {
  local want="$1" what="$2" rc; shift 2
  "$@" >"$TMP/out" 2>&1; rc=$?
  if { [ "$want" = pass ] && [ "$rc" -eq 0 ]; } || { [ "$want" = fail ] && [ "$rc" -eq 1 ]; }; then
    pass "$what（rc=$rc）"
  else
    fail "$what：期望 $want，rc=$rc"; sed 's/^/      /' "$TMP/out" >&2
  fi
}

. "$ROOT/tools/codec-deps.env"

# ── Windows（造样本）────────────────────────────────────────────────────
echo "==> windows"
W="$TMP/win"
mk_win() { # <libheif 版本> <libde265 版本> [额外 status 段]
  rm -rf "$W"; mkdir -p "$W/installed/vcpkg"
  cat > "$W/installed/vcpkg/status" <<EOF
Package: libde265
Version: $2
Architecture: x64-windows-static-md
Multi-Arch: same
Abi: 00
Status: install ok installed

Package: libheif
Version: $1
Port-Version: 0
Depends: vcpkg-cmake, vcpkg-cmake-config
Architecture: x64-windows-static-md
Multi-Arch: same
Abi: 00
Status: install ok installed

Package: libheif
Feature: libde265
Depends: libde265
Architecture: x64-windows-static-md
Multi-Arch: same
Status: install ok installed
${3:-}
EOF
  printf 'cargo:rustc-link-search=native=C:\\vcpkg\\installed\\x64-windows-static-md\\lib\r\ncargo:rustc-link-lib=heif\r\ncargo:rustc-link-lib=libde265\r\n' > "$W/output"
  printf 'MZ fake exe heif_get_version 1.23.7\n' > "$W/daemon.exe"
}
win() { "$CHECK" windows --vcpkg-installed "$W/installed" --link-output "$W/output" "$W/daemon.exe"; }

mk_win "$LIBHEIF_MIN" "$LIBDE265_MIN";             expect pass "合格：版本等于下限" win
mk_win 1.23.6 "$LIBDE265_MIN";                      expect fail "libheif 低于下限（1.23.6）" win
mk_win "$LIBHEIF_MIN" 1.1.1;                        expect fail "libde265 低于下限（1.1.1）" win
mk_win "$LIBHEIF_MIN" "$LIBDE265_MIN" "
Package: x265
Version: 4.3
Architecture: x64-windows-static-md
Status: install ok installed
";                                                  expect fail "vcpkg 装了 x265" win
mk_win "$LIBHEIF_MIN" "$LIBDE265_MIN" "
Package: aom
Version: 3.12.1
Architecture: x64-windows-static-md
Status: install ok installed
";                                                  expect fail "vcpkg 装了 aom" win
mk_win "$LIBHEIF_MIN" "$LIBDE265_MIN"; sed -i.bak 's/^Status: install ok installed$/Status: deinstall ok not-installed/' "$W/installed/vcpkg/status"
                                                    expect fail "libheif 只剩卸载记录（读不到版本）" win
mk_win "$LIBHEIF_MIN" "$LIBDE265_MIN"; printf 'cargo:rustc-link-lib=x265-static\r\n' >> "$W/output"
                                                    expect fail "链接指令里有 x265-static" win
mk_win "$LIBHEIF_MIN" "$LIBDE265_MIN"; printf 'cargo:rustc-link-search=native=C:\\x\n' > "$W/output"
                                                    expect fail "链接指令里没有 heif" win
mk_win "$LIBHEIF_MIN" "$LIBDE265_MIN"; rm "$W/output"
                                                    expect fail "链接指令文件不存在" win
mk_win "$LIBHEIF_MIN" "$LIBDE265_MIN"; rm "$W/installed/vcpkg/status"
                                                    expect fail "vcpkg status 不存在" win
mk_win "$LIBHEIF_MIN" "$LIBDE265_MIN"; printf 'x265 HEVC encoder\n' >> "$W/daemon.exe"
                                                    expect fail "exe 里有 x265 插件名" win
mk_win "$LIBHEIF_MIN" "$LIBDE265_MIN"; printf 'AOMedia AV1 decoder\n' >> "$W/daemon.exe"
                                                    expect fail "exe 里有 libaom 解码器名" win
mk_win "$LIBHEIF_MIN" "$LIBDE265_MIN"
expect fail "没给 --link-output" "$CHECK" windows --vcpkg-installed "$W/installed" "$W/daemon.exe"
expect fail "没给 exe" "$CHECK" windows --vcpkg-installed "$W/installed" --link-output "$W/output"
printf 'LIBHEIF_MIN=1.23.8\nLIBDE265_MIN=%s\n' "$LIBDE265_MIN" > "$TMP/raised.env"
expect fail "下限提高到 1.23.8 后同一份样本不再通过" env CODEC_DEPS_ENV="$TMP/raised.env" "$CHECK" windows \
  --vcpkg-installed "$W/installed" --link-output "$W/output" "$W/daemon.exe"

# ── macOS（拿真包变异）──────────────────────────────────────────────────
if [ "${1:-}" = --macos ]; then
  GOOD="${2:?usage: $0 --macos <bundle目录>}"
  echo "==> macos（样本：$GOOD）"
  M="$TMP/mac"
  reset() { rm -rf "$M"; cp -R "$GOOD" "$M"; }
  heif() { ls "$M"/lib/libheif*.dylib | head -1; }
  de265() { ls "$M"/lib/libde265*.dylib | head -1; }
  mac() { "$CHECK" macos "$M"; }

  reset;                                                   expect pass "合格样本" mac
  reset; cp "$(de265)" "$M/lib/libx265.215.dylib";        expect fail "包里多了 libx265" mac
  reset; cp "$(de265)" "$M/lib/libaom.3.dylib";           expect fail "包里多了 libaom" mac
  reset; rm "$(de265)";                                    expect fail "包里没有 libde265" mac
  reset; rm "$(heif)";                                     expect fail "包里没有 libheif" mac
  reset; printf 'AOMedia AV1 decoder\0' >> "$(heif)";     expect fail "libheif 里有 libaom 解码器名" mac
  reset; printf 'x265 HEVC encoder\0' >> "$(heif)";       expect fail "libheif 里有 x265 插件名" mac
  reset; printf '9.9.9\0' >> "$(de265)";                  expect fail "libde265 版本字符串不唯一" mac
  reset; f="$(heif)"; install_name_tool -change "$(otool -L "$f" | awk 'NR>2 && /libde265/ {print $1; exit}')" \
    /opt/homebrew/opt/libde265/lib/libde265.0.dylib "$f" 2>/dev/null
                                                           expect fail "libheif 依赖包外的 libde265" mac
  reset; f="$(heif)"; vtool -set-build-version macos 15.0 26.0 -replace -output "$f.new" "$f" 2>/dev/null && mv "$f.new" "$f"
                                                           expect fail "libheif 的最低系统版本 15.0 高于 App" mac
  printf 'LIBHEIF_MIN=%s\nLIBDE265_MIN=1.1.4\n' "$LIBHEIF_MIN" > "$TMP/raised-de.env"
  reset; expect fail "libde265 下限提高到 1.1.4 后不再通过" env CODEC_DEPS_ENV="$TMP/raised-de.env" "$CHECK" macos "$M"
  reset; expect fail "libheif 下限提高到 1.23.8 后不再通过" env CODEC_DEPS_ENV="$TMP/raised.env" "$CHECK" macos "$M"
fi

if [ "$fails" -gt 0 ]; then echo "FAIL: $fails 项反证不符合预期" >&2; exit 1; fi
echo "OK: 反证全部符合预期"
