#!/usr/bin/env bash
# Bundle macOS binaries with their non-system dylibs → self-contained dir.
# 把 macOS 二进制及其非系统动态库打包成自包含目录（目标机零依赖）。
#
# Usage: tools/bundle-macos.sh <out_dir> <binary>...
# Result: <out_dir>/{binaries, lib/*.dylib}, all load paths rewritten to
# @executable_path/lib/, ad-hoc signed.
set -euo pipefail

OUT="$1"; shift
mkdir -p "$OUT/lib"

deps_of() { otool -L "$1" | awk 'NR>1 {print $1}' | grep -E '^/opt/homebrew|^/usr/local' || true; }

# 1. Recursively collect non-system dylibs.
queue=""
for bin in "$@"; do cp "$bin" "$OUT/"; queue="$queue $OUT/$(basename "$bin")"; done
while [ -n "$queue" ]; do
  item="${queue%% *}"; rest="${queue#* }"
  [ "$rest" = "$queue" ] && queue="" || queue="$rest"
  for dep in $(deps_of "$item"); do
    base=$(basename "$dep")
    if [ ! -f "$OUT/lib/$base" ]; then
      cp "$dep" "$OUT/lib/$base"
      chmod u+w "$OUT/lib/$base"
      queue="$queue $OUT/lib/$base"
    fi
  done
done

# 2. Rewrite load commands: binaries point to @executable_path/lib,
#    dylibs point to @loader_path (they sit side by side).
rewrite() {
  local file="$1" prefix="$2"
  for dep in $(deps_of "$file"); do
    install_name_tool -change "$dep" "$prefix/$(basename "$dep")" "$file" 2>/dev/null
  done
}
for bin in "$@"; do rewrite "$OUT/$(basename "$bin")" "@executable_path/lib"; done
for lib in "$OUT"/lib/*.dylib; do
  install_name_tool -id "@loader_path/$(basename "$lib")" "$lib" 2>/dev/null
  rewrite "$lib" "@loader_path"
done

# 3. Re-sign (mandatory after install_name_tool on arm64).
for f in "$OUT"/lib/*.dylib; do codesign --force -s - "$f" 2>/dev/null; done
for bin in "$@"; do codesign --force -s - "$OUT/$(basename "$bin")" 2>/dev/null; done

# 4. Verify: nothing outside the bundle or /usr/lib & /System.
echo "── residual external deps (must be empty):"
for f in "$OUT"/* "$OUT"/lib/*.dylib; do
  [ -f "$f" ] || continue
  deps_of "$f" | sed "s|^|  $f → |"
done
echo "── bundle: $(du -sh "$OUT" | cut -f1), $(ls "$OUT/lib" | wc -l | tr -d ' ') dylibs"
