#!/usr/bin/env bash
# worker 流程三条命令（start / done / stuck）共用的函数。只被 source，不直接运行。
# 说明见 AGENTS.md「交付流程」。gh 调用都集中在这里，测试用假 gh 桩替换。

# 「已采纳」方案解析（adopted_adrs）与 owner 共用一份。
# shellcheck source=decision-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/decision-lib.sh"

# 仓库（owner/repo）：PPASS_HOOK_REPO 优先，否则从 origin URL 解析（与 tools/hooks/pre-commit 同口径）。
flow_repo() {
  local r="${PPASS_HOOK_REPO:-}"
  if [ -z "$r" ]; then
    r="$(git config --get remote.origin.url 2>/dev/null |
      sed -E -e 's#/+$##' -e 's#\.git$##' -e 's#^.*[:/]([^/:]+/[^/:]+)$#\1#')"
  fi
  [[ "$r" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || die "解析不出 GitHub 仓库（origin URL 不认识）；设 PPASS_HOOK_REPO=<owner>/<repo>"
  printf '%s' "$r"
}

die() {
  printf '\n✗ %s\n' "$1" >&2
  shift
  local l
  for l in "$@"; do printf '    %s\n' "$l" >&2; done
  printf '\n' >&2
  exit 1
}

# 把本机路径（家目录）从要贴进公开 issue 的文本里抹掉。
scrub() { sed -e "s#${HOME}#~#g"; }

# 主仓工作区根（不论当前在哪个 worktree 里）。
flow_main_root() {
  local c
  c="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)" || return 1
  dirname "$c"
}

# 卡 worktree 的父目录：<主仓>-wt（P-Pass → P-Pass-wt），可用 PPASS_WT_ROOT 覆盖。
flow_wt_root() {
  if [ -n "${PPASS_WT_ROOT:-}" ]; then
    printf '%s' "$PPASS_WT_ROOT"
  else
    printf '%s-wt' "$(flow_main_root)"
  fi
}

# 读 issue：设置 I_STATE I_TITLE I_LABELS（逗号分隔）I_BODY。读不到就 die。
flow_load_issue() { # flow_load_issue <号>
  local out
  out="$(gh issue view "$1" -R "$REPO" --json state,title,labels,body \
    --jq '"state:" + .state, "title:" + .title, "labels:" + ([.labels[].name] | join(",")), "body:", .body' 2>&1)" ||
    die "读取 ${REPO}#$1 失败（离线、没登录或 issue 不存在）" "gh 输出：$(printf '%s' "$out" | head -3 | tr '\n' ' ')"
  out="$(printf '%s\n' "$out" | tr -d '\r')"
  I_STATE="$(printf '%s\n' "$out" | sed -n '1s/^state://p')"
  I_TITLE="$(printf '%s\n' "$out" | sed -n '2s/^title://p')"
  I_LABELS="$(printf '%s\n' "$out" | sed -n '3s/^labels://p')"
  I_BODY="$(printf '%s\n' "$out" | sed '1,4d')"
}

has_label() { case ",${I_LABELS}," in *",$1,"*) return 0 ;; esac; return 1; }

# 「范围」代码块解析：与 tools/hooks/pre-commit 里那段 awk 逐字相同
# （tools/test-flow-worker.sh 会比对两边，漂移即红）。结果放进 GLOBS 数组。
flow_parse_scope() { # flow_parse_scope <issue 正文>
  local scope g
  scope="$(printf '%s\n' "$1" | awk '
  !insec && /^\*\*范围/ { insec = 1; next }
  insec && !infence && /^[[:space:]]*```/ { infence = 1; found = 1; next }
  infence && /^[[:space:]]*```/ { exit }
  infence { print; next }
  insec && (/^\*\*[^*]+\*\*/ || /^#/) { exit }
')"
  GLOBS=()
  while IFS= read -r g; do
    g="$(printf '%s' "$g" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$g" in "" | "#"*) continue ;; esac
    g="${g#./}"
    case "$g" in */) g="${g}**" ;; esac
    GLOBS+=("$g")
  done <<EOF2
$scope
EOF2
}

# 取任务卡正文里 **<字段名>**：的值（到下一个 **字段 或 # 标题为止），去掉 HTML 注释与空行。
flow_field_text() { # flow_field_text <正文> <字段名>
  printf '%s\n' "$1" | awk -v f="$2" '
    index($0, "**" f "**") == 1 { grab = 1; sub(/^[^:：]*[：:]?[[:space:]]*/, ""); }
    grab && /^<!--/ { incomment = 1; if ($0 ~ /-->/) incomment = 0; next }
    grab && incomment { if ($0 ~ /-->/) incomment = 0; next }
    grab && /^[[:space:]]*$/ { next }
    grab && /^\*\*[^*]+\*\*/ { exit }
    grab && /^#/ { exit }
    grab { print }
  ' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | grep -v '^$'
}

# 一个文件是否在 GLOBS 里（用 tools/ci-paths.sh hit，与 hook 同一套 glob 语义）。
flow_in_scope() { # flow_in_scope <文件>
  [ "$(printf '%s\n' "$1" | bash "$FLOW_PATHS" hit - "${GLOBS[@]}" 2>/dev/null)" = "true" ]
}

# 改标签，失败返回非 0、不退出：多卡一次处理时，一张失败不能把其余卡撂下。
flow_try_labels() { # flow_try_labels <号> <加> <减>（任一可空，逗号分隔）
  local n="$1" add="$2" del="$3" args=()
  [ -z "$add" ] || args+=(--add-label "$add")
  [ -z "$del" ] || args+=(--remove-label "$del")
  [ "${#args[@]}" -gt 0 ] || return 0
  gh issue edit "$n" -R "$REPO" "${args[@]}" >/dev/null 2>&1
}

# 改标签：flow_labels <号> <加> <减>（任一可空，逗号分隔）。失败就 die。
flow_labels() {
  local n="$1" add="${2:-}" del="${3:-}" hint=""
  [ -z "$add" ] || hint="${hint} --add-label ${add}"
  [ -z "$del" ] || hint="${hint} --remove-label ${del}"
  flow_try_labels "$n" "$add" "$del" ||
    die "改 #$n 的标签失败（加：${add:-无}；减：${del:-无}）" "手动：gh issue edit $n -R $REPO${hint}"
}

flow_ensure_review_label() {
  gh label create "status:review" -R "$REPO" \
    -d "已交卡，等 PR 的 CI 与放行" -c "5319e7" >/dev/null 2>&1 || true
}

# 贴评论。失败返回非 0（多卡一次处理时由调用方点名是哪张卡）；内容留在文件里，可手动贴。
flow_comment() { # flow_comment <号> <正文文件>
  gh issue comment "$1" -R "$REPO" --body-file "$2" >/dev/null 2>&1 ||
    { printf '⚠ 往 #%s 贴评论失败（离线？）：内容见 %s\n' "$1" "$2" >&2; return 1; }
}

# ── 门禁挑选（#1651）：worker-done 按改动的文件挑、worker-start 按卡的「范围」挑，共用这一份 ──
# 两边共用是为了让「领卡时预检的门禁」就是「交卡时会跑的门禁」，挑选口径不许分叉。
# 口径（本地只跑改动涉及的检查；全量 just ci 是 PR 上 CI 的事，不在本地重复跑）：
#   纯文档（docs/**、*.md、release/notes/**；AGENTS.md 与 .github/** 例外——流程文件仍走 just ci-docs）
#                              → just md-check（#1750：文档检查与工具自测分层。纯文本卡不再串行整套
#                                flow-tests——Windows 实测约 58 分钟；identity / supply-chain 等不再本地预跑的
#                                检查由 PR 上远端 CI 兜底，远端 CI Docs lane 与 flow-tests job 各按自己的
#                                路径过滤跑，不会因本地变窄而漏跑）
#   apps/android/**            → just android-test
#   apps/ios/**、tools/ios/**  → just ios-test
#   assets/i18n/**、strings*.xml → just mobile-static-check
#   iOS 文案（apps/ios/**/*.strings、*.xcstrings、assets/i18n/**）→ 另加 just ios-test --lang en 与 --lang zh
#     （本机模拟器多是中文、CI 是英文：写死某一种语言的断言只在另一种语言下红，#1342）
#   crates/<名>/**             → cargo nextest run -p <包名> + cargo fmt --all -- --check + cargo clippy（与 justfile 的 lint 一致、不带 --all-features，#1646/#1669）
#   apps/desktop/src/**        → pnpm -C apps/desktop test（桌面前端 vitest）
#   apps/desktop/src-tauri/**  → cargo nextest run -p p-pass-desktop + fmt + clippy（独立 workspace，用 --manifest-path；与 desktop-checks 对齐，#1646）
#   tools/e3/**（非测试脚本）   → bash tools/test-e3.sh（e3 工具链自测；场景脚本是 glob 引用、字面 grep 不到，#1650）
#   tools/<文件>               → 改动里的 tools/test-*.sh 本身 + 引用到它的 tools/test-*.sh（git grep 找）
#   .github/workflows/*        → actionlint + just ci-docs（相关 tools/test-ci-*.sh 由 ci-docs 与 tools 规则覆盖）
#   justfile、.github/ISSUE_TEMPLATE/*、.github/PULL_REQUEST_TEMPLATE.md、.coderabbit.yaml → just ci-docs
#   其余（apps/desktop 下上面两条之外的其它文件、其它 .github、没有任何测试引用的 tools 文件…）任何一个挑不出来 → just ci（fail-closed）
flow_gate_add() { # 去重追加
  local g
  for g in ${GATES[@]+"${GATES[@]}"}; do [ "$g" = "$1" ] && return 0; done
  GATES+=("$1")
}
flow_gate_tool_tests() { # flow_gate_tool_tests <tools/下的文件>：打印要跑的测试，一行一个；没有就什么也不打印
  local f="$1" base dir
  case "$f" in
    tools/test-*.sh)
      [ -f "$f" ] && printf '%s\n' "$f"
      return 0
      ;;
    tools/e3/*)
      printf '%s\n' tools/test-e3.sh
      return 0
      ;;
  esac
  base="${f##*/}"
  dir="${f%/*}"
  if [ "$dir" = tools ]; then
    git grep -l -F -e "$f" -e "$base" -- 'tools/test-*.sh' 2>/dev/null || true
  else
    git grep -l -F -e "$f" -e "$base" -e "${dir}/" -- 'tools/test-*.sh' 2>/dev/null || true
  fi
}
flow_gate_desktop_stubs() {
  # apps/desktop/src-tauri 是独立 Cargo workspace；tauri-build 要求 externalBin 指向的
  # 占位文件存在（CI 的 desktop-checks 也先 touch 这两个）。占位目录在 apps/desktop/.gitignore 里。
  local host suffix name stub
  host="$(rustc -vV 2>/dev/null | sed -n 's/^host: //p')"
  [ -n "$host" ] || host="x86_64-unknown-linux-gnu"
  case "$host" in *windows*) suffix=".exe" ;; *) suffix="" ;; esac
  mkdir -p apps/desktop/src-tauri/binaries
  for name in ppf-daemon ppf-decoder; do
    stub="apps/desktop/src-tauri/binaries/${name}-${host}${suffix}"
    [ -e "$stub" ] || : >"$stub"
    chmod +x "$stub" 2>/dev/null || true
  done
}
flow_pick_gates() { # 从 stdin 读路径清单（一行一个），结果放进 GATES（命令数组）与 LANG_TEST（0/1）
  local f crate_dir pkg tests full=0 has_code=0
  GATES=()
  LANG_TEST=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      docs/* | *.md | release/notes/*)
        # 纯文本不算代码；例外是流程文件（与远端 ci-docs.yml flow-tests job 的路径过滤同口径）：
        # AGENTS.md 是流程规矩本体、.github/** 是流程模板，改了仍要跑整套流程自测，不进纯文档快检。
        case "$f" in
          AGENTS.md | .github/*) flow_gate_add "just ci-docs" ;;
        esac
        continue ;;
    esac
    has_code=1
    case "$f" in
      apps/ios/*.strings | apps/ios/*.xcstrings | assets/i18n/*) LANG_TEST=1 ;;
    esac
    case "$f" in
      apps/android/*)
        flow_gate_add "just android-test"
        case "$f" in */strings*.xml) flow_gate_add "just mobile-static-check" ;; esac
        ;;
      tools/ios/test-*.sh)
        # tools/ios 下的测试脚本是构建辅助脚本的测试（由 mobile-static-check / ci-ios 调），
        # 不是 App 代码：直接跑它，别拉模拟器。删除的脚本不跑（diff 也会列出已删除路径）；
        # 需要模拟器的脚本在非 macOS 上自己跳过。
        [ -f "$f" ] && flow_gate_add "bash $f"
        ;;
      apps/ios/* | tools/ios/*) flow_gate_add "just ios-test" ;;
      assets/i18n/*) flow_gate_add "just mobile-static-check" ;;
      apps/desktop/src-tauri/*)
        # 外壳 Rust 是独立 workspace：nextest 要显式 --manifest-path；跑前补 tauri-build 的 sidecar 占位文件。
        # fmt/clippy 与 .github/actions/desktop-checks 逐字对齐（CI-03：主 workspace 的 cargo 覆盖不到独立 workspace）。
        flow_gate_desktop_stubs
        flow_gate_add "cargo nextest run --manifest-path apps/desktop/src-tauri/Cargo.toml -p p-pass-desktop"
        flow_gate_add "cargo fmt --manifest-path apps/desktop/src-tauri/Cargo.toml -- --check"
        flow_gate_add "cargo clippy --manifest-path apps/desktop/src-tauri/Cargo.toml --all-targets -- -D warnings"
        ;;
      apps/desktop/src/*) flow_gate_add "pnpm -C apps/desktop test" ;;
      crates/*/*)
        crate_dir="${f#crates/}"
        crate_dir="${crate_dir%%/*}"
        pkg="$(sed -n 's/^name *= *"\(.*\)"/\1/p' "crates/${crate_dir}/Cargo.toml" 2>/dev/null | head -1)"
        if [ -n "$pkg" ]; then
          flow_gate_add "cargo nextest run -p ${pkg}"
          flow_gate_add "cargo fmt --all -- --check"
          # BUILD-06（#174 修过、#1669 复发）：与 justfile 的 `lint` 逐字一致，**不带** --all-features。
          # transport/mobile-ffi 用 std::os::fd，Windows 上 E0432/E0599 编不过；远端 ci-rust 才带它。
          flow_gate_add "cargo clippy --all-targets -- -D warnings"
        else full=1; fi
        ;;
      tools/*)
        tests="$(flow_gate_tool_tests "$f")"
        if [ -n "$tests" ]; then
          while IFS= read -r t; do flow_gate_add "bash ${t}"; done <<EOF3
$tests
EOF3
        else
          full=1
        fi
        ;;
      .github/workflows/*)
        flow_gate_add "actionlint"
        flow_gate_add "just ci-docs"
        ;;
      justfile | .github/ISSUE_TEMPLATE/* | .github/PULL_REQUEST_TEMPLATE.md) flow_gate_add "just ci-docs" ;;
      .coderabbit.yaml) flow_gate_add "just ci-docs" ;;
      *) full=1 ;;
    esac
  done
  if [ "$has_code" = 0 ]; then
    # 纯文档快检（#1750）：只跑文档域检查，不聚合工具/流程自测；上面点过名的流程文件例外（GATES 非空）。
    [ "${#GATES[@]}" -gt 0 ] || GATES=("just md-check")
  elif [ "$full" = 1 ] || [ "${#GATES[@]}" -eq 0 ]; then
    GATES=("just ci")
  fi
  if [ "$LANG_TEST" = 1 ]; then
    flow_gate_add "just ios-test --lang en"
    flow_gate_add "just ios-test --lang zh"
  fi
}
