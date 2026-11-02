# macOS 安装槽：取 release 包、覆盖安装、装回原版本（供 mac/upgrade 场景与 tools/e3/restore 用）。
# 依赖 common.sh、mac.sh。调用方必须已持 mac 设备锁（tools/e3/lock mac）。
#
# 测试机上只有一个安装槽（docs/decisions/2026-11-02-one-install-per-test-device.md）：覆盖安装只换
# ~/Applications/P-Pass.app，LaunchAgent 与数据目录保留；身份与配对在钥匙串里，不随安装变化。
# shellcheck shell=bash

MAC_SHELL_EXE="$MAC_APP/Contents/MacOS/p-pass-desktop"
MAC_TEAM="${E3_MAC_TEAM:-}"

mac_app_version() { defaults read "${1:-$MAC_APP}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null; }
mac_shell_running() { pgrep -f "^$MAC_SHELL_EXE( |$)" >/dev/null; }

# mac_quit_shell：退出窗口程序（否则替换 .app 时它会被内核按签名失效杀掉，或单实例守卫挡住新壳）
mac_quit_shell() {
  local i
  mac_shell_running || return 0
  osascript -e 'tell application id "com.hawkeyexb.ppass.desktop" to quit' >/dev/null 2>&1
  for i in $(seq 1 30); do mac_shell_running || return 0; sleep 0.5; done
  pkill -f "^$MAC_SHELL_EXE( |$)"
  sleep 1
}

# mac_fetch_release <tag>：下载并校验 release 的 macOS .app 包，打印解出的 .app 路径（缓存在 $E3_STATE/releases/<tag>）
mac_fetch_release() {
  local tag="$1" dir tgz
  dir="$E3_STATE/releases/$tag"
  if [ ! -d "$dir/app/P-Pass.app" ]; then
    rm -rf "$dir"
    mkdir -p "$dir/app"
    gh release download "$tag" -R "${E3_GH_REPO:-hawkeye-xb/P-Pass}" -D "$dir" \
      -p '*_macos-arm64.app.tar.gz' -p 'SHA256SUMS-macos-arm64' >&2 || { log "下载 $tag 失败"; return 1; }
    tgz=$(ls "$dir"/*_macos-arm64.app.tar.gz | head -1)
    (cd "$dir" && grep " $(basename "$tgz")\$" SHA256SUMS-macos-arm64 | shasum -a 256 -c - >&2) ||
      { log "$tag 的 SHA256 对不上"; rm -rf "$dir"; return 1; }
    tar -xzf "$tgz" -C "$dir/app" || return 1
  fi
  [ -d "$dir/app/P-Pass.app" ] || { log "$tag 包里没有 P-Pass.app"; return 1; }
  echo "$dir/app/P-Pass.app"
}

# mac_verify_sig <app>：签名完整、团队一致（与当前已装的同一团队）
mac_verify_sig() {
  local team
  codesign --verify --deep --strict "$1" 2>&1 || return 1
  team=$(codesign -dvv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p')
  [ -n "$team" ] && [ "$team" != "not set" ] || { log "没有团队签名：$1"; return 1; }
  if [ -n "$MAC_TEAM" ] && [ "$team" != "$MAC_TEAM" ]; then log "团队不一致：$team ≠ ${MAC_TEAM}"; return 1; fi
  return 0
}

# mac_install_app <源 .app>：退出外壳 → 停服务 → 整个替换 ~/Applications/P-Pass.app → 起服务 → 等就绪。
# 原来在跑的外壳装完后重新打开。返回 0 = 服务就绪。
mac_install_app() {
  local src="$1" had_shell=0 mark old
  [ -d "$src" ] || { log "没有要装的包：$src"; return 1; }
  mac_shell_running && had_shell=1
  mac_quit_shell
  svc_stop
  mark=$(log_mark)
  old="$E3_STATE/replaced-$$.app"
  rm -rf "$old"
  [ -d "$MAC_APP" ] && mv "$MAC_APP" "$old"
  mkdir -p "$(dirname "$MAC_APP")"
  if ! ditto "$src" "$MAC_APP"; then
    log "复制失败，放回原来的包"
    rm -rf "$MAC_APP"
    mv "$old" "$MAC_APP"
    svc_start
    return 1
  fi
  rm -rf "$old"
  svc_start
  mac_wait_ready "$mark" || return 1
  [ "$had_shell" = 1 ] && open "$MAC_APP"
  return 0
}

# mac_wait_ready <打点> [秒]：服务进程在、日志里出现打点后的「启动就绪」
mac_wait_ready() {
  local i
  for i in $(seq 1 "${2:-90}"); do
    [ -n "$(svc_pid)" ] && log_since "$1" | grep -q '启动就绪$' && return 0
    sleep 1
  done
  log "等 ${2:-90}s 服务没就绪"
  return 1
}

# —— 装回原状 ——
# mac_snapshot：记下当前装的版本，并整包留一份（装回时优先用它：装的可能是不在 release 上的开发构建）
mac_snapshot() {
  local s="$E3_STATE/mac-snapshot"
  rm -rf "$s"
  mkdir -p "$s"
  mac_app_version >"$s/version.txt"
  ditto "$MAC_APP" "$s/P-Pass.app"
  echo "$s"
}
# mac_restore_snapshot：装回 mac_snapshot 留的那份，并核对版本
mac_restore_snapshot() {
  local s="$E3_STATE/mac-snapshot" want
  [ -d "$s/P-Pass.app" ] || { log "没有可装回的快照"; return 1; }
  want=$(cat "$s/version.txt")
  mac_install_app "$s/P-Pass.app" || return 1
  [ "$(mac_app_version)" = "$want" ] && [ "$(svc_version | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')" = "$want" ] ||
    { log "装回后版本不是 ${want}"; return 1; }
  log "已装回 ${want}"
}
# mac_restore_tag <tag>：从 GitHub Release 装指定 tag，核对签名与版本
mac_restore_tag() {
  local tag="$1" app want
  app=$(mac_fetch_release "$tag") || return 1
  mac_verify_sig "$app" || { log "$tag 的签名校验不过"; return 1; }
  want="${tag#v}"
  [ "$(mac_app_version "$app")" = "$want" ] || { log "$tag 包内版本是 $(mac_app_version "$app")"; return 1; }
  mac_install_app "$app" || return 1
  [ "$(svc_version | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')" = "$want" ] || { log "装后 daemon 版本不是 ${want}"; return 1; }
  log "已装 ${tag}"
}

# —— 只读取证（已装 daemon 是签名 socket，脚本不能直连；用它自己的 diag export 子命令拿 status 与设备表） ——
# mac_diag <输出目录>：status.json / devices.json / versions.txt
mac_diag() {
  local d="$1" z="$E3_STATE/diag-$$.zip"
  mkdir -p "$d"
  rm -f "$z"
  T 60 "$MAC_DAEMON_EXE" diag export --out "$z" >"$d/diag-export.json" 2>&1 || return 1
  unzip -o -q "$z" status.json devices.json versions.txt -d "$d"
  rm -f "$z"
}
# mac_node_prefix：daemon 日志里 iroh 端点 id（NodeId 前 10 位）——最近一次启动的
mac_node_prefix() { grep -o 'endpoint{id=[0-9a-f]*}' "$MAC_DAEMON_LOG" 2>/dev/null | tail -1 | sed 's/endpoint{id=\(.*\)}/\1/'; }

# —— 候选签名包 ——
# mac_build_candidate：走正式打包链路出候选包：bundle-macos.sh（daemon + 编解码库）→ bundle-desktop-macos.sh
# 只跑 build 阶段（不带签名，不出 dmg：签名路径下它会出 dmg，还要用 Finder 的 AppleScript 排版）→
# 按它第 4–5 步同样的做法组装 helper、由内向外签名（团队 Developer ID + daemon 描述文件，daemon 才读写得了
# 钥匙串）。重编译套 heavy-build 锁排队。描述文件：PPF_DAEMON_PROVISIONPROFILE，或 just mac-dev 记下的那份。
mac_build_candidate() {
  local out="$E3_STATE/mac-cand" profile ident target version
  profile="${PPF_DAEMON_PROVISIONPROFILE:-$HOME/Library/Application Support/p-pass-mac-dev/daemon.provisionprofile}"
  [ -f "$profile" ] || { log "缺 daemon 描述文件（PPF_DAEMON_PROVISIONPROFILE）"; return 1; }
  ident="$("$REPO_ROOT/tools/daemon-helper-macos.sh" identity)" || return 1
  target="${CARGO_TARGET_DIR:-$REPO_ROOT/target}"
  version="$("$REPO_ROOT/tools/release-version.sh" desktop)"
  rm -rf "$out"
  mkdir -p "$out/rel"
  (
    set -e
    cd "$REPO_ROOT"
    export CARGO_INCREMENTAL=0
    PPF_BUILD_VERSION="$version" /usr/bin/lockf -k /tmp/ppass-heavy-build.lock \
      cargo build --release -p daemon -p testclient
    tools/bundle-macos.sh "$out/rel" "$target/release/daemon" "$target/release/testclient"
    PPF_BUNDLE_PHASE=build /usr/bin/lockf -k /tmp/ppass-heavy-build.lock \
      tools/bundle-desktop-macos.sh "$out/rel" "$out/rel"
    ditto "${CARGO_TARGET_DIR:-apps/desktop/src-tauri/target}/release/bundle/macos/P-Pass.app" "$out/P-Pass.app"
    tools/daemon-helper-macos.sh assemble "$out/rel" "$out/P-Pass.app/Contents/Helpers/ppf-daemon.app" "$version"
    tools/daemon-helper-macos.sh sign "$out/P-Pass.app/Contents/Helpers/ppf-daemon.app" "$ident" "$profile"
    codesign --force --sign "$ident" --options runtime --timestamp "$out/P-Pass.app"
    codesign --verify --deep --strict "$out/P-Pass.app"
  )
}
