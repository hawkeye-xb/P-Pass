#!/usr/bin/env bash
# Regression test for REL-03: every version target must be checked before bumping.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/p-pass-bump-version.XXXXXX")"
POSITIVE_SANDBOX=""

cleanup() {
  for worktree in "$SANDBOX" "$POSITIVE_SANDBOX"; do
    [ -n "$worktree" ] || continue
    git -C "$ROOT" worktree remove --force "$worktree" >/dev/null 2>&1 || true
    rm -rf "$worktree"
  done
}
trap cleanup EXIT

git -C "$ROOT" worktree add --detach "$SANDBOX" HEAD >/dev/null
# Exercise the script under test from the caller's worktree while keeping every
# version-file mutation isolated in a disposable worktree.
cp "$ROOT/tools/bump-version.sh" "$SANDBOX/tools/bump-version.sh"
chmod +x "$SANDBOX/tools/bump-version.sh"

python3 - "$SANDBOX/apps/desktop/src-tauri/Cargo.toml" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
updated, count = re.subn(
    r'(?m)^version = "[^"]+"$',
    'version = "0.0.1"',
    text,
    count=1,
)
assert count == 1, "desktop Cargo.toml package version not found"
path.write_text(updated)
PY

if output="$("$SANDBOX/tools/bump-version.sh" 99.0.0-rel-03 2>&1)"; then
  printf '%s\n' "expected bump-version.sh to reject a drifted desktop Cargo.toml version" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

case "$output" in
  *"apps/desktop/src-tauri/Cargo.toml"*"version drift"*) ;;
  *)
    printf '%s\n' "expected desktop Cargo.toml drift diagnostic, got:" >&2
    printf '%s\n' "$output" >&2
    exit 1
    ;;
esac

printf '%s\n' "PASS: drifted desktop Cargo.toml is rejected before bumping"

POSITIVE_SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/p-pass-bump-version-positive.XXXXXX")"
git -C "$ROOT" worktree add --detach "$POSITIVE_SANDBOX" HEAD >/dev/null
git -C "$ROOT" diff -- tools/bump-version.sh >"$POSITIVE_SANDBOX/.bump-version.patch"
if [ -s "$POSITIVE_SANDBOX/.bump-version.patch" ]; then
  git -C "$POSITIVE_SANDBOX" apply .bump-version.patch
fi
rm "$POSITIVE_SANDBOX/.bump-version.patch"

NEW="99.0.0-rel-03"
if ! output="$("$POSITIVE_SANDBOX/tools/bump-version.sh" "$NEW" 2>&1)"; then
  printf '%s\n' "expected bump-version.sh to synchronize every version target, got:" >&2
  printf '%s\n' "$output" >&2
  exit 1
fi

python3 - "$POSITIVE_SANDBOX" "$NEW" <<'PY'
from pathlib import Path
import re
import subprocess
import sys

root = Path(sys.argv[1])
version = sys.argv[2]

def one(pattern, path):
    match = re.search(pattern, path.read_text(), re.M)
    assert match, f"version not found in {path.relative_to(root)}"
    return match.group(1)

assert one(r'^version = "([^"]+)"$', root / 'Cargo.toml') == version
assert one(r'\?: "([^"]+)"', root / 'apps/android/app/build.gradle.kts') == version
assert one(r'"version": "([^"]+)"', root / 'apps/desktop/src-tauri/tauri.conf.json') == version
assert one(r'"version": "([^"]+)"', root / 'apps/desktop/package.json') == version
assert one(r'^version = "([^"]+)"$', root / 'apps/desktop/src-tauri/Cargo.toml') == version
assert one(
    r'name = "p-pass-desktop"\nversion = "([^"]+)"',
    root / 'apps/desktop/src-tauri/Cargo.lock',
) == version

changed = set(
    subprocess.check_output(['git', 'diff', '--name-only'], cwd=root, text=True).splitlines()
)
expected = {
    'Cargo.toml',
    'Cargo.lock',
    'apps/android/app/build.gradle.kts',
    'apps/desktop/src-tauri/tauri.conf.json',
    'apps/desktop/package.json',
    'apps/desktop/src-tauri/Cargo.toml',
    'apps/desktop/src-tauri/Cargo.lock',
    'release/versions.json',
    'tools/bump-version.sh',
}
unexpected = changed - expected
assert not unexpected, f"unexpected changed files: {sorted(unexpected)}"

for line in subprocess.check_output(
    [
        'git', 'diff', '--unified=0', '--',
        'Cargo.toml', 'Cargo.lock', 'apps/android/app/build.gradle.kts',
        'apps/desktop/src-tauri/tauri.conf.json', 'apps/desktop/package.json',
        'apps/desktop/src-tauri/Cargo.toml', 'apps/desktop/src-tauri/Cargo.lock',
    ],
    cwd=root,
    text=True,
).splitlines():
    if not line.startswith(('+', '-')) or line.startswith(('+++', '---')):
        continue
    value = line[1:]
    assert re.fullmatch(
        r'(?:\s*version = "[^"]+"|\s*versionCode = \d+|\s*\?: "[^"]+"|\s*"version": "[^"]+",?)',
        value,
    ), f"non-version diff line: {line}"
PY

printf '%s\n' "PASS: all version targets and p-pass-desktop lock entry synchronize"

# 默认（both）不碰 iOS 线（#348）：versions.json.ios 与 Base.xcconfig 都保持原样。
git -C "$POSITIVE_SANDBOX" diff --quiet -- apps/ios/Config/Base.xcconfig \
  || { echo "FAIL: both 改了 apps/ios/Config/Base.xcconfig" >&2; exit 1; }
[ "$(jq -r .ios "$POSITIVE_SANDBOX/release/versions.json")" = "$(git -C "$ROOT" show HEAD:release/versions.json | jq -r .ios)" ] \
  || { echo "FAIL: both 改了 versions.json.ios" >&2; exit 1; }
printf '%s\n' "PASS: --platform both leaves the iOS line untouched"

# ── iOS 线（#348）：--platform ios 只动 versions.json.ios + Base.xcconfig 的回退值 ──
IOS_SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/p-pass-bump-version-ios.XXXXXX")"
git -C "$ROOT" worktree add --detach "$IOS_SANDBOX" HEAD >/dev/null
cp "$ROOT/tools/bump-version.sh" "$IOS_SANDBOX/tools/bump-version.sh"
trap 'for w in "$SANDBOX" "$POSITIVE_SANDBOX" "$IOS_SANDBOX"; do git -C "$ROOT" worktree remove --force "$w" >/dev/null 2>&1 || true; rm -rf "$w"; done' EXIT
if ! output="$("$IOS_SANDBOX/tools/bump-version.sh" --platform ios 99.0.0-ios 2>&1)"; then
  printf '%s\n' "expected --platform ios to succeed, got:" >&2; printf '%s\n' "$output" >&2; exit 1
fi
changed="$(git -C "$IOS_SANDBOX" diff --name-only | grep -v "^tools/bump-version.sh$" | sort | tr '\n' ' ')"
[ "$changed" = "apps/ios/Config/Base.xcconfig release/versions.json " ] \
  || { echo "FAIL: --platform ios 改动面不对：$changed" >&2; exit 1; }
v="$(jq -c . "$IOS_SANDBOX/release/versions.json")"
base="$(git -C "$ROOT" show HEAD:release/versions.json | jq -c '.ios = "99.0.0-ios"')"
[ "$v" = "$base" ] || { echo "FAIL: versions.json 除 ios 外有变化：$v vs $base" >&2; exit 1; }
grep -q '^PPASS_FALLBACK_VERSION = 99.0.0-ios$' "$IOS_SANDBOX/apps/ios/Config/Base.xcconfig" \
  || { echo "FAIL: Base.xcconfig 回退版本没跟上" >&2; exit 1; }
printf '%s\n' "PASS: --platform ios bumps only versions.json.ios + Base.xcconfig fallback"
if "$IOS_SANDBOX/tools/bump-version.sh" --platform ios 0.0.1 >/dev/null 2>&1; then
  echo "FAIL: --platform ios 接受了低于当前的版本" >&2; exit 1
fi
printf '%s\n' "PASS: --platform ios rejects a non-increasing version"
