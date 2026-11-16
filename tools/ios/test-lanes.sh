#!/usr/bin/env bash

ios_lane_real_udid() {
  if [ -n "${PPASS_IOS_TEST_DEVICE:-}" ]; then
    printf '%s\n' "$PPASS_IOS_TEST_DEVICE"
    return 0
  fi
  xcrun devicectl list devices 2>/dev/null | awk '
    /available \(paired\)|connected/ {
      for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]+(-[0-9A-F]+)+$/) { print $i; exit }
    }
  '
}

ios_lane_is_device() {
  [ "${CI:-}" != true ] || return 1
  [ "${PPASS_IOS_FORCE_SIMULATOR:-0}" != 1 ] || return 1
  [ -n "$(ios_lane_real_udid)" ]
}

ios_lane_host_test_count() {
  grep -Evc '^[[:space:]]*(#|$)' "$1" | tr -d ' '
}

ios_lane_print_plan() {
  local root="$1" manifest="$2" udid
  if ios_lane_is_device; then
    udid="$(ios_lane_real_udid)"
    printf 'EXECUTION=device UDID=%s HOST_TESTS_DEFERRED=%s\n' "$udid" "$(ios_lane_host_test_count "$manifest")"
    grep -Ev '^[[:space:]]*(#|$)' "$manifest" | while IFS= read -r name; do
      printf 'SKIP=PPassTests/%s\n' "$name"
    done
  else
    udid=auto
    printf 'EXECUTION=simulator UDID=%s HOST_TESTS_DEFERRED=0 SKIP=none\n' "$udid"
  fi
}

ios_lane_validate_manifest() {
  local root="$1" manifest="$2" fails=0 file name
  [ -f "$manifest" ] || { echo "missing manifest: $manifest" >&2; return 1; }
  if [ -n "$(grep -Ev '^[[:space:]]*(#|$)' "$manifest" | sed 's/[[:space:]]*$//' | sort | uniq -d)" ]; then
    echo "duplicate manifest entry" >&2
    fails=1
  fi
  while IFS= read -r name; do
    case "$name" in ''|'#'*) continue ;; esac
    case "$name" in *[!A-Za-z0-9_]*)
      echo "invalid test class: $name" >&2
      fails=1
      continue
      ;;
    esac
    if [ ! -f "$root/apps/ios/PPassTests/$name.swift" ]; then
      echo "missing test file for manifest entry: $name" >&2
      fails=1
    fi
  done < <(grep -Ev '^[[:space:]]*(#|$)' "$manifest")
  for file in "$root"/apps/ios/PPassTests/*Tests.swift; do
    name="$(basename "$file" .swift)"
    if grep -q 'RepoPaths\|crates/proto/tests/snapshots\|deletingLastPathComponent().deletingLastPathComponent()' "$file"; then
      if ! grep -qx "$name" "$manifest"; then
        echo "host-dependent test missing from manifest: $name" >&2
        fails=1
      fi
    fi
  done
  return "$fails"
}
