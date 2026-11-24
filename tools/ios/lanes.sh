#!/usr/bin/env bash

ios_lane_real_udid() {
  # xcodebuild 要 hardwareProperties.udid，不是 devicectl 的 CoreDevice identifier。
  if [ -n "${PPASS_IOS_HARDWARE_UDID:-}" ]; then
    printf '%s\n' "$PPASS_IOS_HARDWARE_UDID"
    return 0
  fi
  local json requested list count
  json="$(mktemp)" || return 1
  if ! xcrun devicectl list devices --quiet --json-output "$json" >/dev/null 2>&1; then
    rm -f "$json"
    return 1
  fi
  requested="${PPASS_IOS_TEST_DEVICE:-}"
  if [ -n "$requested" ]; then
    list="$(jq -r --arg d "$requested" '.result.devices[]? | select(.identifier == $d or .hardwareProperties.udid == $d or .deviceProperties.name == $d) | .hardwareProperties.udid // empty' "$json")"
  else
    list="$(jq -r '.result.devices[]? | select(.hardwareProperties.platform == "iOS" and .connectionProperties.pairingState == "paired" and .connectionProperties.tunnelState != "unavailable") | .hardwareProperties.udid // empty' "$json")"
  fi
  rm -f "$json"
  count="$(printf '%s\n' "$list" | grep -c . || true)"
  # 未指定时只接受唯一一台：没有设备与多台设备必须分开，后者不能回退模拟器装错目标。
  case "$count" in
    1) printf '%s\n' "$list" ;;
    0) return 1 ;;
    *) return 2 ;;
  esac
}

ios_lane_select() {
  local udid rc
  # 物理隔离铁律：普通单测（just ios-test）默认 100% 跑模拟器，绝不因 USB 连着真机自动抢物理 iPhone。
  # 只有显式传 PPASS_IOS_LANE=device（且非 CI、未设 PPASS_IOS_FORCE_SIMULATOR=1）时才走真机。
  if [ "${CI:-}" = true ] || [ "${PPASS_IOS_FORCE_SIMULATOR:-0}" = 1 ]; then
    PPASS_IOS_LANE=simulator
    PPASS_IOS_HARDWARE_UDID=""
  elif [ "${PPASS_IOS_LANE:-}" = device ]; then
    if udid="$(ios_lane_real_udid)" && [ -n "$udid" ]; then
      PPASS_IOS_HARDWARE_UDID="$udid"
    else
      rc=$?
      if [ "$rc" -eq 2 ]; then
        echo "error: 检测到多台已配对 iOS 设备；用 PPASS_IOS_TEST_DEVICE 显式指定，不能装错目标。" >&2
        return 2
      fi
      echo "error: PPASS_IOS_LANE=device 但未检测到可用 iOS 真机。" >&2
      return 1
    fi
  else
    PPASS_IOS_LANE=simulator
    PPASS_IOS_HARDWARE_UDID=""
  fi
  export PPASS_IOS_LANE PPASS_IOS_HARDWARE_UDID
}

ios_lane_is_device() {
  ios_lane_select || return $?
  [ "$PPASS_IOS_LANE" = device ]
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
