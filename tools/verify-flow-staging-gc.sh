#!/usr/bin/env bash
# NET-21 手动验证脚本：确认 flow-staging 孤儿回收真的在工作，不会造成
# 磁盘泄漏。
#
# 用法：
#   tools/verify-flow-staging-gc.sh [--dry-run] [--library-root <path>]
#
# 不带参数时默认对准真实库目录
# (~/Library/Application Support/P-Pass)，只读检查当前状态；
# --dry-run 额外在一个隔离的临时目录里模拟"孤儿产生 -> 回收"全流程，
# 不碰你的真实照片库/daemon 进程。
#
# 退出码：0 = 一切正常；非 0 = 发现问题（脚本会打印具体是什么）。

set -euo pipefail

DEFAULT_ROOT="$HOME/Library/Application Support/P-Pass"
LIBRARY_ROOT="$DEFAULT_ROOT"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --library-root) LIBRARY_ROOT="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

STAGING="$LIBRARY_ROOT/.ppf/flow-staging"
GRACE_SECS=3600  # 与 daemon 里的 STAGING_ORPHAN_GRACE 保持同一个数

log() { printf '%s\n' "$*"; }

# ── 只读检查：真实库当前的 flow-staging 状态 ──────────────────────
inspect_real_library() {
  log "== 检查真实库: $LIBRARY_ROOT =="
  if [[ ! -d "$STAGING" ]]; then
    log "flow-staging 目录不存在（daemon 从未跑过 Flow 交付，或刚清空过）——正常。"
    return 0
  fi

  local total_bytes total_files
  total_files=$(find "$STAGING" -type f | wc -l | tr -d ' ')
  total_bytes=$(du -sk "$STAGING" 2>/dev/null | awk '{print $1 * 1024}')
  log "flow-staging 里现有 $total_files 个文件，共 ${total_bytes:-0} 字节。"

  if [[ "$total_files" -eq 0 ]]; then
    log "✅ 空目录，没有泄漏。"
    return 0
  fi

  # 命名契约: {node_hex}-{queue_sequence}-{content_hash_hex}
  # 落地超过 grace（默认 1 小时）却还在的文件，理论上下一次巡检
  # （daemon 每小时跑一次，或下次启动）就该被清走——除非它对应的
  # Flow grant 仍是 active（真的还在传，不是泄漏）。
  local now old_count
  now=$(date +%s)
  old_count=0
  while IFS= read -r -d '' f; do
    local mtime age name
    mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null)
    age=$(( now - mtime ))
    name=$(basename "$f")
    if [[ "$age" -ge "$GRACE_SECS" ]]; then
      old_count=$((old_count + 1))
      log "  ⚠️  $name 已落地 ${age}s（超过 ${GRACE_SECS}s 宽限期），下次巡检应被回收。"
    fi
  done < <(find "$STAGING" -type f -print0)

  if [[ "$old_count" -eq 0 ]]; then
    log "✅ 现存文件都在宽限期内，不算孤儿（可能是正在传输/刚落地）。"
  else
    log "发现 $old_count 个超过宽限期的文件。用下面两种办法之一确认它们是不是真孤儿："
    log "  1) 看 daemon 日志有没有 'NET-20: 回收 flow-staging 孤儿'——'"
    log "     数字' 这一行（启动时 + 每小时一次）；出现即证明本轮扫过、"
    log "     这批文件之所以还在是因为命中了保护集（真的在传）或刚跑完"
    log "     还没到下一个整点。"
    log "  2) 重启一次 daemon（会立刻触发启动扫描）后重跑本脚本，数字"
    log "     应该降为 0 或明显减少；仍然纹丝不动才是真正需要报告的问题。"
  fi
}

# ── 隔离沙盒：真实模拟"产生孤儿 -> 巡检回收"整个链路 ────────────
dry_run_simulation() {
  sandbox=$(mktemp -d /tmp/net21-verify.XXXXXX)
  trap 'rm -rf "$sandbox"' EXIT
  log "== 沙盒模拟（不影响真实库）: $sandbox =="

  local staging="$sandbox/.ppf/flow-staging"
  mkdir -p "$staging"

  # 三个文件：
  #   1) 孤儿——落地已久，没有任何 grant 认领 -> 该被回收
  #   2) 有主——文件名里的 hash 在"保护集"里 -> 不该被碰
  #   3) 刚落地——没人认领但还在宽限期内 -> 现在不该被碰
  local orphan_hash claimed_hash fresh_hash
  orphan_hash=$(printf 'orphan' | shasum -a 256 | cut -c1-64)
  claimed_hash=$(printf 'claimed' | shasum -a 256 | cut -c1-64)
  fresh_hash=$(printf 'fresh' | shasum -a 256 | cut -c1-64)

  echo "orphan payload" > "$staging/deadbeef-1-$orphan_hash"
  echo "claimed payload" > "$staging/deadbeef-2-$claimed_hash"
  echo "fresh payload" > "$staging/deadbeef-3-$fresh_hash"

  # 把"孤儿"和"有主"两个文件的 mtime 拨回 2 小时前，让它们越过宽限期；
  # "刚落地"的保持当前时间。
  local two_hours_ago
  two_hours_ago=$(date -v-2H +%Y%m%d%H%M.%S 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M.%S)
  touch -t "$two_hours_ago" "$staging/deadbeef-1-$orphan_hash"
  touch -t "$two_hours_ago" "$staging/deadbeef-2-$claimed_hash"

  log "落地前: $(find "$staging" -type f | wc -l | tr -d ' ') 个文件"

  # 直接调生产回收函数本身，而不是重新发明判据——用一个一次性小 Rust
  # 程序跑真实的 sweep_flow_staging_orphans，保护集只含 claimed_hash。
  local runner="$sandbox/runner"
  mkdir -p "$runner/src"
  cat > "$runner/Cargo.toml" <<EOF
[package]
name = "net21-verify-runner"
version = "0.0.0"
edition = "2021"

[dependencies]
daemon = { path = "$PWD/crates/daemon" }
hex = "0.4"
EOF
  cat > "$runner/src/main.rs" <<EOF
use std::collections::HashSet;
use std::path::Path;
use std::time::Duration;

fn main() {
    let staging = Path::new(std::env::args().nth(1).unwrap().as_str()).to_path_buf();
    let mut protected: HashSet<[u8; 32]> = HashSet::new();
    let claimed = hex::decode(std::env::args().nth(2).unwrap()).unwrap();
    protected.insert(claimed.try_into().unwrap());
    let freed = daemon::sweep_flow_staging_orphans(&staging, &protected, Duration::from_secs($GRACE_SECS));
    println!("freed={freed}");
}
EOF
  (cd "$runner" && cargo run --quiet -- "$staging" "$claimed_hash" 2>/dev/null)

  log "回收后: $(find "$staging" -type f | wc -l | tr -d ' ') 个文件"
  local ok=1
  if [[ -f "$staging/deadbeef-1-$orphan_hash" ]]; then
    log "❌ 孤儿文件没有被回收——回收逻辑失效！"
    ok=0
  else
    log "✅ 孤儿文件（无主+过宽限期）已被回收。"
  fi
  if [[ ! -f "$staging/deadbeef-2-$claimed_hash" ]]; then
    log "❌ 有主文件被误删——这是数据丢失级别的问题！"
    ok=0
  else
    log "✅ 有主文件（保护集命中）未被触碰。"
  fi
  if [[ ! -f "$staging/deadbeef-3-$fresh_hash" ]]; then
    log "❌ 刚落地文件被误删——宽限期保护失效！"
    ok=0
  else
    log "✅ 刚落地文件（未过宽限期）未被触碰。"
  fi

  if [[ "$ok" -eq 1 ]]; then
    log ""
    log "✅ 沙盒模拟全部通过：回收只清没主+过期的文件，有主/刚落地的都保留。"
  else
    log ""
    log "❌ 沙盒模拟发现问题，见上面的 ❌ 行。"
    exit 1
  fi
}

inspect_real_library
if [[ "$DRY_RUN" -eq 1 ]]; then
  log ""
  dry_run_simulation
fi
