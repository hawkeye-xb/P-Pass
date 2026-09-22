#!/usr/bin/env bash
# CI-11 (#255): 判定一次改动要不要跑「重型门禁」（Rust 全量 / 桌面壳）。
#
# ## 为什么需要它
#
# `ci-rust` 与 `ci-desktop` 的 `pull_request` **刻意不设 paths**（CI-07 #189）：
# 它们的检查在 `main` 的必需列表里，而被 `paths` 跳过的 workflow **根本不汇报
# 状态**，必需检查会永久 Pending 把 PR 挡死。代价是纯文档 PR 也会整条跑。
#
# 出路是把「要不要干活」从 workflow 触发层下放到 **job 层**：被 `if:` 跳过的
# job **会汇报 `skipped`，而 `skipped` 对必需检查算通过**（PR #260 实测：
# 给必需检查 `architecture enforcement` 加 `if: false`，PR 仍然 CLEAN）。
#
# ## 口径：allowlist，不是 blocklist —— 这是本脚本的全部要害
#
# 朴素写法是「改了 crates/ 才跑」。那是 **fail-open**：漏一个路径 = 静默放行，
# 而且报绿。本仓这一轮修的缺陷（#189 的 paths 错位、#192 的 python3 假成功）
# 全是这个形状。
#
# 这里**反过来**：**只有当每一个改动文件都落在无害清单里，才判「可跳过」。**
# 漏一个路径 = 多跑一次（浪费几分钟），**错误方向是 fail-closed**。
#
# ## 两个 lane（CI-17 #373）
#
# 原先只有**一个**判定，`ci-rust` 下游 6 个 job 共用它 —— 要么全跑要么全跳。
# 后果：一个只改 `apps/**` 的 PR，为了留住**真的需要跑**的
# `architecture enforcement`（`tools/arch-check.sh` 明写 `apps/** — scanned`），
# 顺带拖上整条主 workspace 的重型编译。PR #370 实测 7 秒 vs 12 分 19 秒。
#
# 所以判定按**依赖面**分成两个 lane，各自独立算、各自保持 allowlist 反向写法：
#
#   （默认）        无害清单 = { docs/ cards/ .claude/ *.md }
#                   给「会读 apps/ 的门禁」用：ci-rust 的 arch，以及
#                   ci-desktop 的两条 job（它们就是编 apps/desktop 的）。
#                   **语义与本卡之前完全一致**，所以 ci-desktop.yml 不用改。
#
#   rust-workspace  无害清单 = 上面那些 ∪ { apps/** }
#                   给「只碰主 workspace 的门禁」用：clippy / test /
#                   test (windows) / license+deny / fmt。
#
# `apps/**` 能进第二个清单的依据（CI-17 逐条核实过，别凭印象改）：
#   - `apps/desktop/src-tauri` 是**刻意独立的 workspace**（其 Cargo.toml 头部
#     注释：ZERO business logic / depends on no internal crate），不在根
#     Cargo.toml 的 members 里 ⇒ `cargo nextest` / `clippy` / `cargo deny` /
#     `cargo fmt --all` 编译不到它；
#   - `grep -rn "apps/" crates/ --include="*.rs"` 的命中**全是注释**，
#     `include_str!` / `fs::read` / `File::open` 指向 apps/ 的**一条都没有**；
#   - `crates/daemon/build.rs` 只读 `PPF_BUILD_VERSION` 环境变量，不碰路径。
#   - ⚠️ 方向别看反：`crates/daemon/tests/cli_flow.rs` 提到 src-tauri 的
#     `DAEMON_VERSION_MARKER`，那是**反向**依赖（daemon 的 `--version` 是契约，
#     src-tauri 消费它）。改 src-tauri 弄不红 daemon 的测试；反过来才会，
#     而那种改动落在 `crates/**`，本来就判跑。
#   - ⚠️ `apps/` 里的 Rust **仍然被检查**，只是不由本 lane 检查：src-tauri 的
#     fmt/clippy/test 由 `ci-desktop` 在它自己的 workspace 里跑。
#
# ## 用法
#   tools/ci-needs-full-lane.sh <base-sha>                  # 默认 lane
#   tools/ci-needs-full-lane.sh <base-sha> rust-workspace   # 宽 lane
#   cat filelist | tools/ci-needs-full-lane.sh -                  # stdin（测试用）
#   cat filelist | tools/ci-needs-full-lane.sh - rust-workspace   # stdin + 宽 lane
#
# stdout 恒为一行 `true` / `false`（true = 要跑）。理由写 stderr。
# **退出码恒为 0** —— 判定本身不该让调用方失败；任何异常都走「判 true」。
# **lane 名字打错也走「判 true」** —— 不许把未知 lane 静默当成宽清单。

set -uo pipefail

# ── 无害清单 ───────────────────────────────────────────────────────────
# 每一条都必须先证明它对 Rust / 桌面壳 lane 是惰性的，再往里加。
# 2026-09-20 的核实依据（grep 全仓 .rs 与 tools/arch-check.sh）：
#   docs/ cards/ .claude/  没有任何 Rust 代码或门禁脚本读取它们
#                          （唯一命中是 core-index/src/ingest.rs:182 的一句
#                            注释里提到 docs 路径，不是读取）
#   *.md                   任何位置的 markdown 都不参与编译
# ⚠️ 往这里加东西之前先问：有没有测试/构建脚本会读它？读了就不能加。
# ⚠️ assets/i18n/** 被 diag 的 keys 测试消费，**绝不能**加进来。
is_inert() {
  case "$1" in
    docs/* | cards/* | .claude/*) return 0 ;;
    *.md) return 0 ;;
  esac
  # 宽 lane 额外把 apps/** 也算惰性。依据见文件头「两个 lane」那段 ——
  # 往这里加东西之前先证明它对**该 lane 的每一条 job** 都是惰性的。
  if [ "$LANE" = "rust-workspace" ]; then
    case "$1" in
      apps/*) return 0 ;;
    esac
  fi
  return 1
}

say() { printf '%s\n' "$*" >&2; }

list_changed_files() {
  if [ "${1:-}" = "-" ]; then
    cat
    return 0
  fi
  base="${1:-}"
  if [ -z "$base" ]; then
    return 1
  fi
  git diff --name-only "$base...HEAD" 2>/dev/null
}

main() {
  # 第二个位置参数是 lane。**未知 lane 一律判要跑**（fail-closed）——
  # 打错一个字母就静默套用更宽的清单，正是本脚本存在的意义所要防的那件事。
  LANE="${2:-default}"
  case "$LANE" in
    default | rust-workspace) : ;;
    *)
      say "未知 lane「$LANE」→ 不猜，保守判定：要跑"
      printf 'true
'
      return 0
      ;;
  esac

  # ${1:-} 而不是 "$1" —— set -u 下无参数时 "$1" 会当场 unbound variable，
  # 而「没给 base」必须走下面的「判 true」，不是让脚本崩掉。
  if ! files="$(list_changed_files "${1:-}")"; then
    say "取不到改动文件列表（没给 base，或 git diff 失败）→ 保守判定：要跑"
    printf 'true\n'
    return 0
  fi

  # 空列表说明我们没搞清楚发生了什么（浅 clone / force push / base 变了），
  # 不是「什么都没改」。一律判要跑。
  case "$files" in
    *[![:space:]]*) : ;;
    *)
      say "改动文件列表为空 → 说明没搞清状况，保守判定：要跑"
      printf 'true\n'
      return 0
      ;;
  esac

  # 用 here-string 而不是管道：管道会开子 shell，里面的 return 出不来
  # （tools/clean-local-builds.sh 在 DEV-04 #192 栽过同一个跟头）。
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if ! is_inert "$f"; then
      say "「$f」不在无害清单里（lane=$LANE）→ 要跑"
      printf 'true\n'
      return 0
    fi
  done <<EOF
$files
EOF

  say "全部改动都落在无害清单里（lane=$LANE）→ 可跳过"
  printf 'false\n'
  return 0
}

main "$@"
