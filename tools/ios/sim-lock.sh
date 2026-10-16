# shellcheck shell=bash
# 共用模拟器的互斥锁：由 tools/ios/test.sh 与 tools/ios/test-packages.sh source。
#
# 为什么要锁：两个脚本都用 sim.sh 选出的同一台模拟器，并在结束时关掉自己启动的那台。
# 本机多个会话同时跑测试时，先跑完的一方会把模拟器关掉，后跑的一方被打断（2026-10-16 实测撞车）。
# 锁让同一台模拟器上的测试排队执行；持锁进程已退出时视为过期锁，直接接管。
#
# 用法：sim_lock_acquire；退出时调用 sim_lock_release（放进调用方的 EXIT trap）。
SIM_LOCK_DIR="${TMPDIR:-/tmp}/ppass-ios-sim.lock"

sim_lock_acquire() {
  local waited=0 holder
  while ! mkdir "$SIM_LOCK_DIR" 2>/dev/null; do
    holder=$(cat "$SIM_LOCK_DIR/pid" 2>/dev/null || true)
    if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
      echo "模拟器锁的持有进程 ${holder} 已退出，接管过期锁"
      rm -rf "$SIM_LOCK_DIR"
      continue
    fi
    if [ $((waited % 30)) -eq 0 ]; then
      echo "模拟器正被进程 ${holder:-?} 使用，排队等待（已等 ${waited} 秒）"
    fi
    sleep 2
    waited=$((waited + 2))
  done
  echo $$ >"$SIM_LOCK_DIR/pid"
}

sim_lock_release() {
  if [ "$(cat "$SIM_LOCK_DIR/pid" 2>/dev/null || true)" = "$$" ]; then
    rm -rf "$SIM_LOCK_DIR"
  fi
}
