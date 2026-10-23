#!/usr/bin/env bash
# macOS 本地开发循环：前端热更新 + debug 外壳/daemon 增量构建，窗口连本机真实的签名 daemon。
#
# 为什么要这条：#1115 起常驻 daemon 只接受「团队 Developer ID 签名、identifier 是
# com.hawkeyexb.ppass.desktop」的窗口程序；未签名的 `tauri dev` 连不上它，以前验一次只能
# 打完整的正式签名包（十几到三十分钟）。这里照 Xcode 的做法：每个 debug 构建都组装成
# .app、用同一张 Developer ID 证书签名，**签名要求与校验一个字不改、没有开发后门**。
#
# 做法：开发版就装在 ~/Applications/P-Pass.app——LaunchAgent（com.hawkeyexb.ppass.desktop.daemon）
#   指向的位置，也是 `is_stable_install_location` 认的位置，所以登记一字不改、仍由 launchd 管
#   那一份 daemon，永远只有一个；改 daemon 后用 `kickstart -k` 换进程。
#   外壳 = `tauri dev` 编出的 debug 二进制，Contents/Helpers/ppf-daemon.app = debug daemon。
#
# 与正式包互斥（同一个 bundle id、LaunchAgent、数据目录）：
#   那个位置上是**正式包**（带 Apple 安全时间戳的签名）时一律拒绝，不替换、不备份——
#   可能有人正拿它做回归。要进开发模式，先自己退出正式版、把它移走。
#   退出开发模式：Ctrl+C 结束 tauri dev，再装回正式 dmg（覆盖这个位置即可）。
#
# 用法（justfile 的 mac-dev 转发到这里）：
#   up [tauri dev 参数…]  默认。编 daemon、组装签名 helper → `tauri dev`（vite HMR；外壳 Rust
#                          一改，cargo runner 即本脚本的 runner 子命令自动组装、签名、拉起）。
#                          Ctrl+C 结束。
#   daemon                 改了 daemon 的 Rust 之后：增量编译 → 组装签名 helper → 重签外层
#                          → kickstart -k → 让 tauri dev 重新拉起外壳（见 cmd_daemon）。
#   status                 现在装的是开发版还是正式版、进程与签名。
#   runner <bin> [args…]   仅供 cargo 调用（CARGO_TARGET_<triple>_RUNNER），不要手敲。
#
# 授权文件：PPF_DAEMON_PROVISIONPROFILE=<daemon 的 Developer ID 授权文件>。给过一次就记在
# 状态目录里（授权文件不是机密，只是不进仓库），之后不用再给。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESKTOP="$ROOT/apps/desktop"
HELPER_TOOL="$ROOT/tools/daemon-helper-macos.sh"
WT="$ROOT/tools/release/with-timeout.sh"
SELF="$ROOT/tools/mac-dev.sh"

APP="$HOME/Applications/P-Pass.app"
SHELL_EXE="$APP/Contents/MacOS/p-pass-desktop"
HELPER="$APP/Contents/Helpers/ppf-daemon.app"
DAEMON_EXE="$HELPER/Contents/MacOS/ppf-daemon"
DAEMON_LABEL="com.hawkeyexb.ppass.desktop.daemon"
DAEMON_PLIST="$HOME/Library/LaunchAgents/$DAEMON_LABEL.plist"
STATE="$HOME/Library/Application Support/p-pass-mac-dev"
SAVED_PROFILE="$STATE/daemon.provisionprofile"
# tauri dev 额外监视的目录（--additional-watch-folders）：往里写文件 = 让它杀掉外壳、
# 跑一遍（无事可做的）cargo run、经 runner 重新签名拉起。
RESTART_DIR="$STATE/shell-restart"
DOMAIN="gui/$(id -u)"
DAEMON_TARGET="${CARGO_TARGET_DIR:-$ROOT/target}"
SHELL_TARGET="${CARGO_TARGET_DIR:-$DESKTOP/src-tauri/target}"

die() { echo "FATAL: $*" >&2; exit 1; }
say() { echo "── mac-dev: $*"; }
now() { python3 -c 'import time; print(f"{time.time():.1f}")'; }

[ "$(uname)" = "Darwin" ] || die "mac-dev 只在 macOS 上用"

# 外壳与 daemon 同一个版本号（#809，与正式包同源）：daemon 经 PPF_BUILD_VERSION、外壳经
# tauri --config。两边不一致时壳的内核对账（#667）会去换内核。
VERSION="$("$ROOT/tools/release-version.sh" desktop)"
TAURI_CONFIG="$(node "$ROOT/tools/release/tauri-config.mjs" macos "$VERSION")"

profile() {
  if [ -n "${PPF_DAEMON_PROVISIONPROFILE:-}" ]; then
    mkdir -p "$STATE"
    cmp -s "$PPF_DAEMON_PROVISIONPROFILE" "$SAVED_PROFILE" 2>/dev/null \
      || cp "$PPF_DAEMON_PROVISIONPROFILE" "$SAVED_PROFILE"
  fi
  [ -f "$SAVED_PROFILE" ] || die "第一次用要给授权文件：PPF_DAEMON_PROVISIONPROFILE=<daemon 的 Developer ID 授权文件> just mac-dev"
  echo "$SAVED_PROFILE"
}

running_pids() { pgrep -f "^$1( |$)" || true; }

daemon_pid() {
  launchctl print "$DOMAIN/$DAEMON_LABEL" 2>/dev/null | awk '/^\tpid = / {print $3; exit}'
}

cdhash() { codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p'; }

# 正式包 = 外层签名带 Apple 安全时间戳（发布链 `--timestamp`）；开发版签名是 --timestamp=none，
# codesign 只给 Signed Time、没有 Timestamp 行。
is_release_install() {
  [ -d "$APP" ] && codesign -dvv "$APP" 2>&1 | grep -q '^Timestamp='
}

# 互斥闸门：每个会写 $APP 或动 daemon 的子命令先过这里。
refuse_release() {
  is_release_install || return 0
  if [ -n "$(running_pids "$SHELL_EXE")" ] || [ -n "$(daemon_pid)" ]; then
    die "正式版正在运行（${APP}）。先退出正式版：菜单栏「退出」并停止后台服务，再把正式包移走；
       mac-dev 不会替换、备份或恢复正式包。"
  fi
  die "$APP 是正式包。mac-dev 不会替换、备份或恢复它——要进开发模式先自己把它移走。"
}

# 只用 launchd 那一份：从不直接起 daemon 进程。
kickstart_daemon() {
  if launchctl print "$DOMAIN/$DAEMON_LABEL" >/dev/null 2>&1; then
    launchctl kickstart -k "$DOMAIN/$DAEMON_LABEL"
  elif [ -f "$DAEMON_PLIST" ]; then
    launchctl bootstrap "$DOMAIN" "$DAEMON_PLIST"
  else
    echo "warn: 没有 daemon 的 LaunchAgent——外壳启动对账会登记它（与正式包同一条路径）" >&2
  fi
}

# 一个 daemon 的不变量：launchd 登记指向本 App，且机器上只有这一个常驻 daemon 进程。
check_single_daemon() {
  if [ -f "$DAEMON_PLIST" ] && ! grep -q "<string>$DAEMON_EXE</string>" "$DAEMON_PLIST"; then
    die "LaunchAgent 不指向 ${DAEMON_EXE}——先 just mac-dev status 看清楚再动"
  fi
  # 常驻 daemon = 不带参数的 daemon 进程（LaunchAgent 就这么起它）；带参数的是 CLI 子命令
  # （外壳每 10s 的 `--version --json` 探测、diag export）或测试沙盒（--ephemeral），不算。
  # -ww：不加的话非终端下命令行被截断，长路径匹配不上、检查形同虚设。
  local others
  others="$(ps -axwwo pid=,command= | awk -v me="$(daemon_pid)" \
    'NF == 2 && $2 ~ /(\/ppf-daemon|\/(debug|release)\/daemon)$/ && $1 != me')"
  [ -z "$others" ] || die "除 launchd 那一份外还有常驻 daemon 在跑：
$others"
}

# 增量编译 daemon → 组装成签名 helper（复用 daemon-helper-macos.sh dev）→ 换进 App。
install_helper() {
  local stage
  say "编译 daemon（debug，版本 ${VERSION}）"
  (cd "$ROOT" && PPF_BUILD_VERSION="$VERSION" cargo build -p daemon)
  stage="$(mktemp -d)"
  PPF_DAEMON_PROVISIONPROFILE="$(profile)" \
    "$HELPER_TOOL" dev "$DAEMON_TARGET/debug/daemon" "$stage/ppf-daemon.app"
  # 签好再整目录换：launchd KeepAlive 在换的瞬间拉起也拿不到半成品。
  mkdir -p "$APP/Contents/Helpers"
  [ ! -e "$HELPER" ] || mv "$HELPER" "$stage/old.app"
  mv "$stage/ppf-daemon.app" "$HELPER"
  rm -rf "$stage"
}

# 外层：与正式包同一张证书、同样的参数（hardened runtime、不带权限声明），只是不请求
# Apple 时间戳（与 daemon-helper-macos.sh dev 一致）。不用 --deep：helper 已单独签好。
sign_outer() {
  "$WT" "codesign 外层开发 App" 300 1 -- \
    codesign --force --sign "$("$HELPER_TOOL" identity)" --options runtime --timestamp=none "$APP"
  codesign --verify --deep --strict "$APP"
}

# 退出正在跑的开发外壳（refuse_release 已排除正式版），否则单实例守卫会让新外壳一启动就退出。
quit_dev_shell() {
  local pids i
  pids="$(running_pids "$SHELL_EXE")"
  [ -n "$pids" ] || return 0
  say "退出上一次的开发外壳（pid $(echo $pids)）"
  kill $pids 2>/dev/null || true
  for i in $(seq 1 50); do
    [ -z "$(running_pids "$SHELL_EXE")" ] && return 0
    sleep 0.2
  done
  kill -9 $(running_pids "$SHELL_EXE") 2>/dev/null || true
}

cmd_up() {
  profile >/dev/null
  "$HELPER_TOOL" identity >/dev/null
  refuse_release
  check_single_daemon
  quit_dev_shell
  install_helper
  kickstart_daemon
  local triple var
  triple="$(rustc -vV | awk '/^host: / {print $2}')"
  var="CARGO_TARGET_$(echo "$triple" | tr 'a-z-' 'A-Z_')_RUNNER"
  say "tauri dev（外壳每次编完由 $SELF runner 组装、签名、拉起）"
  cd "$DESKTOP"
  pnpm install --frozen-lockfile --silent
  # 开发外壳只连常驻签名 daemon：测试沙盒变量不带进来。
  unset PPF_SANDBOX_DIR
  mkdir -p "$RESTART_DIR"
  env "$var=$SELF runner" PPF_MAC_DEV=1 pnpm tauri dev --config "$TAURI_CONFIG" \
    --additional-watch-folders "$RESTART_DIR" "$@"
}

# cargo runner：cargo 编完外壳后带着二进制路径调这里。
cmd_runner() {
  local bin="$1"; shift
  local t0 skel
  t0="$(now)"
  [ "${PPF_MAC_DEV:-}" = "1" ] || die "runner 只给 just mac-dev 用"
  refuse_release
  [ -d "$HELPER" ] || die "$HELPER 不存在——先 just mac-dev"
  # .app 骨架（Info.plist、图标）用 tauri 自己的 bundler 出，不另写：只打包、不编译，约 1 秒。
  (cd "$DESKTOP" && node_modules/.bin/tauri bundle --debug --bundles app --config "$TAURI_CONFIG" >/dev/null)
  skel="$SHELL_TARGET/debug/bundle/macos/P-Pass.app"
  cmp -s "$bin" "$skel/Contents/MacOS/p-pass-desktop" || die "tauri bundle 的产物不是这次编出的 $bin"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "$skel/Contents/Info.plist" "$APP/Contents/Info.plist"
  cp -R "$skel/Contents/Resources/." "$APP/Contents/Resources/"
  # 先写临时文件再 rename：直接覆盖一个仍被映射的可执行文件会让内核按签名失效杀进程。
  cp "$bin" "$SHELL_EXE.new"
  mv "$SHELL_EXE.new" "$SHELL_EXE"
  sign_outer
  echo "── mac-dev: 外壳已组装并签名（$(python3 -c "print(f'{$(now)-$t0:.1f}')")s），拉起 $SHELL_EXE"
  exec "$SHELL_EXE" "$@"
}

# helper 变了 ⇒ 外层的封印（记着 helper 的 cdhash）变了 ⇒ 外层重签后 cdhash 也变。
# 正在跑的外壳此后会被 daemon 的对端校验拒绝（「the code on disk does not match what is
# running」）——这正是 #1115 校验该有的行为，不绕。所以外壳也要换成磁盘上这一份：
# 经 tauri dev 自己的重启路径拉起（cargo 无事可做，runner 重新签名、exec）。
cmd_daemon() {
  local t0 old_pid pid old_shell shell before i
  t0="$(now)"
  refuse_release
  [ -d "$HELPER" ] || die "还没进开发模式——先 just mac-dev"
  check_single_daemon
  old_pid="$(daemon_pid)"
  before="$(cdhash "$APP")"
  install_helper
  sign_outer
  kickstart_daemon
  for i in $(seq 1 100); do
    pid="$(daemon_pid)"
    [ -n "$pid" ] && [ "$pid" != "$old_pid" ] && break
    sleep 0.1
  done
  check_single_daemon
  say "daemon 已换：pid ${old_pid:-无} → ${pid:-无}，$(python3 -c "print(f'{$(now)-$t0:.1f}')")s"
  old_shell="$(running_pids "$SHELL_EXE")"
  if [ -n "$old_shell" ] && [ "$(cdhash "$APP")" != "$before" ]; then
    [ -d "$RESTART_DIR" ] || die "外壳在跑但不是 just mac-dev 拉起的——手动重开它"
    date >"$RESTART_DIR/restart"
    for i in $(seq 1 600); do
      shell="$(running_pids "$SHELL_EXE")"
      [ -n "$shell" ] && [ "$shell" != "$old_shell" ] && break
      sleep 0.1
    done
    [ -n "$shell" ] && [ "$shell" != "$old_shell" ] || die "60s 内外壳没有重新拉起——看 tauri dev 那个终端"
    say "外壳已按新封印重新拉起：pid $old_shell → ${shell}，共 $(python3 -c "print(f'{$(now)-$t0:.1f}')")s"
  fi
}

# 只读：不写 $APP、不动 daemon。
cmd_status() {
  if [ ! -d "$APP" ]; then echo "模式：$APP 不存在"
  elif is_release_install; then echo "模式：正式包（mac-dev 不会动它）"
  else echo "模式：开发版"; fi
  echo "外壳：$(codesign -dvvv "$APP" 2>&1 | grep -E '^(Identifier|TeamIdentifier|CDHash)=' | tr '\n' ' ')"
  echo "      进程 $(running_pids "$SHELL_EXE" | tr '\n' ' ')"
  echo "daemon：$(codesign -dvvv "$HELPER" 2>&1 | grep -E '^(Identifier|TeamIdentifier|CDHash)=' | tr '\n' ' ')"
  echo "      launchd pid $(daemon_pid)"
  check_single_daemon && echo "      ✓ 只有 launchd 这一份 daemon"
}

cmd="${1:-up}"; [ $# -eq 0 ] || shift
case "$cmd" in
  up) cmd_up "$@" ;;
  runner) [ $# -ge 1 ] || die "用法：$0 runner <bin> [args…]"; cmd_runner "$@" ;;
  daemon) cmd_daemon ;;
  status) cmd_status ;;
  -*) cmd_up "$cmd" "$@" ;;
  *) die "用法：$0 [up|daemon|status] …（见文件头）" ;;
esac
