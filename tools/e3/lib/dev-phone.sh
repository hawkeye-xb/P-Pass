# just dev android|ios（#1375）：增量编译 → 取设备锁（被占就拒绝）→ 覆盖安装（不卸载）→ 打开 App。
# 由 tools/e3/dev source；编译走 tools/heavy-lock，Rust 产物走共享 CARGO_TARGET_DIR（见 dev-cache.sh）。
# 设备按在线探测选：只有一台就用它；多台时用 E3_ANDROID_SERIAL / PPASS_DEVICE 指定。序列号不进仓库。
# shellcheck shell=bash

DEV_PKG=com.hawkeyexb.ppass

# —— Android ——

# 选手机：E3_ANDROID_SERIAL 优先；否则 adb 里唯一一台 device。打印序列号。
dev_android_pick() {
  if [ -n "${E3_ANDROID_SERIAL:-}" ]; then
    printf '%s' "$E3_ANDROID_SERIAL"
    return 0
  fi
  local list n
  list="$(adb devices 2>/dev/null | awk 'NR > 1 && $2 == "device" {print $1}')"
  n="$(printf '%s' "$list" | grep -c . || true)"
  case "$n" in
    1) printf '%s' "$list" ;;
    0) log "adb 看不到在线手机（just doctor 列出在线设备）"; return 1 ;;
    *) log "在线安卓手机不止一台：用 E3_ANDROID_SERIAL=<序列号> 指定"; printf '%s\n' "$list" | sed 's/^/  /' >&2; return 1 ;;
  esac
}

dev_android_apk() { echo "$REPO_ROOT/apps/android/app/build/outputs/apk/debug/app-debug.apk"; }

# 增量编 debug 包：gradle 整个跑在重编译锁里（libtransport.so 由 gradle 任务编进本目录的 build/，不会被别的目录覆盖）。
dev_android_build() {
  (
    set -e
    # 没有 local.properties 也没设 ANDROID_HOME 时，用 Android Studio 在 macOS 上的默认 SDK 位置
    if [ -z "${ANDROID_HOME:-}" ] && [ ! -f "$REPO_ROOT/apps/android/local.properties" ] && [ -d "$HOME/Library/Android/sdk" ]; then
      export ANDROID_HOME="$HOME/Library/Android/sdk"
    fi
    # shellcheck source=../../java-home.sh
    source "$REPO_ROOT/tools/java-home.sh"
    cd "$REPO_ROOT/apps/android"
    "$REPO_ROOT/tools/heavy-lock" ./gradlew -q --build-cache :app:assembleDebug
  )
}

# dev_android_install <apk> <fresh 0|1> [页面]：已在设备锁里调用。
dev_android_install() {
  local apk="$1" fresh="$2" page="${3:-}"
  if [ "$fresh" = 1 ]; then
    log "卸载旧包（--fresh）"
    A uninstall "$DEV_PKG" >/dev/null 2>&1 || true
  fi
  log "覆盖安装 $(basename "$apk")"
  A install -r -d "$apk" >/dev/null || return 1
  [ -n "$page" ] && log "安卓还没有深链：先只启动 App，页面「${page}」要手动点过去"
  A shell monkey -p "$DEV_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || return 1
}

# —— iOS ——

# 选 iPhone：PPASS_DEVICE 优先；否则 devicectl 里唯一一台已配对的 iOS 设备。打印标识。
dev_ios_pick() {
  if [ -n "${PPASS_DEVICE:-}" ]; then
    printf '%s' "$PPASS_DEVICE"
    return 0
  fi
  local js list n
  js="$(mktemp)"
  xcrun devicectl list devices --quiet --json-output "$js" >/dev/null 2>&1 || { rm -f "$js"; log "devicectl 列不出设备"; return 1; }
  list="$(python3 -I -c '
import json, sys
for d in json.load(open(sys.argv[1]))["result"]["devices"]:
    if d["hardwareProperties"].get("platform") == "iOS" and d["connectionProperties"].get("pairingState") == "paired" \
            and d["connectionProperties"].get("tunnelState") != "unavailable":
        print(d["identifier"])' "$js")"
  rm -f "$js"
  n="$(printf '%s' "$list" | grep -c . || true)"
  case "$n" in
    1) printf '%s' "$list" ;;
    0) log "devicectl 看不到已配对的 iPhone（just doctor 列出在线设备）"; return 1 ;;
    *) log "已配对的 iPhone 不止一台：用 PPASS_DEVICE=<标识> 指定"; printf '%s\n' "$list" | sed 's/^/  /' >&2; return 1 ;;
  esac
}

# dev_ios_build <输出目录>：在重编译锁里编传输 XCFramework 与 Debug 包，并把 PPass.app 拷到输出目录。
# DerivedData 在共享位置（PPASS_IOS_DERIVED_DATA），别的目录随后再编会覆盖它，所以拷出来再装。
dev_ios_build() {
  local out="$1" derived="${PPASS_IOS_DERIVED_DATA:-$REPO_ROOT/apps/ios/build/derived-device}"
  "$REPO_ROOT/tools/heavy-lock" /bin/bash -c '
    set -e
    root="$1" derived="$2" out="$3"
    ios="$root/apps/ios"
    "$root/tools/build-ios-transport-xcframework.sh" "$ios/TransportFFITests/Generated" >&2
    (cd "$ios" && xcodegen generate --quiet)
    xcodebuild build -project "$ios/PPass.xcodeproj" -scheme PPass -configuration Debug \
      -destination "generic/platform=iOS" -allowProvisioningUpdates -derivedDataPath "$derived" -quiet >&2
    rm -rf "$out/PPass.app"
    mkdir -p "$out"
    ditto "$derived/Build/Products/Debug-iphoneos/PPass.app" "$out/PPass.app"
  ' _ "$REPO_ROOT" "$derived" "$out"
}

# dev_ios_install <设备> <app> <fresh 0|1> [页面]：已在设备锁里调用。页面 = PPASS_ROUTE（只 DEBUG 包读）。
dev_ios_install() {
  local dev="$1" app="$2" fresh="$3" page="${4:-}" envs='{}'
  if [ "$fresh" = 1 ]; then
    log "卸载旧包（--fresh）"
    xcrun devicectl device uninstall app --device "$dev" "$DEV_PKG" >/dev/null 2>&1 || true
  fi
  log "覆盖安装 PPass.app"
  xcrun devicectl device install app --device "$dev" "$app" >/dev/null || return 1
  [ -n "$page" ] && envs="{\"PPASS_ROUTE\":\"$page\"}"
  xcrun devicectl device process launch --device "$dev" --terminate-existing \
    --environment-variables "$envs" "$DEV_PKG" >/dev/null || return 1
}
