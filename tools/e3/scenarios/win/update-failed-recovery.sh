# #1735（#1063 收尾）：Windows 安装失败后服务恢复复验。
#
# 验证安装器（installer-hooks.nsh）在「替换 ppf-daemon.exe 失败」时的恢复语义。
#
# 恢复机制（真机实测结论，2026-11-17）：
#   - 安装器 UpdateFailureRecover 的恢复 = 一次性 `sc start`（wanted-state 不是 stopped 时），
#     并把「尝试过恢复」记成 update-failed 的 service=1（installer-hooks.nsh:281-330 不检查 sc start 结果）。
#   - 那句 `sc failure … restart/5000` 只是补回崩溃自动重启（PREINSTALL 清掉的持久配置），
#     **不会**重试「start 失败」：实测 Event 7000（sharing violation）后 60s 无 Event 7032，服务不回来。
#   - 所以 sc start 成不成只看二进制此刻可不可读：share=read（只占写）→ 替换失败但 sc start 能拉起旧版；
#     share=none（读写执行全占）→ 替换失败且 sc start 也失败，服务一直停着，没人再拉起。
#
# 场景三个用例：
#   - 服务原本在运行 + 只占写（FILE_SHARE_READ）→ 替换失败被识别（update-failed service=1），
#     恢复归因于安装器 sc start（旧版 daemon 被拉起、IPC 可应答、版本仍是 base）。
#   - 用户已主动停过（wanted-state=stopped）+ 全占（FILE_SHARE_NONE）→ update-failed service=0，
#     不得拉起 daemon，不得新增/启用自启登记。
#   - 对照组：不注入文件占用 → 正常覆盖安装成功，daemon 与版本都换成候选。
#
# 反证（E2）：用全占（FILE_SHARE_NONE）重跑「服务运行」用例 ⇒ sc start 也失败、释放锁后
# daemon 仍不恢复 ⇒ 「应恢复」判据（daemon 在跑 / IPC / 服务在运行）变红，证明恢复确实归因于
# 安装器 sc start，而不是测试手动 Start-Service 掩盖。
#
# 前置：本机是 perMachine 服务模式安装（Program Files + Windows 服务 P-Pass），会话已提权
# （High integrity，运行安装器 /S 不需要弹 UAC）。三个用例共用一个候选安装包；base 用更旧版本，
# 让「安装失败版本不变 / 正常安装版本升级」可判。
# 只动 tools/e3/scenarios/win/** 与 docs/evidence/**，不碰产品代码，不接 Android/iOS。
DESC="#1735 安装失败后服务恢复：只占写→替换失败 service=1→sc start 拉起旧版 / 用户停过 service=0 不拉起 / 对照组正常安装"
COUNTER=on

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

INST_DIR_WIN="${PROGRAMFILES}\\P-Pass"
INST_DIR="$(cygpath -u "$INST_DIR_WIN")"
INST_DAEMON="$INST_DIR/ppf-daemon.exe"
PD_DIR_WIN="${ProgramData:-C:\ProgramData}\P-Pass"
PD_DIR="$(cygpath -u "$PD_DIR_WIN")"
# 服务模式下 daemon 的 config.toml（库位置）在 ProgramData，不在用户态数据目录。
WIN_CONF_DIR="$PD_DIR"

# base 用更旧版本（本地缓存已有），候选用当前最新 test 包；都可用环境变量换。
UF_BASE_TAG="${E3_WIN_UF_BASE_TAG:-v0.11.2-test.3}"
UF_BASE_VER="${E3_WIN_UF_BASE_VER:-0.11.2-test.3}"
UF_CAND_TAG="${E3_WIN_UF_CAND_TAG:-v0.11.4-test.1}"
UF_CAND_VER="${E3_WIN_UF_CAND_VER:-0.11.4-test.1}"

# —— 服务 / 版本 / 标记 ——

svc_state() { win_ps "(Get-Service -Name 'P-Pass' -ErrorAction SilentlyContinue).Status" 2>/dev/null | tr -d '[:space:]'; }
svc_exists() { win_ps "if (Get-Service -Name 'P-Pass' -ErrorAction SilentlyContinue) { 'yes' } else { 'no' }" 2>/dev/null | tr -d '[:space:]'; }
inst_exe_version() { win_ps "(Get-Item '$INST_DIR_WIN\\p-pass-desktop.exe' -ErrorAction SilentlyContinue).VersionInfo.ProductVersion" 2>/dev/null | tr -d '[:space:]'; }
daemon_file_version() { # 磁盘上 ppf-daemon.exe 的版本；文件被独占时读不出（返回空）。
  "$INST_DAEMON" --version --json 2>/dev/null | tr -d '\r' | sed -n 's/.*"version":"\([^"]*\)".*/\1/p'
}
wanted_state() { tr -d '\r\n' <"$PD_DIR/wanted-state" 2>/dev/null; }
update_failed_present() { [ -f "$PD_DIR/update-failed" ]; }
svc_binpath() { win_ps "(Get-CimInstance Win32_Service -Filter \"Name='P-Pass'\").PathName" 2>/dev/null | tr -d '\r'; }

# —— 安装（会话已提权：直接跑 /S，不弹 UAC；未提权时 setup 返回 77 记 SKIP）——

win_is_high_integrity() {
  # 匹配完整性级别的 SID（High Mandatory Level = S-1-16-12288）：显示名会随系统语言本地化，
  # 非英文系统上 grep 'High Mandatory Level' 会落空、误把已提权会话判成没提权而 SKIP。
  MSYS2_ARG_CONV_EXCL='*' /c/Windows/System32/whoami.exe /groups 2>/dev/null | tr -d '\r' | grep -q 'S-1-16-12288'
}

install_pkg() { # install_pkg <setup.exe> <outfile>
  local exe="$1" out="$2" t0 t1 code
  t0=$(date +%s)
  code="$(win_ps "\$p = Start-Process -FilePath '$(cygpath -w "$exe")' -ArgumentList '/S' -Wait -PassThru; if (\$p) { \$p.ExitCode } else { 'NO_PROCESS' }" 2>"$out.err")"
  t1=$(date +%s)
  printf 'installer=%s\nexit=%s\nduration_secs=%s\n' "$(basename "$exe")" "$(printf '%s' "$code" | tr -d '[:space:]')" "$((t1 - t0))" >"$out"
  [ -s "$out.err" ] || rm -f "$out.err"
}

# —— 独占句柄占住 ppf-daemon.exe ——
# share 决定占住方式，对应两种故障注入：
#   share=none/0（FILE_SHARE_NONE，默认）：写/读/执行全被拒。NSIS File 覆盖、--version 复查、
#     UpdateFailureRecover 的 sc start 全失败 ⇒ 「文件替换失败 + 服务起不来」，恢复也起不来。
#   share=read/1（FILE_SHARE_READ）：只许别人读/执行，不许写/删。NSIS File 覆盖失败（写被拒），
#     但 --version 与 sc start 能读 ⇒ 「文件替换失败 + 服务可被 sc start 拉起旧版」，
#     这是让「恢复」真正归因到安装器 sc start 的可成功路径（见 act 用例1 与 counter）。
# Git Bash 的 kill 杀不掉 Windows 进程，释放必须用 PowerShell Stop-Process。
# pid 写到 $E3_STATE/win/uf-lock-<tag>.pid（绝对路径，跨 bash/Python 用 cygpath 对齐）。

uf_lock_pidfile() { echo "$E3_STATE/win/uf-lock-$1.pid"; }

win_lock_daemon() { # win_lock_daemon <tag> [share=none|read]
  local tag="$1" share="${2:-none}" pidfile i
  case "$share" in read|1) share=1 ;; *) share=0 ;; esac
  pidfile="$(uf_lock_pidfile "$tag")"
  rm -f "$pidfile"
  python3 - "$(cygpath -m "$INST_DAEMON")" "$(cygpath -m "$pidfile")" "$share" <<'PY' >/dev/null 2>&1 &
import ctypes, sys, time, os
k32 = ctypes.WinDLL('kernel32', use_last_error=True)
h = k32.CreateFileW(sys.argv[1], 0x80000000, int(sys.argv[3]), None, 3, 0x80, None)
if h in (-1, 0xFFFFFFFFFFFFFFFF):
    sys.exit(1)
with open(sys.argv[2], 'w') as f:
    f.write(str(os.getpid()))
while True:
    time.sleep(60)
PY
  for i in $(seq 1 50); do [ -s "$pidfile" ] && return 0; sleep 0.2; done
  echo "锁文件失败（${tag}）" >&2
  return 1
}

win_daemon_file_unlocked() { # 试 open share=0：成功即无人独占（运行中的 daemon 不拦这个）。
  python3 - "$(cygpath -m "$INST_DAEMON")" <<'PY'
import ctypes, sys
k32 = ctypes.WinDLL('kernel32', use_last_error=True)
h = k32.CreateFileW(sys.argv[1], 0x80000000, 0, None, 3, 0x80, None)
if h in (-1, 0xFFFFFFFFFFFFFFFF):
    sys.exit(1)
k32.CloseHandle(h)
PY
}

win_unlock_daemon() { # win_unlock_daemon <tag>
  local tag="$1" pidfile pid i
  pidfile="$(uf_lock_pidfile "$tag")"
  pid="$(tr -d '[:space:]' <"$pidfile" 2>/dev/null)"
  [ -n "$pid" ] && win_ps "Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1 || true
  # 确认持锁进程真的退出（文件能被独占打开）后再删 pidfile；杀不掉就留着给 teardown 重试。
  for i in $(seq 1 20); do win_daemon_file_unlocked && { rm -f "$pidfile"; return 0; }; sleep 0.3; done
  echo "释放锁失败（${tag}）" >&2
  return 1
}

win_kill_lingering_locks() { # teardown 兜底：杀掉任何残留的独占进程
  local pf pid i
  for pf in "$E3_STATE"/win/uf-lock-*.pid; do
    [ -f "$pf" ] || continue
    pid="$(tr -d '[:space:]' <"$pf" 2>/dev/null)"
    [ -n "$pid" ] && win_ps "Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1 || true
    # 确认进程退出后再删 pidfile：杀不掉就留着，别丢了这个兜底的唯一凭据。
    for i in $(seq 1 20); do win_daemon_file_unlocked && { rm -f "$pf"; break; }; sleep 0.3; done
  done
}

# —— 采样 / 判定数据 ——

record_state() { # record_state <dir> <tag>
  local d="$1" tag="$2"
  {
    echo "svc_state=$(svc_state)"
    echo "svc_exists=$(svc_exists)"
    echo "daemon_pid=$(win_daemon_pid)"
    echo "daemon_file_version=$(daemon_file_version)"
    echo "inst_exe_version=$(inst_exe_version)"
    echo "wanted_state=$(wanted_state)"
    echo "task_state=$(win_task_state)"
    echo "task_enabled=$(win_task_enabled)"
    echo "run_value=$(win_run_value_exists && echo yes || echo no)"
    echo "svc_binpath=$(svc_binpath)"
    echo "update_failed_present=$(update_failed_present && echo yes || echo no)"
  } >"$d/$tag-state.txt"
}

record_update_failed() { # record_update_failed <dir> <tag>
  local d="$1" tag="$2" f="$PD_DIR/update-failed"
  if [ -f "$f" ]; then tr -d '\r' <"$f" >"$d/$tag-update-failed.txt"; else : >"$d/$tag-update-failed.txt"; fi
}

diag_inst() { # diag_inst <dir>：服务模式 daemon（Program Files）的 diag export；IPC 应答证据
  local d="$1" i
  local zip="$d/diag.zip"
  mkdir -p "$d"
  rm -f "$zip"; rm -rf "$d/diag"
  win_ps "& '$(cygpath -w "$INST_DAEMON")' diag export --out '$(cygpath -w "$zip")' --app-version '$(inst_exe_version)'" >"$d/diag-export.json" 2>"$d/diag-export.err" || true
  for i in $(seq 1 25); do [ -s "$zip" ] && break; sleep 0.2; done
  if [ -s "$zip" ]; then
    mkdir -p "$d/diag"
    unzip -oq "$zip" -d "$d/diag" >/dev/null 2>&1 || true
  fi
  [ -f "$d/diag/status.json" ]
}

diag_daemon_reachable() { grep -q '"daemon_reachable":true' "$1/diag-export.json" 2>/dev/null; }

# 服务日志（daemon.log 尾部）：安装失败/恢复期间的运行证据。
capture_daemon_log() { # capture_daemon_log <dir> <tag>
  local d="$1" tag="$2" log="$PD_DIR/logs/daemon.log"
  if [ -f "$log" ]; then tail -c 200000 "$log" >"$d/$tag-daemon.log" 2>/dev/null || true; fi
}

ensure_running() { # 恢复到「服务在运行 + wanted-state=running」的干净起点
  win_ps "Set-Content -LiteralPath '$(cygpath -w "$PD_DIR/wanted-state")' -Value 'running' -NoNewline -Encoding ascii" >/dev/null 2>&1 || true
  if [ "$(svc_state)" != Running ]; then
    win_ps "Start-Service -Name 'P-Pass' -ErrorAction SilentlyContinue" >/dev/null 2>&1 || true
  fi
  local i
  for i in $(seq 1 30); do [ "$(svc_state)" = Running ] && [ -n "$(win_daemon_pid)" ] && return 0; sleep 1; done
  return 1
}

wait_daemon_file_version() { # wait_daemon_file_version <ver> <secs>：等磁盘文件换成目标版本且服务运行
  local ver="$1" end=$((SECONDS + ${2:-60}))
  while [ $SECONDS -lt $end ]; do
    [ "$(daemon_file_version)" = "$ver" ] && [ "$(svc_state)" = Running ] && return 0
    sleep 1
  done
  return 1
}

setup() {
  win_is_high_integrity || { echo "本会话不是 High integrity，跑不了真实安装器 /S（需要提权）"; return 77; }
  [ "$(svc_exists)" = yes ] || { echo "没有 Windows 服务 P-Pass（先做 perMachine 安装）"; return 77; }
  [ -f "$INST_DAEMON" ] || { echo "没有 $INST_DAEMON"; return 77; }
  local base cand
  base="$(win_release_file "$UF_BASE_TAG" '*_x64-setup.exe')"
  cand="$(win_release_file "$UF_CAND_TAG" '*_x64-setup.exe')"
  [ -n "$base" ] || { echo "缺 base 安装包（$WIN_REL_DIR/$UF_BASE_TAG/*_x64-setup.exe）"; return 77; }
  [ -n "$cand" ] || { echo "缺候选安装包（$WIN_REL_DIR/$UF_CAND_TAG/*_x64-setup.exe）"; return 77; }
  echo "base：$(basename "$base")（sha256 $(sha256sum "$base" | awk '{print $1}')）"
  echo "候选：$(basename "$cand")（sha256 $(sha256sum "$cand" | awk '{print $1}')）"
  echo "起点：inst_exe=$(inst_exe_version) daemon_file=$(daemon_file_version) svc=$(svc_state) wanted=$(wanted_state)"
}

act() {
  local d="$OUT" base cand
  base="$(win_release_file "$UF_BASE_TAG" '*_x64-setup.exe')"
  cand="$(win_release_file "$UF_CAND_TAG" '*_x64-setup.exe')"

  # ---- 0) 装 base（更旧版本），作为三个用例的共同起点 ----
  echo "== 装 base $UF_BASE_VER =="
  install_pkg "$base" "$d/base-install.txt" || true
  wait_daemon_file_version "$UF_BASE_VER" 90 || echo "base 安装后没等到 ${UF_BASE_VER}（继续，judge 判）"
  ensure_running || echo "base 装后服务没起来（继续，judge 判）"
  record_state "$d" base
  capture_daemon_log "$d" base

  # ---- 1) 失败 / 服务原本在运行 ----
  local ca="$d/case-running"; mkdir -p "$ca"
  echo "== 用例1：服务运行中，只占写锁（替换失败 + sc start 可拉起），装候选（应失败 service=1，旧版恢复）=="
  ensure_running || { echo "用例1 起点服务没起来"; return 1; }
  record_state "$ca" pre
  win_lock_daemon running read || { echo "用例1 锁文件失败"; return 1; }
  install_pkg "$cand" "$ca/install.txt" || true
  # 恢复是安装器 UpdateFailureRecover 里的 sc start（share=read 时二进制可读，能拉起旧版）；
  # sc start 是异步的，等它真的把旧版 daemon 拉到 Running 再采样。这里不手动 Start-Service——手动拉起会掩盖「安装器恢复失效」的回归。
  local i ok=0
  for i in $(seq 1 30); do [ "$(svc_state)" = Running ] && [ -n "$(win_daemon_pid)" ] && { ok=1; break; }; sleep 1; done
  [ "$ok" = 1 ] || echo "用例1 sc start 后服务没恢复"
  record_update_failed "$ca" after-fail
  record_state "$ca" after-fail
  capture_daemon_log "$ca" after-fail
  win_unlock_daemon running || echo "用例1 释放锁失败"
  diag_inst "$ca" || true
  record_state "$ca" after-recover
  capture_daemon_log "$ca" after-recover

  # ---- 2) 失败 / 用户已主动停止 ----
  local cb="$d/case-stopped"; mkdir -p "$cb"
  echo "== 用例2：用户停过（wanted-state=stopped），锁文件，装候选（应失败，service=0 不拉起）=="
  # 「用户停过」的正本是 ProgramData 的 wanted-state（壳点停止写它，安装器读它）。
  win_ps "Set-Content -LiteralPath '$(cygpath -w "$PD_DIR/wanted-state")' -Value 'stopped' -NoNewline -Encoding ascii" >/dev/null 2>&1
  win_ps "Stop-Service -Name 'P-Pass' -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1 || true
  for i in $(seq 1 20); do [ "$(svc_state)" = Stopped ] && [ -z "$(win_daemon_pid)" ] && break; sleep 0.5; done
  record_state "$cb" pre
  win_lock_daemon stopped || { echo "用例2 锁文件失败"; return 1; }
  install_pkg "$cand" "$cb/install.txt" || true
  record_update_failed "$cb" after-fail
  record_state "$cb" after-fail
  capture_daemon_log "$cb" after-fail
  # 先释放锁再采样：锁还占着时即使想拉起 daemon 也起不来，采样要能抓到「解锁后仍不该被拉起」。
  win_unlock_daemon stopped || echo "用例2 释放锁失败"
  : >"$cb/stopped-samples.txt"
  for i in 5 10 15; do
    sleep 5
    echo "t+${i}s pid=$(win_daemon_pid) svc=$(svc_state) wanted=$(wanted_state)" >>"$cb/stopped-samples.txt"
  done
  ensure_running || echo "用例2 收尾没把服务拉起来"

  # ---- 3) 对照组：不注入文件占用，正常覆盖安装 ----
  local cc="$d/case-normal"; mkdir -p "$cc"
  echo "== 用例3：无占用，正常覆盖安装候选 $UF_CAND_VER =="
  record_state "$cc" pre
  install_pkg "$cand" "$cc/install.txt" || true
  wait_daemon_file_version "$UF_CAND_VER" 90 || echo "正常安装后没等到 ${UF_CAND_VER}（继续，judge 判）"
  diag_inst "$cc" || true
  record_state "$cc" after-install
  capture_daemon_log "$cc" after-install
}

# —— 判据小工具 ——

no_daemon_samples() { [ -s "$1" ] && no_line "$1" 'pid=[0-9]'; }

judge() {
  local d="$1"
  local ca="$d/case-running" cb="$d/case-stopped" cc="$d/case-normal"

  # 用例1：失败被识别（应失败）+ 恢复归因到安装器 sc start（应恢复）。
  # 反证里用 share=none 锁 ⇒ sc start 失败 ⇒ 下面三条「应恢复」判据变红，证明恢复确实归因于安装器 sc start。
  check "用例1 安装失败被识别：update-failed 存在且首行 install-failed" grep -qx 'install-failed' "$ca/after-fail-update-failed.txt"
  check "用例1 service=1（用户没停过，安装器尝试恢复）" grep -qx 'service=1' "$ca/after-fail-update-failed.txt"
  check "用例1 恢复后 daemon 在运行（安装器 sc start 拉起）" grep -Eq '^daemon_pid=[0-9]+' "$ca/after-recover-state.txt"
  check "用例1 恢复后 IPC 可应答（diag daemon_reachable）" diag_daemon_reachable "$ca"
  check "用例1 版本与安装结果一致（失败=仍是 base ${UF_BASE_VER}）" grep -Fqx "daemon_file_version=$UF_BASE_VER" "$ca/after-recover-state.txt"
  check "用例1 恢复后服务在运行" grep -qx 'svc_state=Running' "$ca/after-recover-state.txt"

  # 用例2：用户停过 → service=0、不拉起、不新增自启
  check "用例2 update-failed 存在且首行 install-failed" grep -qx 'install-failed' "$cb/after-fail-update-failed.txt"
  check "用例2 service=0（用户停过，安装器不恢复）" grep -qx 'service=0' "$cb/after-fail-update-failed.txt"
  check "用例2 wanted-state 仍是 stopped（安装器不把用户选择改回 running）" grep -qx 'wanted_state=stopped' "$cb/after-fail-state.txt"
  check "用例2 采样期间 daemon 一次都没被拉起" no_daemon_samples "$cb/stopped-samples.txt"
  check "用例2 无新增计划任务自启" grep -qx 'task_state=' "$cb/after-fail-state.txt"
  check "用例2 无 HKCU Run 自启值" grep -qx 'run_value=no' "$cb/after-fail-state.txt"

  # 用例3：对照组正常安装
  check "用例3 正常安装后 daemon 文件版本 = 候选 $UF_CAND_VER" grep -Fqx "daemon_file_version=$UF_CAND_VER" "$cc/after-install-state.txt"
  check "用例3 正常安装后服务在运行" grep -qx 'svc_state=Running' "$cc/after-install-state.txt"
  check "用例3 正常安装后 daemon 在运行" grep -Eq '^daemon_pid=[0-9]+' "$cc/after-install-state.txt"
  check "用例3 正常安装后 IPC 可应答" diag_daemon_reachable "$cc"
  check "用例3 正常安装后没有 update-failed 标记" grep -qx 'update_failed_present=no' "$cc/after-install-state.txt"

  verdict
}

counter() {
  local d="$OUT" base cand
  # 反证（不恢复服务）：share=none（FILE_SHARE_NONE）锁住 daemon ⇒ 替换失败，UpdateFailureRecover 的
  # sc start 也因二进制不可读而失败 ⇒ 释放锁后 daemon 仍不会被拉起 ⇒ 「应恢复」判据（daemon 在跑 / IPC / 服务在运行）变红，
  # 证明主路径的「恢复」确实归因于安装器 sc start，而不是测试手动 Start-Service。
  # 用例2/用例3 不受反证影响，沿用主路径证据，避免它们被误判红。
  mkdir -p "$d"
  cp -r "$EV/main/case-stopped" "$d/" 2>/dev/null || true
  cp -r "$EV/main/case-normal" "$d/" 2>/dev/null || true
  echo "counter: 不恢复服务（share=none 锁，sc start 失败，不手动 Start-Service），应恢复判据应红" >"$d/note.txt"
  local ca="$d/case-running"; mkdir -p "$ca"
  base="$(win_release_file "$UF_BASE_TAG" '*_x64-setup.exe')"
  cand="$(win_release_file "$UF_CAND_TAG" '*_x64-setup.exe')"
  # 先降回 base，让这次安装有版本变化（失败可判）。
  install_pkg "$base" "$d/base-install.txt" || true
  # 反证起点必须是真的 base：版本没到 base 或服务没起来，就无法构造「替换失败」的前置，立即停下。
  wait_daemon_file_version "$UF_BASE_VER" 90 || { echo "反证起点没建立：base 版本没就绪"; return 1; }
  ensure_running || { echo "反证起点没建立：base 服务没运行"; return 1; }
  record_state "$ca" pre
  win_lock_daemon running || { echo "反证锁文件失败"; return 1; }
  install_pkg "$cand" "$ca/install.txt" || true
  record_update_failed "$ca" after-fail
  record_state "$ca" after-fail
  capture_daemon_log "$ca" after-fail
  win_unlock_daemon running || echo "反证释放锁失败"
  # 关键：不手动 Start-Service。给 SCM failure recovery 一个「万一有重试」的窗口（实测不会来），
  # 再采样 after-recover，确认 daemon 仍是停的。
  sleep 5
  diag_inst "$ca" || true
  record_state "$ca" after-recover
  capture_daemon_log "$ca" after-recover
}

teardown() {
  # 先杀掉任何残留的独占进程，再保证机器回到候选版本 + 服务运行（起点就是候选）。
  win_kill_lingering_locks
  local cand
  cand="$(win_release_file "$UF_CAND_TAG" '*_x64-setup.exe')"
  if [ -n "$cand" ] && [ "$(inst_exe_version)" != "$UF_CAND_VER" ]; then
    install_pkg "$cand" "$EV/teardown-install.txt" || true
  fi
  ensure_running || true
  return 0
}
