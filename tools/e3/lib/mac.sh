# macOS：本机已装 P-Pass 的常驻服务（launchd）与候选构建的二进制。
#
# 已装 daemon 的 IPC 是签名 socket（#1115，只认团队签名的窗口程序），脚本连不上；
# 所以服务类判定只用 launchctl、进程表与 daemon 自己的日志，不走 IPC。
# shellcheck shell=bash

MAC_APP="${E3_MAC_APP:-$HOME/Applications/P-Pass.app}"
MAC_LABEL="com.hawkeyexb.ppass.desktop.daemon"
MAC_DOMAIN="gui/$(id -u)"
MAC_PLIST="$HOME/Library/LaunchAgents/$MAC_LABEL.plist"
MAC_DAEMON_EXE="$MAC_APP/Contents/Helpers/ppf-daemon.app/Contents/MacOS/ppf-daemon"
MAC_DAEMON_LOG="$HOME/Library/Application Support/P-Pass/logs/daemon.log"


# 本机桌面 App（MAC_APP，可能就是人在用的正式版）也是 mac 设备：替换、安装、启停服务、退出外壳、改数据
# 都必须在 mac 设备锁里（tools/e3/lock mac；人工验收时 owner 用 hold-for-human 占着它，场景排队）。
# 改它的函数开头调这个，不在锁里就拒绝，不碰 App（#1449）。
mac_need_lock() {
  [ "${E3_LOCKED_MAC:-}" = 1 ] && return 0
  log "拒绝 ${FUNCNAME[1]:-?}：没持 mac 设备锁就要动本机 P-Pass（${MAC_APP}）。经 tools/e3/run / dev / restore 跑，或包在 tools/e3/lock mac 里"
  return 1
}

# 候选签名包：E3_MAC_CAND_APP 指定（如 CI 出的正式签名包），默认 just dev mac 编的开发版签名包
mac_cand_app() { echo "${E3_MAC_CAND_APP:-$E3_STATE/mac-cand/P-Pass.app}"; }

# launchd 管的那一份 daemon 的 pid（没在跑为空）
svc_pid() { launchctl print "$MAC_DOMAIN/$MAC_LABEL" 2>/dev/null | awk '/^\tpid = / {print $3; exit}'; }
# 任何常驻 daemon 进程（不带参数的那种；带参数的是 CLI 子命令或测试桩）
svc_any_pid() { ps -axwwo pid=,command= | awk -v exe="$MAC_DAEMON_EXE" '$2 == exe && NF == 2 {print $1; exit}'; }
# 全部常驻 daemon 进程（pid ppid 启动时间），一行一个：正常只有 launchd 那一份
svc_all() { ps -axwwo pid=,ppid=,lstart=,command= | awk -v exe="$MAC_DAEMON_EXE" 'NF == 8 && $8 == exe {print $1, $2, $3, $4, $5, $6, $7}'; }
svc_loaded() { launchctl print "$MAC_DOMAIN/$MAC_LABEL" >/dev/null 2>&1; }
# bootout 返回时服务可能还在拆（print 仍查得到）：等它真的从 launchd 里消失，否则紧接着的 svc_start
# 会误以为「已登记」而什么都不做
svc_stop() {
  local i
  mac_need_lock || return 1
  launchctl bootout "$MAC_DOMAIN/$MAC_LABEL" 2>/dev/null
  for i in $(seq 1 60); do svc_loaded || return 0; sleep 0.5; done
  log "服务 30s 内没从 launchd 里卸掉"
  return 1
}
# bootout 刚返回时 launchd 还在拆旧实例，紧接着 bootstrap 会报 5: Input/output error：重试到登记成功
svc_start() {
  local i
  mac_need_lock || return 1
  for i in $(seq 1 30); do
    svc_loaded && return 0
    launchctl bootstrap "$MAC_DOMAIN" "$MAC_PLIST" 2>/dev/null && return 0
    sleep 1
  done
  log "服务登记不上（launchctl bootstrap 一直失败）"
  return 1
}
svc_version() { T 10 "$MAC_DAEMON_EXE" --version --json 2>/dev/null; }
# 日志打点：daemon 每次启动会重写 daemon.log，所以按时间戳（UTC，与日志同格式）切，
# 并在每次重启之后各取一份快照。
log_mark() { date -u +%Y-%m-%dT%H:%M:%S; }
# 正式版写 daemon.log；debug 版（just dev mac）的日志走 stderr，落在 launchd 接的 daemon.err：两份都读。
MAC_DAEMON_ERR="$(dirname "$MAC_DAEMON_LOG")/daemon.err"
log_since() { awk -v s="$1" 'substr($0, 1, 19) >= s' "$MAC_DAEMON_LOG" "$MAC_DAEMON_ERR" 2>/dev/null | sort -s -k1,1; }
