#!/usr/bin/env bash
# acceptance gate：PR 合入时只把核心改动的方案关；用户看得到的改动不在 PR 上验收，随版本验收（#1471）。
#
#   acceptance-gate.sh check    --files <改动文件列表> --body <PR 正文文件> [--repo <仓库根>] [--core-rules <规则文件>] [--diff <unified diff>]
#   acceptance-gate.sh classify [--repo <仓库根>] [--core-rules <规则文件>] [--diff <unified diff>] < 改动文件列表
#                               打印 core / core-hidden / ui / notes / none
#
# 级别判定只在这里一份：flow.py done/review、CI 的 acceptance gate（check）、
# release-scope.sh（classify，算每个版本的验收范围）都调用本脚本，别在别处再抄一份。
#
# 「用户可见」= 界面与文案路径（本脚本 UI_GLOBS）或 apps/** 下的非测试文件
# （测试 = 下面 TEST_RE 圈出的位置）。核心 = .github/core-paths.txt（给了 --diff 时，只改版本号行的文件不算，见 tools/ci-paths.sh）。
#   core        命中核心且用户可见：正文引用 origin/main 上「已采纳」的方案（docs/decisions/<文件>.md）；不要验收行，随版本验收
#   core-hidden 命中核心、用户看不见（如发布链脚本，#1448）：正文引用已采纳方案，且改动里带测试文件（带反证的自动化测试）
#   ui          用户可见：合入不要验收行，随版本验收
#   notes       只改更新说明（非测试文件全在 release/notes/** 与 CHANGELOG.md，且至少一个 release/notes/**）：同 ui，
#               发版前在台账里做文案确认；notes 与界面混改是 ui；只改 CHANGELOG.md 是 none
#   none        自动级，直接绿
# 随版本验收：验收单位是候选版相对上一个正式版、用户看得见的改动。just release-scope 从 git 算范围（ui / core / notes），
# 台账每版一张 issue，发版前 just release-acceptance <台账号> 清零才出正式版（AGENTS.md「验收」）。
# 退出码：0 绿 / 1 红 / 2 用法错误。

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=decision-lib.sh
. "${HERE}/decision-lib.sh"

# 注意：方括号里不放全角字符（C locale 下 grep 按字节解析，会把它拆成几个字节）。
# 更新说明路径（release/notes/**）与随版本写的 CHANGELOG.md。
NOTES_RE='^(release/notes/|CHANGELOG\.md$)'

# 只认真实测试位置：*.test.* / *.spec.* 文件，或测试目录下的文件（test、tests、__tests__、androidTest、
# sharedTest、iOS 的 PPassTests 与各包的 Tests 目录；对照过 build.gradle.kts / Package.swift / project.yml / Cargo）。
# 注意 iOS 的 TransportFFITests/Package.swift 是 App 依赖的包清单，不是测试，所以不能按「*Tests 目录」放过。不按文件名后缀 Test 判，否则 SpeedTest.svelte 这种正式组件会被漏掉。
TEST_RE='(\.(test|spec)\.[^/]*$)|((^|/)(PPassTests|Tests|tests|test|__tests__|androidTest|sharedTest)/)|((^|/)test-[^/]*\.(sh|py)$)'

# 界面与文案路径（唯一真源）：碰到就算用户可见行为。
UI_GLOBS="assets/i18n/** assets/design/** apps/android/app/src/main/res/** apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/** apps/desktop/src/** apps/ios/PPass/** site/** release/notes/**"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

MODE="${1:-}"
[ -n "$MODE" ] || usage
shift
FILES_F=""
BODY_F=""
REPO="$(cd "${HERE}/../.." && pwd)"
HEAD_DIR=""
CORE_RULES=""
DIFF_F=""
CARDS_SET=0
CARDS_OVR=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --files) FILES_F="${2:-}"; shift 2 || shift ;;
    --body) BODY_F="${2:-}"; shift 2 || shift ;;
    --repo) REPO="${2:-}"; shift 2 || shift ;;
    --head-dir) HEAD_DIR="${2:-}"; shift 2 || shift ;;
    --core-rules) CORE_RULES="${2:-}"; shift 2 || shift ;;
    --diff) DIFF_F="${2:-}"; shift 2 || shift ;;
    --cards) CARDS_SET=1; CARDS_OVR="${2:-}"; shift 2 || shift ;;
    *) usage ;;
  esac
done
[ -n "$HEAD_DIR" ] || HEAD_DIR="$REPO"

# 用户可见：apps/** 下的非测试文件（如安卓备份行为 backup/**），或界面与文案路径。
visible() { # visible <非测试文件列表>：可见打印 yes
  local nontest="$1" ui
  [ -n "$nontest" ] || return 0
  if [ "$(printf '%s\n' "$nontest" | bash "${REPO}/tools/ci-paths.sh" hit - 'apps/**' 2>/dev/null)" != "false" ]; then
    echo yes
    return
  fi
  [ -n "${UI_GLOBS:-}" ] || { echo yes; return; }
  set -f
  # shellcheck disable=SC2086 # 清单是空格分隔的 glob，刻意拆开
  ui="$(printf '%s\n' "$nontest" | bash "${REPO}/tools/ci-paths.sh" hit - $UI_GLOBS 2>/dev/null)"
  set +f
  [ "$ui" = "false" ] || echo yes
}

classify() {
  local files core nontest
  files="$(cat)"
  [ -n "$CORE_RULES" ] || CORE_RULES="${REPO}/.github/core-paths.txt"
  # 过滤后为空就不判（ci-paths 对空输入 fail-closed 判 true）。
  nontest="$(printf '%s\n' "$files" | grep -Ev "$TEST_RE" | grep -v '^$')"
  if [ -n "$DIFF_F" ]; then
    core="$(printf '%s\n' "$files" | bash "${REPO}/tools/ci-paths.sh" core - "$CORE_RULES" --diff "$DIFF_F" 2>/dev/null)"
  else
    core="$(printf '%s\n' "$files" | bash "${REPO}/tools/ci-paths.sh" core - "$CORE_RULES" 2>/dev/null)"
  fi
  if [ "$core" != "false" ]; then
    # 核心里再分可见与否：只改更新说明也算可见（文案）。
    if [ -n "$(visible "$nontest")" ]; then echo core; else echo core-hidden; fi
    return
  fi
  [ -n "$nontest" ] || { echo none; return; }
  # 只改更新说明（可带 CHANGELOG.md）：文案确认，不要真机验收。
  if [ -z "$(printf '%s\n' "$nontest" | grep -Ev "$NOTES_RE")" ] &&
    printf '%s\n' "$nontest" | grep -q '^release/notes/'; then
    echo notes
    return
  fi
  if [ -n "$(visible "$nontest")" ]; then echo ui; else echo none; fi
}

# 正文引用的、origin/main 上「已采纳」的方案（一行一个）。在仓库根下判，取 origin/main 上的版本：
# PR 自己加进来的方案文件不算（没合进 main 就不是已采纳）。
adopted_in_body() { (cd "$REPO" && adopted_adrs "$(cat "$BODY_F")"); }

# 反假考卷门禁：彻底拒绝在 PR 改动里新增/保留任何 exam_* 一次性考卷，或新增读取业务源码字符串充当断言的假测试（物理删除存量旧文件合法放行）。
check_no_exam_files() {
  local spec
  spec="$(fake_src_read_spec)"
  python3 -B -I - "$HEAD_DIR" "$FILES_F" "$TEST_RE" "$spec" "$REPO" <<'PY' || exit 1
from collections import Counter
import json, os, pathlib, re, subprocess, sys

head_dir, files_f, test_re = pathlib.Path(sys.argv[1]), sys.argv[2], re.compile(sys.argv[3])
spec = json.loads(sys.argv[4])
repo_dir = pathlib.Path(sys.argv[5])
ext_re = re.compile(spec["ext"])
py_read_re = re.compile(spec["py_read_text"])
call_head_re = re.compile(spec["call_head"])
path_ctor_re = re.compile(spec["path_ctor_head"])
path_read_re = re.compile(spec["path_read_meth"])
allowlist = spec.get("cross_end_allowlist", {})

def strip_comments(text: str) -> str:
    return "".join(
        "\n" if (s := ln.lstrip()).startswith(("//", "# ")) or s in ("#", "#\n") else ln
        for ln in text.splitlines(True)
    )

def paren_span(text: str, open_idx: int, limit: int = 400):
    depth, end, i = 0, min(len(text), open_idx + limit), open_idx
    while i < end:
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i, text[open_idx:i + 1]
        i += 1
    return None

def find_fake_reads(text: str, rel_path: str) -> list[str]:
    clean = strip_comments(text)
    hits = [re.sub(r"\s+", " ", m.group(0)).strip() for m in py_read_re.finditer(clean)]
    for m in call_head_re.finditer(clean):
        paren = clean.find("(", m.start())
        if paren == -1:
            continue
        sp = paren_span(clean, paren)
        if sp and ext_re.search(sp[1]):
            hits.append(re.sub(r"\s+", " ", clean[m.start():sp[0] + 1]).strip())
    for m in path_ctor_re.finditer(clean):
        sp = paren_span(clean, m.end() - 1)
        if not sp or not ext_re.search(sp[1]):
            continue
        tail = clean[sp[0] + 1:sp[0] + 220]
        nxt = path_ctor_re.search(tail)
        if nxt:
            tail = tail[:nxt.start()]
        if path_read_re.search(tail):
            hits.append(re.sub(r"\s+", " ", clean[m.start():sp[0] + 1]).strip())
    allowed_targets = allowlist.get(rel_path, ())
    if allowed_targets:
        hits = [h for h in hits if not any(t in h for t in allowed_targets)]
    return hits

def base_text_of(rel_path: str) -> str:
    if not (repo_dir / ".git").exists():
        return ""
    env = {**os.environ, "MSYS_NO_PATHCONV": "1"}
    r = subprocess.run(["git", "-C", str(repo_dir), "show", f"origin/main:{rel_path}"], capture_output=True, text=True, errors="ignore", env=env)
    return r.stdout if r.returncode == 0 else ""

bad_exams, bad_fakes = [], []
for raw in pathlib.Path(files_f).read_text(encoding="utf-8", errors="ignore").splitlines():
    f = raw.strip()
    if not f:
        continue
    target = head_dir / f
    if not target.exists():
        continue
    if re.search(r"(^|/)exam_[^/]*$", f):
        bad_exams.append(f)
    elif test_re.search(f) and target.is_file():
        txt = target.read_text(encoding="utf-8", errors="ignore")
        head_hits = find_fake_reads(txt, f)
        if head_hits:
            base_txt = base_text_of(f)
            if base_txt:
                diff_hits = Counter(head_hits) - Counter(find_fake_reads(base_txt, f))
                if not diff_hits:
                    continue
            bad_fakes.append(f)
if bad_exams or bad_fakes:
    if bad_exams:
        print("acceptance gate ❌：禁止提交一次性 exam_* 考卷文件（请直接写在各端正式测试套件里）：", file=sys.stderr)
        for x in bad_exams:
            print(f"  - {x}", file=sys.stderr)
    if bad_fakes:
        print("acceptance gate ❌：禁止提交通过读取业务源码字符串充当断言的假测试：", file=sys.stderr)
        for x in bad_fakes:
            print(f"  - {x}", file=sys.stderr)
    sys.exit(1)
PY
}

case "$MODE" in
  classify) classify ;;
  check)
    [ -f "$FILES_F" ] && [ -f "$BODY_F" ] || usage
    check_no_exam_files
    KIND="$(classify <"$FILES_F")"
    case "$KIND" in
      none)
        echo "acceptance gate：不碰界面与核心路径（自动级），不需要验收 ✅"
        exit 0
        ;;
      core-hidden)
        adrs="$(adopted_in_body)"
        tests="$(grep -E "$TEST_RE" "$FILES_F" | head -n 3)"
        if [ -n "$adrs" ] && [ -n "$tests" ]; then
          echo "acceptance gate：核心改动、用户看不见，正文引用已采纳方案（$(printf '%s' "$adrs" | tr '\n' ' ')）且带测试 ✅"
          exit 0
        fi
        echo "acceptance gate ❌：改动碰核心路径、用户看不见（不要验收行），但缺："
        [ -n "$adrs" ] || echo "  - PR 正文引用 origin/main 上「已采纳」的方案（docs/decisions/<日期>-<名>.md）"
        [ -n "$tests" ] || echo "  - 改动里带测试文件（带反证的自动化测试）"
        exit 1
        ;;
    esac
    if [ "$KIND" = core ]; then
      adrs="$(adopted_in_body)"
      if [ -z "$adrs" ]; then
        echo "acceptance gate ❌：改动碰核心路径（用户看得到），PR 正文缺 origin/main 上「已采纳」的方案引用（docs/decisions/<日期>-<名>.md）。"
        exit 1
      fi
      echo "acceptance gate：核心且用户可见，引用了已采纳方案（$(printf '%s' "$adrs" | tr '\n' ' ')），合入不要验收行，随版本验收 ✅"
      exit 0
    fi
    if [ "$KIND" = ui ] || [ "$KIND" = notes ]; then
      echo "acceptance gate：${KIND} 级改动（用户看得见），合入不要验收行，随版本验收（just release-scope 列进台账，发版前清零）✅"
      exit 0
    fi
    echo "acceptance gate ❌：判不了级别（classify 输出「${KIND}」），不放行。"
    exit 1
    ;;
  *) usage ;;
esac
