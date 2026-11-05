# macOS 安装槽：取 release 包、覆盖安装、装回原版本（供 mac/upgrade 场景与 tools/e3/restore 用）。
# 依赖 common.sh、mac.sh。调用方必须已持 mac 设备锁（tools/e3/lock mac）。
#
# 测试机上只有一个安装槽（docs/decisions/2026-11-02-one-install-per-test-device.md）：覆盖安装只换
# ~/Applications/P-Pass.app，LaunchAgent 与数据目录保留；身份与配对在钥匙串里，不随安装变化。
# shellcheck shell=bash

MAC_SHELL_EXE="$MAC_APP/Contents/MacOS/p-pass-desktop"
# daemon 数据目录（库索引、缩略图、blob 账本、config.toml）；照片原件在 config.toml 的 data_dir 里，不进快照
MAC_DATA_DIR="${E3_MAC_DATA_DIR:-$HOME/Library/Application Support/P-Pass}"
MAC_TEAM="${E3_MAC_TEAM:-}"

mac_app_version() { defaults read "${1:-$MAC_APP}/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null; }
mac_shell_running() { pgrep -f "^$MAC_SHELL_EXE( |$)" >/dev/null; }

# mac_quit_shell：退出窗口程序（否则替换 .app 时它会被内核按签名失效杀掉，或单实例守卫挡住新壳）
mac_quit_shell() {
  local i
  mac_need_lock || return 1
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

# mac_install_app <源 .app> [数据]：退出外壳 → 停服务 →（数据快照）→ 整个替换
# ~/Applications/P-Pass.app → 起服务 → 等就绪。原来在跑的外壳装完后重新打开。返回 0 = 服务就绪。
# 数据（#1311）：服务停着时做——mac_snapshot 之后的第一次安装把当时的数据存进快照（候选可能带新迁移，
# 装上就改了库）。第二个参数：快照目录 = 先把数据恢复成那份再起服务（旧版 daemon 不认新迁移，拒绝启动）；
# `blank` = 清成空白数据（mac_data_blank），装上一版 release 做升级基线时用。
mac_install_app() {
  local src="$1" data="${2:-}" had_shell=0 mark old snap="$E3_STATE/mac-snapshot"
  mac_need_lock || return 1
  [ -d "$src" ] || { log "没有要装的包：$src"; return 1; }
  mac_shell_running && had_shell=1
  mac_quit_shell
  svc_stop || return 1
  if [ -f "$snap/data-pending" ]; then
    mac_data_save "$snap/data" || { svc_start; return 1; }
    rm -f "$snap/data-pending"
  fi
  if [ "$data" = blank ]; then
    mac_data_blank || { svc_start; return 1; }
  elif [ -n "$data" ]; then
    mac_data_restore "$data" || { svc_start; return 1; }
  fi
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
  [ "$had_shell" = 1 ] && { open "$MAC_APP"; mac_wait_shell_settled; }
  return 0
}

# mac_wait_shell_settled：等刚打开的窗口程序连上服务（desktop.log 出现打开之后的 to=running），再静置 10s。
# 外壳启动的头几秒在做自己的对账，这时外部停服务会被它重新登记（11-02 e3 实测），稳态场景要避开这个窗口。
mac_wait_shell_settled() {
  local t0 i
  t0=$(($(date +%s) * 1000))
  for i in $(seq 1 60); do
    awk -v t="$t0" 'match($0, /^at_ms=[0-9]+/) && substr($0, 7, RLENGTH - 6) + 0 >= t && /to=running/ {f = 1} END {exit !f}' \
      "$HOME/Library/Application Support/P-Pass/logs/desktop.log" 2>/dev/null && break
    sleep 1
  done
  sleep 10
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
# mac_snapshot：记下当前装的版本，并整包留一份（装回时优先用它：装的可能是不在 release 上的开发构建）。
# 数据快照与它同生命周期：标记 data-pending，由紧接着的那次 mac_install_app 在服务停下后存（#1311）。
mac_snapshot() {
  local s="$E3_STATE/mac-snapshot"
  rm -rf "$s"
  mkdir -p "$s"
  mac_app_version >"$s/version.txt"
  ditto "$MAC_APP" "$s/P-Pass.app"
  : >"$s/data-pending"
  echo "$s"
}
# mac_restore_snapshot：装回 mac_snapshot 留的那份（连同数据快照），核对版本，且 daemon 在线、库可读
mac_restore_snapshot() {
  local s="$E3_STATE/mac-snapshot" want data=
  [ -d "$s/P-Pass.app" ] || { log "没有可装回的快照"; return 1; }
  want=$(cat "$s/version.txt")
  if [ -d "$s/data" ]; then data="$s/data"; else log "快照里没有数据（旧快照或还没装过候选）：只装回程序"; fi
  mac_install_app "$s/P-Pass.app" "$data" || return 1
  [ "$(mac_app_version)" = "$want" ] && [ "$(svc_version | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')" = "$want" ] ||
    { log "装回后版本不是 ${want}"; return 1; }
  mac_library_readable || return 1
  log "已装回 ${want}"
}
# mac_restore_tag <tag> [数据]：从 GitHub Release 装指定 tag，核对签名与版本（数据参数同 mac_install_app）
mac_restore_tag() {
  local tag="$1" data="${2:-}" app want
  app=$(mac_fetch_release "$tag") || return 1
  mac_verify_sig "$app" || { log "$tag 的签名校验不过"; return 1; }
  want="${tag#v}"
  [ "$(mac_app_version "$app")" = "$want" ] || { log "$tag 包内版本是 $(mac_app_version "$app")"; return 1; }
  mac_install_app "$app" "$data" || return 1
  [ "$(svc_version | sed -n 's/.*"version":"\([^"]*\)".*/\1/p')" = "$want" ] || { log "装后 daemon 版本不是 ${want}"; return 1; }
  log "已装 ${tag}"
}

# —— 数据快照（#1311）：只在服务停着时存、恢复 ——
# 范围：$MAC_DATA_DIR 下的 config.toml 与 libraries/（库索引、blob 账本、缩略图），加库目录（config.toml 的
# data_dir）下的 .ppf/（blob 存储与库标识）。不含照片原件（originals/）与日志。身份与配对在钥匙串里，不随之变。
mac_library_dir() { sed -n 's/^data_dir *= *"\(.*\)"$/\1/p' "$1/config.toml" 2>/dev/null | head -1; }

# mac_data_save <目标目录>
mac_data_save() {
  local dst="$1" lib
  [ -z "$(svc_any_pid)" ] || { log "服务还在跑，不存数据快照"; return 1; }
  [ -f "$MAC_DATA_DIR/config.toml" ] || { log "没有 $MAC_DATA_DIR/config.toml"; return 1; }
  rm -rf "$dst"
  mkdir -p "$dst/appsupport"
  ditto "$MAC_DATA_DIR/config.toml" "$dst/appsupport/config.toml" || return 1
  if [ -d "$MAC_DATA_DIR/libraries" ]; then ditto "$MAC_DATA_DIR/libraries" "$dst/appsupport/libraries" || return 1; fi
  lib=$(mac_library_dir "$MAC_DATA_DIR")
  echo "$lib" >"$dst/library-dir.txt"
  if [ -n "$lib" ] && [ -d "$lib/.ppf" ]; then ditto "$lib/.ppf" "$dst/library-ppf" || return 1; fi
  log "数据快照已存（$(du -sh "$dst" | cut -f1)）"
}

# mac_data_restore <快照目录>：把 mac_data_save 存的那份放回原处（先删现有的同名目录，避免新文件残留）
mac_data_restore() {
  local src="$1" lib
  mac_need_lock || return 1
  [ -f "$src/appsupport/config.toml" ] || { log "数据快照不完整：$src"; return 1; }
  [ -z "$(svc_any_pid)" ] || { log "服务还在跑，不恢复数据"; return 1; }
  ditto "$src/appsupport/config.toml" "$MAC_DATA_DIR/config.toml" || return 1
  rm -rf "$MAC_DATA_DIR/libraries"
  if [ -d "$src/appsupport/libraries" ]; then ditto "$src/appsupport/libraries" "$MAC_DATA_DIR/libraries" || return 1; fi
  lib=$(cat "$src/library-dir.txt")
  if [ -n "$lib" ] && [ -d "$src/library-ppf" ]; then
    rm -rf "$lib/.ppf"
    ditto "$src/library-ppf" "$lib/.ppf" || return 1
  fi
  log "数据已恢复为快照（库 ${lib:-?}）"
}

# mac_data_blank：清成空白数据——删 libraries/（库索引、blob 账本、缩略图）和库目录 .ppf/ 里除库标识外的一切。
# 留 config.toml 与 .ppf/library-id：库位置正本在钥匙串里，库标记不在 daemon 会当成库没挂上（#1253）。
# 照片原件不动：daemon 启动时把它们收编进新索引（IDX-01），就是上一版的基线数据。只在留过数据快照后调用。
mac_data_blank() {
  local lib f
  mac_need_lock || return 1
  [ -z "$(svc_any_pid)" ] || { log "服务还在跑，不清数据"; return 1; }
  [ -d "$E3_STATE/mac-snapshot/data" ] || { log "没有数据快照，不清数据"; return 1; }
  rm -rf "$MAC_DATA_DIR/libraries"
  lib=$(mac_library_dir "$MAC_DATA_DIR")
  if [ -n "$lib" ] && [ -d "$lib/.ppf" ]; then
    for f in "$lib/.ppf"/* "$lib/.ppf"/.[!.]*; do
      [ -e "$f" ] && [ "$(basename "$f")" != library-id ] && rm -rf "$f"
    done
  fi
  log "数据已清成空白（库 ${lib:-?}，原件保留）"
}

# mac_library_readable：装回后库可读——已装 daemon 自己 diag export 出的 status 里有照片数
mac_library_readable() {
  local d="$E3_STATE/restore-diag-$$" n
  rm -rf "$d"
  mac_diag "$d" || { log "装回后 diag export 失败：库读不出"; return 1; }
  n=$(jget "$d/status.json" 'j["photo_count"]')
  rm -rf "$d"
  [ -n "$n" ] || { log "装回后 status 里没有照片数：库读不出"; return 1; }
  log "装回后库可读（照片数 ${n}）"
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
mac_node_prefix() { log_since 0 | grep -o 'endpoint{id=[0-9a-f]*}' | tail -1 | sed 's/endpoint{id=\(.*\)}/\1/'; }

# —— 开发版签名包（just dev mac 与 mac/upgrade 的候选）——
# mac_build_dev：debug daemon（组装成签名 helper，复用 daemon-helper-macos.sh dev）+ tauri bundle --debug 出的外壳，
# 外层用同一张团队 Developer ID 签名（hardened runtime、不请求 Apple 时间戳），与 tools/mac-dev.sh 同一做法、
# 不起 tauri dev。daemon 带描述文件签名，才读写得了钥匙串。产物：$(mac_cand_app)。重编译套 heavy-build 锁排队。
# 描述文件：PPF_DAEMON_PROVISIONPROFILE，或 just mac-dev 记下的那份。
mac_build_dev() {
  local out="$E3_STATE/mac-cand" profile ident version config desktop shell_target
  profile="${PPF_DAEMON_PROVISIONPROFILE:-$HOME/Library/Application Support/p-pass-mac-dev/daemon.provisionprofile}"
  [ -f "$profile" ] || { log "缺 daemon 描述文件（PPF_DAEMON_PROVISIONPROFILE）"; return 1; }
  ident="$("$REPO_ROOT/tools/daemon-helper-macos.sh" identity)" || return 1
  version="$("$REPO_ROOT/tools/release-version.sh" desktop)"
  config="$(node "$REPO_ROOT/tools/release/tauri-config.mjs" macos "$version")"
  desktop="$REPO_ROOT/apps/desktop"
  shell_target="${CARGO_TARGET_DIR:-$desktop/src-tauri/target}"
  rm -rf "$out"
  mkdir -p "$out"
  (
    set -e
    cd "$REPO_ROOT"
    PPF_BUILD_VERSION="$version" "$REPO_ROOT/tools/heavy-lock" cargo build -p daemon
    PPF_DAEMON_PROVISIONPROFILE="$profile" tools/daemon-helper-macos.sh dev \
      "${CARGO_TARGET_DIR:-target}/debug/daemon" "$out/ppf-daemon.app"
    cd "$desktop"
    pnpm install --frozen-lockfile --silent
    "$REPO_ROOT/tools/heavy-lock" pnpm tauri build --debug --no-bundle --config "$config"
    pnpm tauri bundle --debug --bundles app --config "$config" >/dev/null
    ditto "$shell_target/debug/bundle/macos/P-Pass.app" "$out/P-Pass.app"
    mkdir -p "$out/P-Pass.app/Contents/Helpers"
    mv "$out/ppf-daemon.app" "$out/P-Pass.app/Contents/Helpers/ppf-daemon.app"
    codesign --force --sign "$ident" --options runtime --timestamp=none "$out/P-Pass.app"
    codesign --verify --deep --strict "$out/P-Pass.app"
  )
}
