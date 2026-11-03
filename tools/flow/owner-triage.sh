#!/usr/bin/env bash
# just triage <号> <方案文件>：owner 给 status:inbox 的卡定方案（方案闸门）。说明见 docs/runbook/owner.md。
#
# 方案由模型写进一个 markdown 文件，下面这些字段一个都不能少（值写「无」也算写了）：
#   **做法**：…            **涉及端**：android / mac / windows / ios / 无
#   **数据**：…            **用户可见行为**：…      **隐私**：…      **风险**：…
#   **范围**：后面跟一个 ``` 代码块，一行一个路径或 glob（新文件也要写上）
#   **验收场景**：…        （按任务卡模板：场景 id，或步骤 + 日志判据 + 反证，标 E1–E4）
#   **ADR**：docs/decisions/<文件>.md        （范围命中核心时必填）
#   **选项一**：… **选项二**：…               （需要产品负责人拍板时必填，各写做法与影响）
#   **产品定案**：docs/decisions/<文件>.md，产品负责人 <日期> 已确认   （可选；写「无」等于没写）
#
# 分流由脚本判定，不看模型的结论：
#   1. 范围命中核心（.github/core-paths.txt）：要有 origin/main 上「已采纳」的 ADR；
#      没有 ⇒ status:blocked（写明先定 ADR）。有 ⇒ 打 core 标签，继续往下判。
#   2. 有「产品定案」：引用的方案全部在 origin/main 上「已采纳」，且字段写明产品负责人确认，
#      否则拒绝；合格 ⇒ 产品取向已定，不打 needs:product、不要选项，按 3 判。
#      没有「产品定案」：用户可见行为 / 隐私 / 数据 任一不是「无」，或范围碰到界面与文案路径
#      （即使方案写了「无」也算）⇒ needs:product，必须有两个选项，否则拒绝。
#   3. 其余 ⇒ status:ready。
# 方案写回 issue：「范围」「验收场景」「是否核心」填进任务卡对应字段（hook 与 just verify 读它们），
# 其余放进正文末尾的「实施方案」段（重跑覆盖，不叠加）。
# 输出：TRIAGE <号> ready | needs:product | blocked

set -uo pipefail
# shellcheck source=tools/flow/owner-lib.sh
source "$(cd "$(dirname "$0")" && pwd)/owner-lib.sh"

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ $# -eq 2 ] || usage
N="$1"
PLAN="$2"
[[ "$N" =~ ^[0-9]+$ ]] || refuse "「${N}」不是 issue 号"
[ -f "$PLAN" ] || refuse "找不到方案文件 ${PLAN}"

# 界面与文案：碰到就算用户可见行为。
UI_GLOBS="assets/i18n/** assets/design/** apps/android/app/src/main/res/** apps/android/app/src/main/java/com/hawkeyexb/ppass/ui/** apps/desktop/src/** apps/ios/PPass/** site/** release/notes/**"

need_gh
fetch_origin
load_issue "$N" || refuse "$CARD_ERR"
[ "$ISSUE_STATE" = OPEN ] || refuse "#${N} 不是打开状态"
has_label status:inbox || refuse "#${N} 不是 status:inbox（标签：${ISSUE_LABELS}）" "triage 只给新诉求定方案；已分拣过的卡要重来，先把它改回 status:inbox。"

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
# 解析方案：字段 → 文件（TMPD/<字段>）。缺字段在 stderr 列出并退出 3。
python3 -I - "$PLAN" "$TMPD" <<'PY'
import re, sys, pathlib
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").replace("\r", "")
out = pathlib.Path(sys.argv[2])
names = ["做法", "涉及端", "数据", "用户可见行为", "隐私", "风险", "范围", "验收场景", "ADR", "选项一", "选项二", "产品定案"]
pat = re.compile(r"^\*\*(" + "|".join(names) + r")\*\*[：:]?[ \t]*", re.M)
hits = list(pat.finditer(text))
fields = {}
for i, m in enumerate(hits):
    end = hits[i + 1].start() if i + 1 < len(hits) else len(text)
    fields[m.group(1)] = text[m.end():end].strip()
scope = ""
if "范围" in fields:
    m = re.search(r"```[^\n]*\n(.*?)```", fields["范围"], re.S)
    scope = m.group(1).strip() if m else ""
    fields["范围"] = scope
missing = [n for n in names[:8] if not fields.get(n, "").strip()]
if missing:
    print("方案缺字段或字段为空：" + "、".join(missing) + ("（范围要有 ``` 代码块）" if "范围" in missing else ""), file=sys.stderr)
    sys.exit(3)
for k, v in fields.items():
    (out / k).write_text(v + "\n", encoding="utf-8")
PY
rc=$?
[ "$rc" -eq 0 ] || refuse "方案不完整（见上一行）" "补齐 ${PLAN} 再重跑 just triage ${N} ${PLAN}。"
field() { [ -f "${TMPD}/$1" ] && cat "${TMPD}/$1"; }
is_none() { [[ "$(field "$1" | head -1 | tr -d '[:space:]')" =~ ^(无|没有|不涉及|none|无。)$ ]]; }

GLOBS=()
while IFS= read -r g; do
  g="$(printf '%s' "$g" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's#^\./##')"
  case "$g" in "" | "#"*) continue ;; esac
  case "$g" in */) g="${g}**" ;; esac
  GLOBS+=("$g")
done <<EOF
$(field 范围)
EOF
[ "${#GLOBS[@]}" -gt 0 ] || refuse "范围代码块里没有路径"

# 范围 → 具体文件：已有文件按 glob 展开；没展开出东西的（新文件 / 新目录）把通配换成占位名照样判，
# 宁可多判核心，不漏判。
FILES="${TMPD}/files"
: >"$FILES"
ALL="$(git ls-tree -r --name-only origin/main)"
for g in "${GLOBS[@]}"; do
  hits="$(printf '%s\n' "$ALL" | python3 -I -c '
import re, sys
g = sys.argv[1]
r = re.escape(g).replace(r"\*\*/", "(?:.*/)?").replace(r"\*\*", ".*").replace(r"\*", "[^/]*").replace(r"\?", "[^/]")
for line in sys.stdin:
    if re.fullmatch(r, line.rstrip("\n")):
        print(line.rstrip("\n"))
' "$g")"
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits" >>"$FILES"
  else
    printf '%s\n' "$g" | sed -e 's#\*\*#__new__/__new__#g' -e 's#\*#__new__#g' -e 's#?#_#g' >>"$FILES"
  fi
done
CORE="$(sort -u "$FILES" | bash "${REPO_ROOT}/tools/ci-paths.sh" core - "${REPO_ROOT}/.github/core-paths.txt" 2>/dev/null)"
set -f
# shellcheck disable=SC2086
UI="$(sort -u "$FILES" | bash "${REPO_ROOT}/tools/ci-paths.sh" hit - $UI_GLOBS 2>/dev/null)"
set +f

ADRS=""
REASONS=""
if [ "$CORE" != false ]; then
  ADRS="$(adopted_adrs "$(field ADR)")"
  if [ -z "$ADRS" ]; then
    DECISION=blocked
  fi
fi
# 产品定案：引用的方案全部已采纳、且写明产品负责人确认，才算产品取向已定。
DECIDED=""
if [ -n "$(field 产品定案)" ] && ! is_none 产品定案; then
  refs="$(decision_refs "$(field 产品定案)")"
  DECIDED="$(adopted_adrs "$(field 产品定案)")"
  [ -n "$refs" ] && [ "$refs" = "$DECIDED" ] ||
    refuse "**产品定案** 引用的方案不是全部在 origin/main 上「已采纳」（引用：$(printf '%s' "${refs:-无}" | tr '\n' ' ')；已采纳：$(printf '%s' "${DECIDED:-无}" | tr '\n' ' ')）" \
      "等方案采纳并合入 main 再重跑；产品取向还没定就去掉这个字段，走 needs:product。"
  [[ "$(field 产品定案 | tr '\n' ' ')" =~ 产品负责人.*确认 ]] ||
    refuse "**产品定案** 没写明产品负责人已确认（要写成「产品负责人 <日期> 已确认」）" \
      "确认过就补上再重跑；没确认就去掉这个字段，走 needs:product。"
fi
PRODUCT=0
is_none 用户可见行为 || { PRODUCT=1; REASONS="${REASONS}用户可见行为；"; }
is_none 隐私 || { PRODUCT=1; REASONS="${REASONS}隐私；"; }
is_none 数据 || { PRODUCT=1; REASONS="${REASONS}数据去留；"; }
[ "$UI" = false ] || { PRODUCT=1; REASONS="${REASONS}范围碰到界面或文案路径；"; }
[ -z "$DECIDED" ] || PRODUCT=0
if [ "${DECISION:-}" != blocked ]; then
  if [ "$PRODUCT" = 1 ]; then
    [ -n "$(field 选项一)" ] && [ -n "$(field 选项二)" ] ||
      refuse "这张卡要产品负责人拍板（${REASONS%；}），方案里必须有 **选项一** 与 **选项二**（各写做法与影响）" \
        "补齐 ${PLAN} 再重跑。"
    DECISION=needs:product
  else
    DECISION=ready
  fi
fi

# 写回 issue 正文。
printf '%s\n' "$ISSUE_BODY" >"${TMPD}/body"
CORE_TXT="否（范围不命中 .github/core-paths.txt）"
[ "$CORE" = false ] || CORE_TXT="是（定案：$(printf '%s' "${ADRS:-无}" | tr '\n' ' ')）"
python3 -I - "${TMPD}" "$CORE_TXT" "$DECISION" "${REASONS%；}" <<'PY'
import re, sys, pathlib
d = pathlib.Path(sys.argv[1]); core_txt, decision, reasons = sys.argv[2], sys.argv[3], sys.argv[4]
f = lambda k: (d / k).read_text(encoding="utf-8").strip() if (d / k).exists() else ""
body = (d / "body").read_text(encoding="utf-8").replace("\r", "")
begin, end = "<!-- triage:begin -->", "<!-- triage:end -->"
body = re.sub(re.escape(begin) + r".*?" + re.escape(end) + r"\n?", "", body, flags=re.S).rstrip() + "\n"

def set_field(body, label_re, value, block=False):
    """把任务卡字段（**<label>**：…直到下一个 **字段** 或 # 标题）换成新值；没有就返回 None。"""
    m = re.search(r"^(\*\*" + label_re + r"[^*\n]*\*\*[：:]?)[^\n]*\n?", body, re.M)
    if not m:
        return None
    rest = body[m.end():]
    n = re.search(r"^(\*\*[^*\n]+\*\*|#)", rest, re.M)
    tail = rest[n.start():] if n else ""
    new = m.group(1) + ("\n```\n" + value + "\n```\n\n" if block else value + "\n\n")
    return body[:m.start()] + new + tail

scope, accept = f("范围"), f("验收场景")
extra = []
b = set_field(body, "范围", scope, block=True)
if b is None:
    extra.append("**范围（只许动这些）**：\n```\n" + scope + "\n```\n")
else:
    body = b
b = set_field(body, "验收场景", accept)
if b is None:
    extra.append("**验收场景**：\n" + accept + "\n")
else:
    body = b
b = set_field(body, "是否核心", core_txt)
if b is None:
    extra.append("**是否核心**：" + core_txt + "\n")
else:
    body = b

sec = [begin, "## 实施方案（just triage）", ""]
sec += extra
for k in ("做法", "涉及端", "数据", "用户可见行为", "隐私", "风险", "ADR", "产品定案"):
    if f(k):
        sec.append("**" + k + "**：" + f(k) + "\n")
if decision == "needs:product":
    sec.append("**需要产品负责人拍板**（" + reasons + "）：\n")
    sec.append("1. " + f("选项一"))
    sec.append("2. " + f("选项二") + "\n")
sec.append("分流结果：`" + decision + "`（脚本按范围路径与字段判定）")
sec.append(end)
(d / "newbody").write_text(body.rstrip() + "\n\n" + "\n".join(sec) + "\n", encoding="utf-8")
PY
[ -s "${TMPD}/newbody" ] || die_stuck "triage #${N}：生成新正文失败" --issue "$N"

# 写回后自检：hook 读得出范围（与 tools/hooks/pre-commit 同一解析）。
got="$(scope_globs "$(cat "${TMPD}/newbody")" | tr '\n' ' ')"
want="$(printf '%s\n' "${GLOBS[@]}" | tr '\n' ' ')"
[ "$got" = "$want" ] || die_stuck "triage #${N}：写回后的「范围」读出来是「${got}」，不是「${want}」，没有写入" --issue "$N"

gh issue edit "$N" -R "$REPO" --body-file "${TMPD}/newbody" >/dev/null || die_stuck "写回 #${N} 正文失败"
case "$DECISION" in
  blocked)
    bash "${FLOW_DIR}/owner-stuck.sh" "范围命中核心（.github/core-paths.txt），方案没有引用 origin/main 上「已采纳」的 ADR。先按 AGENTS.md 红线 6 写 ADR（docs/decisions/）并定案，再重跑 just triage" --issue "$N" ||
      die_stuck "把 #${N} 打成 status:blocked 失败"
    ;;
  needs:product)
    [ "$CORE" = false ] || gh issue edit "$N" -R "$REPO" --add-label core >/dev/null
    gh issue edit "$N" -R "$REPO" --add-label needs:product >/dev/null || die_stuck "给 #${N} 打 needs:product 失败"
    ;;
  ready)
    [ "$CORE" = false ] || gh issue edit "$N" -R "$REPO" --add-label core >/dev/null
    set_status "$N" status:ready || die_stuck "把 #${N} 换成 status:ready 失败"
    ;;
esac
printf 'TRIAGE %s %s\n' "$N" "$DECISION"
