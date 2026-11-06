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
#   （默认）        无害清单 = { docs/ .claude/ *.md tools/flow/ release/notes/ … }
#                   （完整清单见 is_inert）
#                   给「会读 apps/ 的门禁」用：ci-rust 的 arch，以及
#                   ci-desktop 的两条 job（它们就是编 apps/desktop 的）。
#                   **语义与本卡之前完全一致**，所以 ci-desktop.yml 不用改。
#
#   rust-workspace  无害清单 = 上面那些 ∪ { apps/** }
#                   给「只碰主 workspace 的门禁」用：clippy / test /
#                   test (windows) / license+deny / fmt。
#
# `apps/**` 能进第二个清单的依据（CI-17 逐条核实过，别凭印象改）：
#   - `apps/desktop/src-tauri` 是**刻意独立的 workspace**（壳 = UI + 托管，
#     ADR-012；单向依赖 crates/platform 与 crates/version-cmp），不在根
#     Cargo.toml 的 members 里 ⇒ `cargo nextest` / `clippy` / `cargo deny` /
#     `cargo fmt --all` 编译不到它；
#   - `grep -rn "apps/" crates/ --include="*.rs"`：`include_str!` / `fs::read` 指向
#     apps/ 的只有 #1066 的两个手机端常量文件与 #1467 的桌面 i18n 字典
#     （crates/diag/src/lib.rs），它们在 is_inert 里单独登记成「要跑」；
#   - `crates/daemon/build.rs` 只读 `PPF_BUILD_VERSION` 环境变量，不碰路径。
#   - ⚠️ 方向别看反：daemon 的 `--version --json`（`cli::VERSION_PRODUCT`）是
#     契约，src-tauri 的 `daemon_cli::DAEMON_PRODUCT` 消费它，那是**反向**依赖。
#     改 src-tauri 弄不红 daemon 的测试；反过来才会，
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
#   docs/ .claude/         没有任何 Rust 代码或门禁脚本读取它们
#                          （例外：docs/desktop/business-rules.zh-CN.md，见 is_inert）
#                          （core-index/src/ingest.rs 里有一句注释提到 docs
#                            路径，不是读取）
#   *.md                   任何位置的 markdown 都不参与编译
# 2026-11-06（#1467）按依赖面补进两个 lane 共用的清单：
#   tools/flow/ tools/e3/ tools/hooks/   流程、真机验收、本地钩子脚本
#   上述目录的自测 tools/test-{flow-*,acceptance-gate,ci-review,e3,local-hooks,release-acceptance}.sh
#   tools/ci-paths.sh 与其自测             只被 android/ios/docs/core-review lane 与流程脚本调用
#   release/notes/                         应用内更新说明（由 ci-docs 的 release/** 路径负责）
#   .github/ISSUE_TEMPLATE/                issue 模板
#   .coderabbit.yaml                       CodeRabbit 配置。构建、crates/、桌面壳都不读
#                                          （与 plan-builds 同一口径，#1545）
#   核实：git grep 这些路径于 crates/ apps/desktop/ config/ .github/actions/
#   ci-rust.yml ci-desktop.yml 无命中；arch-check.sh 写明 tools/** 不扫；
#   fitness 检查的 SCAN_ROOTS 只有 crates/ apps/ config/（tools/fitness_lib.py）。
#   兜底仍是「要跑」：判据脚本自身、tools/*.txt 登记表、fitness / arch 的脚本与自测、
#   setup-rust-toolchain.sh 等 gated job 调用的脚本都不在清单里。
#   tools/test-ci-needs-full-lane.sh 从源码派生反向用例：crates/ 里每个 include_str!/
#   include_bytes! 指向 crates/ 之外的目标，以及 ci-rust.yml、ci-desktop.yml 与其
#   composite action 里引用的 tools/ 脚本，两个 lane 都必须判「要跑」。
# ⚠️ 往这里加东西之前先问：有没有测试/构建脚本会读它？读了就不能加。
# ⚠️ assets/i18n/** 被 diag 的 keys 测试消费，**绝不能**加进来。
# 2026-11-06（#1504）：tools/ 下没在本清单登记的文件，不再一律判要跑，改由
#   tools_closure_inert 按引用闭包判（见该函数）；本清单是它的前置，结果只会更严不会更松。
static_inert() {
  case "$1" in
    # #1049 E2：桌面业务规则文档 §12 常量表被三处测试读取（daemon 与壳的
    # cargo 测试 include_str!、前端 vitest readFileSync），只改它也必须跑
    # 两条 lane，否则「改表不改代码」不会变红。必须排在 docs/* 之前。
    docs/desktop/business-rules.zh-CN.md) return 1 ;;
    # #1066：低空间线「三端同值」对账（crates/daemon/tests/flow_health.rs
    # `low_space_threshold_matches_both_phone_sources`）用 read_to_string 读这两个手机
    # 端源码文件。宽 lane 把 apps/** 当惰性，只改手机端常量时那条测试不会跑，三端
    # 不一致就能静默合入。必须排在 apps/* 之前；默认 lane 本来就会跑，这里对两个 lane
    # 都判「要跑」。新增「Rust 测试读取 apps/ 下某文件」时，同样要把该文件登记在这里。
    apps/android/app/src/main/java/com/hawkeyexb/ppass/backup/flow/FlowContract.kt) return 1 ;;
    apps/ios/Packages/PPassCore/Sources/PPassCore/Flow/FlowTypes.swift) return 1 ;;
    # #1467：crates/diag/src/lib.rs 用 include_str! 读桌面 i18n 字典做键对账，
    # 只改它时宽 lane 也必须跑（原先被 apps/* 静默跳过）。必须排在 apps/* 之前。
    apps/desktop/src/i18n/en.json | apps/desktop/src/i18n/zh.json) return 1 ;;
    docs/* | .claude/*) return 0 ;;
    *.md) return 0 ;;
    # #1467：流程与发布说明，两个 lane 都惰性（核实依据见上方清单注释）。
    tools/flow/* | tools/e3/* | tools/hooks/*) return 0 ;;
    tools/test-flow-*.sh | tools/test-acceptance-gate.sh | tools/test-ci-review.sh) return 0 ;;
    tools/test-e3.sh | tools/test-local-hooks.sh | tools/test-release-acceptance.sh) return 0 ;;
    tools/ci-paths.sh | tools/test-ci-paths.sh) return 0 ;;
    release/notes/*) return 0 ;;
    .github/ISSUE_TEMPLATE/*) return 0 ;;
    # #1545：只服务 CodeRabbit，不进安装包，Rust / 桌面门禁也不读。
    .coderabbit.yaml) return 0 ;;
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

# ── tools/ 的引用闭包（#1504）─────────────────────────────────────────────
# 问题：只改 tools/ 下一个跟 Rust 无关的脚本（如本地清理脚本），以前因为不在上面
# 清单里就判要跑，PR 被拖上 Rust 全量近一小时；逐个往清单里加又追不上新脚本。
#
# 做法：tools/ 下的文件只有被门禁 job 用到才影响结果，而「用到」必然写在某个文件里。
# 从改动文件出发，git grep 找提到它的文件（关键字取去掉扩展名的文件名，同时盖住
# 完整路径、`$(dirname "$0")/x.sh`、相对路径、Python 的 `from x import`），
# 引用方在 tools/ 下就接着往上追，直到闭包封口。引用方的分类**同样是 allowlist**：
#   - 自己、已追过的、判据脚本与其自测（它们提到别的路径只是数据；两者本身被
#     changes job 无条件执行，被改时按闭包照样判要跑）→ 跳过；
#   - 落在上面静态无害清单里（沿用当前 lane）→ 跳过；
#   - justfile（门禁 job 不调用 just，已核实 ci-rust.yml、ci-desktop.yml 与其 action
#     只在注释里提到 just）、ci-rust.yml / ci-desktop.yml 以外的 workflow → 跳过；
#   - tools/ 下的 → 入队继续追；
#   - 其余一律判要跑（门禁 workflow 与其 action、crates/、apps/desktop、Cargo.*、
#     build.rs、config/、不认识的路径……）。
# 判不了的一律判要跑：取不到仓库根、改动文件在 HEAD 已不存在（改名/删除的旧路径，
# 引用方可能正因此坏掉）、git grep 出错（退出码 ≥2；1 只表示没命中）、闭包超过上限、
# 门禁 workflow 或其 action 用 tools/ 加通配符或变量拼路径（引用不写名字，追不到）。
GATED_WORKFLOWS=".github/workflows/ci-rust.yml .github/workflows/ci-desktop.yml"
CLOSURE_MAX=300
ROOT=""
DYN_CHECKED=""

# 门禁 workflow 及其 composite action 里有没有追不到的动态 tools/ 引用。
# 有、或读不到这些文件 → 返回 0（判不了）。
gated_has_dynamic_tools_ref() {
  local wf_files w a actions
  wf_files=()
  for w in $GATED_WORKFLOWS; do
    if [ ! -f "$w" ]; then
      say "门禁 workflow「${w}」不存在 → 判不了引用闭包"
      return 0
    fi
    wf_files+=("$w")
  done
  actions="$(grep -hoE 'uses: \./\.github/actions/[A-Za-z0-9_-]+' "${wf_files[@]}" | sed 's#uses: \./##' | sort -u)"
  for a in $actions; do
    if [ ! -f "$a/action.yml" ]; then
      say "门禁用到的 action「${a}」读不到 → 判不了引用闭包"
      return 0
    fi
    wf_files+=("$a/action.yml")
  done
  if grep -nE 'tools/[A-Za-z0-9_./-]*[*$]' "${wf_files[@]}" >&2; then
    say "门禁 workflow / action 用通配符或变量拼 tools/ 路径（见上）→ 引用追不全"
    return 0
  fi
  false
}

tools_closure_inert() {
  local f="$1" i cur base stem refs rc r seen NL
  NL='
'
  if [ -z "$ROOT" ]; then
    if ! ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || [ -z "$ROOT" ] || ! cd "$ROOT"; then
      ROOT=""
      say "取不到仓库根 → 判不了「${f}」的引用闭包"
      return 1
    fi
  fi
  if [ -z "$DYN_CHECKED" ]; then
    if gated_has_dynamic_tools_ref; then DYN_CHECKED=dynamic; else DYN_CHECKED=ok; fi
  fi
  if [ "$DYN_CHECKED" != ok ]; then
    return 1
  fi
  if [ ! -e "$f" ]; then
    say "「${f}」在 HEAD 不存在（改名或删除）→ 引用方可能正因此坏掉"
    return 1
  fi
  local queue=("$f")
  seen="$NL$f$NL"
  i=0
  while [ "$i" -lt "${#queue[@]}" ]; do
    cur="${queue[$i]}"
    i=$((i + 1))
    if [ "$i" -gt "$CLOSURE_MAX" ]; then
      say "「${f}」的引用闭包超过 ${CLOSURE_MAX} 个文件 → 不再追"
      return 1
    fi
    base="${cur##*/}"
    stem="${base%.*}"
    [ -n "$stem" ] || stem="$base"
    refs="$(git -c core.quotepath=off grep -lF -e "$stem" -- 2>/dev/null)"
    rc=$?
    if [ "$rc" -gt 1 ]; then
      say "git grep「${stem}」出错（退出码 ${rc}）→ 判不了「${f}」"
      return 1
    fi
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      case "$seen" in *"$NL$r$NL"*) continue ;; esac
      case "$r" in
        tools/ci-needs-full-lane.sh | tools/test-ci-needs-full-lane.sh) continue ;;
      esac
      static_inert "$r" && continue
      case "$r" in
        justfile) continue ;;
        .github/workflows/ci-rust.yml | .github/workflows/ci-desktop.yml) ;;
        .github/workflows/*) continue ;;
        tools/*)
          seen="$seen$r$NL"
          queue+=("$r") # 闭包追溯：引用方在 tools/ 下就接着往上追
          continue
          ;;
      esac
      if [ "$cur" = "$f" ]; then
        say "「${f}」被「${r}」引用（门禁会用到或不认识）→ 要跑"
      else
        say "「${f}」经「${cur}」被「${r}」引用（门禁会用到或不认识）→ 要跑"
      fi
      return 1
    done <<EOF
$refs
EOF
  done
  say "「${f}」的引用闭包（${#queue[@]} 个 tools/ 文件）里没有门禁入口 → 惰性"
}

is_inert() {
  static_inert "$1" && return 0
  case "$1" in
    tools/*) tools_closure_inert "$1" ;;
    *) false ;;
  esac
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
  # --no-renames：改名时旧路径也要参与判定。默认的改名检测只列新路径，把 gated job
  # 调用的脚本挪进惰性目录（如 tools/setup-rust-toolchain.sh → tools/flow/）就会被判可跳。
  git diff --no-renames --name-only "$base...HEAD" 2>/dev/null
}

main() {
  # 第二个位置参数是 lane。**未知 lane 一律判要跑**（fail-closed）——
  # 打错一个字母就静默套用更宽的清单，正是本脚本存在的意义所要防的那件事。
  LANE="${2:-default}"
  case "$LANE" in
    default | rust-workspace) : ;;
    *)
      say "未知 lane「${LANE}」→ 不猜，保守判定：要跑"
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
      say "「${f}」不在无害清单里（lane=${LANE}）→ 要跑"
      printf 'true\n'
      return 0
    fi
  done <<EOF
$files
EOF

  say "全部改动都落在无害清单里（lane=${LANE}）→ 可跳过"
  printf 'false\n'
  return 0
}

main "$@"
