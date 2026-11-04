# 共享编译缓存（#1375）：主副本与所有卡目录共用一份 Rust target 与 Xcode DerivedData，卡目录只放源码。
#
# 唯一来源是环境变量 CARGO_TARGET_DIR（仓库里的脚本都按 ${CARGO_TARGET_DIR:-target} 找产物；
# 不用 .cargo/config.toml 的 target-dir，否则 cargo 写共享目录、脚本还去 ./target 找，拿到旧二进制）。
# 变量写在主副本旁边的 .env.ppass-dev（与主副本同级，例如 ~/personal/ppass/.env.ppass-dev）：
# justfile 的 dotenv-load 会从工作目录往上找到它，主副本与默认位置的卡目录（<主副本>-wt/*）自动带上；
# 卡目录不在主副本旁边时，just start 把它拷进卡目录根（文件名命中 .gitignore 的 .env.*）。
# CI 与没跑过 just start 的机器上没有这个文件，行为不变。直接跑 cargo（不经 just）不读它：
# 先 `set -a; . <文件>; set +a`。Gradle 的依赖缓存本来就在 ~/.gradle，各目录共享，不挪。
# shellcheck shell=bash

DEV_CACHE_ENV_NAME=.env.ppass-dev

# 主副本根：git 公共目录的上一级（在卡目录里跑也指向主副本）。
dev_cache_main_root() {
  local common
  common="$(git -C "${1:-$PWD}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  dirname "$common"
}

# 放缓存与 env 文件的父目录：主副本的上一级。测试用 PPASS_DEV_CACHE_PARENT 覆盖。
dev_cache_parent() {
  if [ -n "${PPASS_DEV_CACHE_PARENT:-}" ]; then
    printf '%s' "$PPASS_DEV_CACHE_PARENT"
  else
    local main
    main="$(dev_cache_main_root "${1:-$PWD}")" || return 1
    dirname "$main"
  fi
}

dev_cache_env_file() { printf '%s/%s' "$(dev_cache_parent "${1:-$PWD}")" "$DEV_CACHE_ENV_NAME"; }
dev_cache_root() { printf '%s/P-Pass-cache' "$(dev_cache_parent "${1:-$PWD}")"; }

# dev_cache_init [目录]：没有 env 文件就写一份（已有就不动，人改过的值优先），打印文件路径。
dev_cache_init() {
  local f root
  f="$(dev_cache_env_file "${1:-$PWD}")" || return 1
  root="$(dev_cache_root "${1:-$PWD}")"
  mkdir -p "$root/cargo-target" "$root/ios-derived" || return 1
  if [ ! -f "$f" ]; then
    cat >"$f" <<EOF
# 共享编译缓存（P-Pass #1375，tools/e3/lib/dev-cache.sh 生成）。just 自动读；直接跑 cargo 先 set -a; . 本文件; set +a
CARGO_TARGET_DIR=$root/cargo-target
PPASS_IOS_DERIVED_DATA=$root/ios-derived
EOF
  fi
  printf '%s' "$f"
}

# dev_cache_value <键> [目录]：从 env 文件读一个值（没有文件或没有键就空）。
dev_cache_value() {
  local f
  f="$(dev_cache_env_file "${2:-$PWD}")" || return 0
  [ -f "$f" ] || return 0
  sed -n "s/^$1=//p" "$f" | tail -1
}

# dev_cache_covers <卡目录> [主副本]：卡目录往上能找到 env 文件（just 的 dotenv 查找规则）就成功。
dev_cache_covers() {
  local d="$1" name="$DEV_CACHE_ENV_NAME"
  while :; do
    [ -f "$d/$name" ] && return 0
    [ "$d" = / ] || [ -z "$d" ] && return 1
    d="$(dirname "$d")"
  done
}
