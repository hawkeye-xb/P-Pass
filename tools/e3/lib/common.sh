# tools/e3 公共函数：本机配置、日志、证据目录、判定小工具。由 tools/e3/run source，场景不必再 source。
#
# 本机配置（设备序列号、隧道主机、端口……）不进仓库：按顺序读
#   1. 已有的环境变量；
#   2. ${E3_ENV:-$HOME/.config/ppass/e3.env}（KEY=VALUE，一行一个；本机 local-state.md 记它在哪）。
# 缺了必需项就报错退出并指向 local-state.md，不猜默认值。
# shellcheck shell=bash

E3_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$E3_ROOT/../.." && pwd)"
E3_LIB="$E3_ROOT/lib"

e3_env_file="${E3_ENV:-$HOME/.config/ppass/e3.env}"
if [ -f "$e3_env_file" ]; then
  # 只导入还没设的变量：命令行上给的永远优先。
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | \#*) continue ;; esac
    k="${line%%=*}"
    v="${line#*=}"
    [ -n "${!k+x}" ] || export "$k=$v"
  done <"$e3_env_file"
fi

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { printf 'E3 ERROR: %s\n' "$*" >&2; exit 2; }

# need_cfg <变量名> <说明>：缺本机配置时报错退出。
need_cfg() {
  [ -n "${!1:-}" ] && return 0
  die "缺本机配置 $1（$2）。写进 $e3_env_file 或导出环境变量；值见本机 local-state.md 的「E3 真机验证」段。"
}

# 运行期状态（桩、缓存）放仓库外；证据放仓库内 evidence/（gitignore）。
E3_STATE="${E3_STATE:-$HOME/.cache/ppass-e3}"
mkdir -p "$E3_STATE"

# 候选构建的桌面二进制：配对桩与扮手机的 testclient（just verify 负责编；也可用环境变量指定）
cand_daemon() { echo "${E3_DAEMON:-${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/daemon}"; }
cand_testclient() { echo "${E3_TESTCLIENT:-${CARGO_TARGET_DIR:-$REPO_ROOT/target}/debug/testclient}"; }

# —— 判定小工具（judge 里用；只读证据目录） ——
# 每个 judge 用 check 累加失败数，最后 verdict 收口。
E3_FAILS=0
check() { # check <描述> <命令…>：命令成功记 ok，否则记 FAIL
  local what="$1"
  shift
  if "$@"; then
    printf '  ok    %s\n' "$what"
  else
    printf '  FAIL  %s\n' "$what"
    E3_FAILS=$((E3_FAILS + 1))
  fi
}
# 文件里有/没有匹配正则的行
has_line() { [ -f "$1" ] && grep -Eq -- "$2" "$1"; }
no_line() { [ -f "$1" ] || return 0; ! grep -Eq -- "$2" "$1"; }
count_lines() { [ -f "$1" ] && grep -Ec -- "$2" "$1" || echo 0; }
# 文件内容（去首尾空白）等于给定值
eq_file() { [ -f "$1" ] && [ "$(tr -d '[:space:]' <"$1")" = "$2" ]; }
# 数值比较：num <文件> <op> <值>（op 是 test 的 -eq/-ge/-lt…）
num() { local v; v="$(tr -d '[:space:]' <"$1" 2>/dev/null)"; [ -n "$v" ] && [ "$v" "$2" "$3" ]; }
# json 字段：jget <文件> <python 表达式，j 是解析后的对象>
jget() { python3 -I -c 'import json,sys; j=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null; }
verdict() { [ "$E3_FAILS" -eq 0 ]; }

# 带超时跑命令（macOS 没有 timeout）
T() { perl -e 'alarm shift; exec @ARGV' "$@"; }
