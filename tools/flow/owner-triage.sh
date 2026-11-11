#!/usr/bin/env bash
# just triage <号> <方案文件>：owner 给 status:inbox 的卡定方案（方案闸门）。说明见 docs/runbook/owner.md。
#
# 方案由模型写进一个 markdown 文件；必填字段一个都不能少（值写「无」也算写了），可选字段见下：
#   **做法**：…            **涉及端**：android / mac / windows / ios / 无
#   **数据**：…            **用户可见行为**：…      **隐私**：…      **风险**：…
#   **影响**：不可挽回 / 面广 / 局部     （不可挽回＝丢照片、隐私泄露、安全；面广＝主流程坏、发不了版；局部＝文案、样式）
#   **时间性**：停线 / 截止日 / 线性 / 无   （停线＝此刻卡住交付或卡着产品负责人；产品负责人点名的一类卡也算停线）
#   **范围**：后面跟一个 ``` 代码块，一行一个路径或 glob（新文件也要写上）
#   **验收场景**：…        （按任务卡模板：场景 id，或步骤 + 日志判据 + 反证，标 E1–E4）
#   **ADR**：docs/decisions/<文件>.md        （范围命中核心时必填）
#   **选项一**：… **选项二**：…               （需要产品负责人拍板时必填，各写做法与影响）
#   **产品定案**：docs/decisions/<文件>.md，产品负责人 <日期> 已确认
#                 或 <本仓 issue/PR 的评论链接>   （可选；写「无」等于没写）
#   **owner 定案**：AGENTS.md「<逐字原文>」 和/或 <仓库 owner 的评论链接>   （可选；写「无」等于没写）
#   **标准依据**：WAI-ARIA / Android 权限规范 / NN/g / Google 或 Microsoft 写作指南等业界标准   （可选；写「无」等于没写）
#
# 分流由脚本判定，不看模型的结论：
#   1. 范围命中核心（.github/core-paths.txt）：要有 origin/main 上「已采纳」的 ADR；
#      没有 ⇒ status:blocked（写明先定 ADR）。有 ⇒ 打 core 标签，继续往下判。
#   2. 有「产品定案」：引用的方案全部在 origin/main 上「已采纳」（同时有时），引用的本仓评论链接
#      作者必须是产品负责人（对本仓有 admin 权限的 User），链接里的 issue/PR 号必须与评论实际所属一致；
#      字段里所有评论链接都必须属于本仓，外仓链接直接拒绝。评论链接本身就是拍板依据，不要求另写
#      「产品负责人…确认」。任一不成立就拒绝；合格 ⇒ 产品取向已定，不打 needs:product、不要选项。
#      核心卡仍要第 1 条已采纳 ADR，评论链接不能替代 ADR。
#      没有「产品定案」：用户可见行为 / 隐私 / 数据 任一不是「无」，或范围碰到界面与文案路径
#      （即使方案写了「无」也算）⇒ needs:product，必须有两个选项，否则拒绝。
#      有「owner 定案」：依据只认 AGENTS.md 原文（「」里的句子在 origin/main 的 AGENTS.md 里逐字出现）
#      和仓库 owner 账号的评论链接（gh api 核对评论存在、作者是 owner），任一不成立就拒绝；
#      合格且隐私、数据都是「无」、卡类型不是 Feature ⇒ 不打 needs:product、不要选项，打 decided:owner。
#      有「标准依据」：值须写明可核对的业界标准（WAI-ARIA/WCAG/ARIA APG、Android 权限规范、NN/g、
#      Google/Microsoft 写作指南、Apple HIG、Material Design）；官方链接只认完整主机与适用路径，
#      其他主机/路径直接拒绝，没有链接时按标准名校验，否则拒绝；
#      标准成立且隐私、数据都是「无」、卡类型不是 Feature ⇒ 同上，打 decided:owner。
#      隐私或数据不是「无」、或 Feature 卡：owner 定案 / 标准依据都不顶用，照常 needs:product。
#   3. 其余 ⇒ status:ready。
# 优先级（P0–P3）也由脚本按「影响」×「时间性」算，不看模型的结论，不看卡的类型（流程 / 功能）：
#   停线 → P0；不可挽回（其余时间性）→ P1；面广：截止日 → P1、线性 → P2、无 → P3；局部：截止日 → P2，线性、无 → P3。
#   自动定级：标题以 [MAIN-RED] 开头 → 直接 P0；挂了 milestone 且到期不足 3 天（含已过期）→ 在上表结果上升一级（最高 P0）。
#   写标签时替换这张卡上已有的 P0–P3，不叠加；产品负责人可直接改标签覆盖。
# 方案写回 issue：「范围」「验收场景」「是否核心」填进任务卡对应字段（hook 与 just verify 读它们），
# 其余放进正文末尾的「实施方案」段（重跑覆盖，不叠加）。
# 输出：TRIAGE <号> ready | needs:product | blocked，下一行 PRIORITY <号> P0–P3

set -uo pipefail
# shellcheck source=tools/flow/owner-lib.sh
source "$(cd "$(dirname "$0")" && pwd)/owner-lib.sh"

# 开工前自检：位置、shell、提交拦截、gh、提交身份、磁盘、私仓模式。不过就停，不带病继续。
bash "${FLOW_DIR}/doctor.sh" || exit 1

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
python3 -I -X utf8 - "$PLAN" "$TMPD" <<'PY'
import re, sys, pathlib
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").replace("\r", "")
out = pathlib.Path(sys.argv[2])
names = ["做法", "涉及端", "数据", "用户可见行为", "隐私", "风险", "影响", "时间性", "范围", "验收场景", "ADR", "选项一", "选项二", "产品定案", "标准依据", "owner 定案", "复现路径"]
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
missing = [n for n in names[:10] if not fields.get(n, "").strip()]
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
# 整个字段（含换行后的内容）都只是「无」才算无；隐私、数据用这个，不能只看第一行。
is_none_full() { [[ "$(field "$1" | tr -d '[:space:]')" =~ ^(无|没有|不涉及|none|无。)$ ]]; }

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

# 优先级：影响 × 时间性（脚本判，缺或写错都拒绝）。
IMPACT=""
case "$(field 影响 | head -1 | tr -d '[:space:]')" in
  不可挽回*) IMPACT=irreversible ;;
  面广*) IMPACT=wide ;;
  局部*) IMPACT=local ;;
esac
[ -n "$IMPACT" ] || refuse "**影响** 必须是 不可挽回 / 面广 / 局部 之一（现在写的是「$(field 影响 | head -1)」）" "按方案模板补正后重跑。"
TIMING=""
case "$(field 时间性 | head -1 | tr -d '[:space:]')" in
  停线*) TIMING=stop ;;
  截止日*) TIMING=deadline ;;
  线性*) TIMING=linear ;;
  无*) TIMING=none ;;
esac
[ -n "$TIMING" ] || refuse "**时间性** 必须是 停线 / 截止日 / 线性 / 无 之一（现在写的是「$(field 时间性 | head -1)」）" "按方案模板补正后重跑。"
if [ "$TIMING" = stop ]; then PRIO=0
elif [ "$IMPACT" = irreversible ]; then PRIO=1
elif [ "$IMPACT" = wide ]; then
  case "$TIMING" in deadline) PRIO=1 ;; linear) PRIO=2 ;; *) PRIO=3 ;; esac
else
  case "$TIMING" in deadline) PRIO=2 ;; *) PRIO=3 ;; esac
fi
PRIO_WHY="影响=$(field 影响 | head -1 | tr -d '[:space:]')，时间性=$(field 时间性 | head -1 | tr -d '[:space:]')"
case "$ISSUE_TITLE" in
  "[MAIN-RED]"*) PRIO=0; PRIO_WHY="${PRIO_WHY}；标题 [MAIN-RED]：main 红了，自动 P0" ;;
esac
# 挂了带截止日的 milestone：到期前 3 天（含已过期）升一级。
MS_DUE="$(gh issue view "$N" -R "$REPO" --json milestone --jq '.milestone.dueOn // ""' 2>/dev/null)" ||
  refuse "读不到 #${N} 的 milestone，算不了截止日升级" "稍后重跑。"
if [ -n "$MS_DUE" ] && [ "$PRIO" -gt 0 ]; then
  days="$(python3 -I -X utf8 -c '
import sys, datetime
due = datetime.date.fromisoformat(sys.argv[1][:10]); now = datetime.date.fromisoformat(sys.argv[2])
print((due - now).days)' "$MS_DUE" "$(today)")" || refuse "milestone 到期日「${MS_DUE}」读不懂" "核对 milestone 的 due date。"
  if [ "$days" -lt 3 ]; then PRIO=$((PRIO - 1)); PRIO_WHY="${PRIO_WHY}；milestone 到期还剩 ${days} 天，升一级"; fi
fi

# 范围 → 具体文件：已有文件按 glob 展开；没展开出东西的（新文件 / 新目录）把通配换成占位名照样判，
# 宁可多判核心，不漏判。
FILES="${TMPD}/files"
: >"$FILES"
ALL="$(git ls-tree -r --name-only origin/main)"
for g in "${GLOBS[@]}"; do
  hits="$(printf '%s\n' "$ALL" | python3 -I -X utf8 -c '
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
    REASONS="${REASONS}范围命中核心、没有已采纳 ADR；"
  fi
fi
# Bug 卡：必须有「复现路径」（100% 复现的步骤/命令）。复现不了 → blocked 找人对齐，不自动修。
ITYPE_TRIAGE="$(gh api "repos/${REPO}/issues/${N}" --jq '.type.name // empty' 2>/dev/null | tr -d '\r')"
if [ -z "$ITYPE_TRIAGE" ]; then
  if has_label bug; then ITYPE_TRIAGE="Bug"; else ITYPE_TRIAGE="Task"; fi
fi
if [ "$ITYPE_TRIAGE" = "Bug" ]; then
  repro="$(field 复现路径 | head -1 | tr -d '[:space:]')"
  if [ -z "$repro" ] || [[ "$repro" =~ ^(无|没有|不涉及|none|无。)$ ]]; then
    DECISION=blocked
    REASONS="${REASONS}Bug 卡缺「复现路径」；"
  fi
fi
# 产品定案：两种依据——已采纳方案（要写明产品负责人确认），或本仓产品负责人的评论链接。
# 两者可同时出现：所有方案引用都须已采纳，所有评论链接都须是产品负责人的；至少一条依据。
DECIDED=""
PRODUCT_COMMENTS=0
if [ -n "$(field 产品定案)" ] && ! is_none 产品定案; then
  basis="$(field 产品定案)"
  refs="$(decision_refs "$basis")"
  DECIDED="$(adopted_adrs "$basis")"
  [ -z "$refs" ] || [ "$refs" = "$DECIDED" ] ||
    refuse "**产品定案** 引用的方案不是全部在 origin/main 上「已采纳」（引用：$(printf '%s' "${refs:-无}" | tr '\n' ' ')；已采纳：$(printf '%s' "${DECIDED:-无}" | tr '\n' ' ')）" \
      "等方案采纳并合入 main 再重跑；产品取向还没定就去掉这个字段，走 needs:product。"
  if [ -n "$DECIDED" ]; then
    [[ "$(printf '%s' "$basis" | tr '\n' ' ')" =~ 产品负责人.*确认 ]] ||
      refuse "**产品定案** 引用方案时没写明产品负责人已确认（要写成「产品负责人 <日期> 已确认」）" \
        "确认过就补上再重跑；没确认就去掉这个字段，走 needs:product。"
  fi
  # 字段里所有 GitHub issue/PR 评论链接都必须属于本仓；外仓链接不能静默忽略。
  all_links="$(printf '%s\n' "$basis" | grep -oE 'https://github\.com/[^/[:space:]]+/[^/[:space:]]+/(issues|pull)/[0-9]+#issuecomment-[0-9]+' | sort -u)"
  foreign="$(printf '%s\n' "$all_links" | grep -vE "^https://github\.com/${REPO}/(issues|pull)/[0-9]+#issuecomment-[0-9]+$" || true)"
  [ -z "$foreign" ] ||
    refuse "**产品定案** 里有不是本仓的评论链接：$(printf '%s' "$foreign" | tr '\n' ' ')" \
      "只认 https://github.com/${REPO}/... 的产品负责人评论；去掉外仓链接再重跑。"
  # 本仓 issue/PR 评论链接：作者必须是产品负责人（对本仓有 admin 权限的 User），
  # 且链接里的 issue/PR 号必须与评论实际所属的 issue 一致。
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    cid="${url##*issuecomment-}"
    rest="${url#https://github.com/${REPO}/}"
    rest="${rest#*/}"
    link_num="${rest%%#*}"
    meta="$(gh api "repos/${REPO}/issues/comments/${cid}" --jq '[.user.login, .user.type, .issue_url] | @tsv' 2>/dev/null | tr -d '\r')" ||
      refuse "**产品定案** 的评论链接读不到：${url}" "核对链接，或去掉这个字段走 needs:product。"
    IFS=$'\t' read -r login utype issue_url <<<"$meta"
    actual_num="${issue_url##*/}"
    [ "$actual_num" = "$link_num" ] ||
      refuse "**产品定案** 的评论链接 issue/PR 号与评论实际所属不符（链接 #${link_num}，评论属于 #${actual_num:-未知}）：${url}" \
        "核对链接里的 issue/PR 号，或直接贴评论的原始链接。"
    [ "$utype" = User ] ||
      refuse "**产品定案** 的评论作者「${login:-未知}」不是真人账号（${utype:-未知}）：${url}" \
        "只认产品负责人的评论；别人的话不算依据。"
    perm="$(gh api "repos/${REPO}/collaborators/${login}/permission" --jq .permission 2>/dev/null | tr -d '\r')" || perm=""
    [ "$perm" = admin ] ||
      refuse "**产品定案** 的评论作者「${login:-未知}」不是产品负责人（对本仓权限：${perm:-无}）：${url}" \
        "只认对本仓有 admin 权限的产品负责人评论；别人的话不算依据。"
    PRODUCT_COMMENTS=$((PRODUCT_COMMENTS + 1))
  done <<EOF2
$(printf '%s\n' "$all_links" | grep -E "^https://github\.com/${REPO}/(issues|pull)/[0-9]+#issuecomment-[0-9]+$" || true)
EOF2
  [ -n "$DECIDED" ] || [ "$PRODUCT_COMMENTS" -gt 0 ] ||
    refuse "**产品定案** 里没有可校验的依据" \
      "写已采纳的 docs/decisions/<文件>.md（产品负责人 <日期> 已确认），或本仓产品负责人的评论链接；没有依据就去掉这个字段走 needs:product。"
fi
# 标准依据：只认列得出的业界标准；写错就拒绝，不静默忽略。
# 有链接时，链接必须是完整主机 + 适用路径的官方出处；名称匹配不能替代对错链接的校验。
STANDARD_OK=0
if [ -n "$(field 标准依据)" ] && ! is_none 标准依据; then
  standard="$(field 标准依据)"
  standard_re='(WAI-ARIA|WCAG|ARIA[[:space:]]*(Authoring Practices|APG)|Android.*权限|Android.*[Pp]ermission|NN/g|Nielsen[[:space:]]*Norman|尼尔森|(Google|Microsoft).*(写作|文案|风格|[Ss]tyle[[:space:]]+[Gg]uide|developer documentation)|Apple.*(HIG|Human Interface Guidelines|人机界面指南)|Material[[:space:]]*Design)'
  url_state="$(printf '%s' "$standard" | python3 -I -X utf8 -c '
import re, sys
from urllib.parse import urlparse
text = sys.stdin.read()
urls = [u.rstrip("。，,;；") for u in re.findall(r"https?://[^\s（）()]+", text)]
if not urls:
    print("NONE")
    sys.exit(0)
hosts = {
    "w3.org", "www.w3.org", "nngroup.com", "www.nngroup.com",
    "developer.android.com", "developers.google.com",
    "learn.microsoft.com", "developer.apple.com", "m3.material.io",
}
bad = []
for u in urls:
    p = urlparse(u)
    host = (p.hostname or "").lower()
    path = p.path or "/"
    ok = host in hosts
    if host in ("w3.org", "www.w3.org"):
        ok = ok and ("/WAI/" in path or "/TR/" in path)
    elif host == "developers.google.com":
        ok = ok and path.startswith("/style")
    elif host == "learn.microsoft.com":
        ok = ok and "style" in path
    elif host == "developer.apple.com":
        ok = ok and path.startswith("/design")
    if not ok:
        bad.append(u)
print("BAD " + " ".join(bad) if bad else "OK")
')" || refuse "**标准依据** 里的链接读不懂" "改用官方标准名或完整官方链接。"
  case "$url_state" in
    BAD*)
      refuse "**标准依据** 里的链接不是可核对的官方标准出处：${url_state#BAD }" \
        "只认 w3.org、nngroup.com、developer.android.com、developers.google.com/style、learn.microsoft.com/…style、developer.apple.com/design、m3.material.io 的官方链接；没有链接就写标准名。"
      ;;
    OK) STANDARD_OK=1 ;;
  esac
  printf '%s\n' "$standard" | grep -qiE "$standard_re" && STANDARD_OK=1
  [ "$STANDARD_OK" = 1 ] ||
    refuse "**标准依据** 没写出可核对的业界标准（现在写的是「$(printf '%s' "$standard" | head -1)」）" \
      "写明 WAI-ARIA / WCAG、Android 权限规范、NN/g、Google 或 Microsoft 写作指南、Apple HIG、Material Design 等标准（或官方链接）。"
fi
# owner 定案：依据只认 AGENTS.md 原文与仓库 owner 的评论链接；不带这个字段时下面整段不执行。
OWNER_DECIDED=0
if [ -n "$(field "owner 定案")" ] && ! is_none "owner 定案"; then
  basis="$(field "owner 定案")"
  nbasis=0
  printf '%s\n' "$basis" | python3 -I -X utf8 -c 'import re, sys; sys.exit(1 if any("\n" in q for q in re.findall("「([^」]*)」", sys.stdin.read())) else 0)' ||
    refuse "**owner 定案** 引用的 AGENTS.md 原文跨行了" "只认单行原文；一句话写在一行里，分别引用多句。"
  while IFS= read -r q; do
    [ -n "$q" ] || continue
    [ "$(printf '%s' "$q" | python3 -I -X utf8 -c 'import sys; print(len(sys.stdin.read()))')" -ge 8 ] || refuse "**owner 定案** 引用的 AGENTS.md 原文太短（「${q}」，至少 8 个字）" "引一整句规矩原文。"
    # Git Bash 会把 origin/main:<path> 的冒号当路径分隔符改写；禁止 MSYS 做路径转换。
    MSYS_NO_PATHCONV=1 git show origin/main:AGENTS.md 2>/dev/null | grep -qF -- "$q" ||
      refuse "**owner 定案** 引用的原文在 origin/main 的 AGENTS.md 里找不到：「${q}」" \
        "逐字照抄 AGENTS.md 的句子；找不到依据就去掉这个字段，走 needs:product。"
    nbasis=$((nbasis + 1))
  done <<EOF2
$(printf '%s\n' "$basis" | python3 -I -X utf8 -c 'import re, sys; print("\n".join(re.findall("「([^」]*)」", sys.stdin.read())))')
EOF2
  owner_login="${REPO%%/*}"
  while IFS= read -r url; do
    [ -n "$url" ] || continue
    cid="${url##*issuecomment-}"
    author="$(gh api "repos/${REPO}/issues/comments/${cid}" --jq .user.login 2>/dev/null)" ||
      refuse "**owner 定案** 的评论链接读不到：${url}" "核对链接，或去掉这个字段走 needs:product。"
    [ "$author" = "$owner_login" ] ||
      refuse "**owner 定案** 的评论作者是「${author:-未知}」，不是仓库 owner「${owner_login}」：${url}" \
        "只认仓库 owner 账号的评论；别人的话不算依据。"
    nbasis=$((nbasis + 1))
  done <<EOF2
$(printf '%s\n' "$basis" | grep -oE "https://github\.com/${REPO}/(issues|pull)/[0-9]+#issuecomment-[0-9]+" | sort -u)
EOF2
  [ "$nbasis" -gt 0 ] ||
    refuse "**owner 定案** 里没有可校验的依据" "写 AGENTS.md「<原文>」或仓库 owner 的评论链接；没有依据就去掉这个字段。"
  OWNER_DECIDED=1
fi
PRODUCT=0
is_none 用户可见行为 || { PRODUCT=1; REASONS="${REASONS}用户可见行为；"; }
is_none_full 隐私 || { PRODUCT=1; REASONS="${REASONS}隐私；"; }
is_none_full 数据 || { PRODUCT=1; REASONS="${REASONS}数据去留；"; }
[ "$UI" = false ] || { PRODUCT=1; REASONS="${REASONS}范围碰到界面或文案路径；"; }
PRODUCT_DECIDED=0
[ -z "$DECIDED" ] || PRODUCT_DECIDED=1
[ "$PRODUCT_COMMENTS" -eq 0 ] || PRODUCT_DECIDED=1
[ "$PRODUCT_DECIDED" = 0 ] || PRODUCT=0
# 只在本来要 needs:product 时才用得上 owner 定案 / 标准依据；隐私或数据不是「无」、或 Feature 卡，owner 不能代定。
USED_OWNER=0
USED_STANDARD=0
if [ "$PRODUCT" = 1 ] && { [ "$OWNER_DECIDED" = 1 ] || [ "$STANDARD_OK" = 1 ]; }; then
  if is_none_full 隐私 && is_none_full 数据; then
    itype="$(gh api "repos/${REPO}/issues/${N}" --jq '.type.name // ""' 2>/dev/null | tr -d '\r')" ||
      refuse "读不到 #${N} 的卡类型，判断不了 owner 定案是否适用" "稍后重跑。"
    if [ "$itype" != Feature ]; then
      [ "$OWNER_DECIDED" = 0 ] || { PRODUCT=0; USED_OWNER=1; }
      [ "$STANDARD_OK" = 0 ] || { PRODUCT=0; USED_STANDARD=1; }
    fi
  fi
  if [ "$OWNER_DECIDED" = 1 ] && [ "$USED_OWNER" = 0 ]; then
    REASONS="${REASONS}owner 定案不适用（隐私或数据非「无」，或 Feature 卡）；"
  fi
  if [ "$STANDARD_OK" = 1 ] && [ "$USED_STANDARD" = 0 ]; then
    REASONS="${REASONS}标准依据不适用（隐私或数据非「无」，或 Feature 卡）；"
  fi
fi
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
[ "$DECISION" = ready ] || { USED_OWNER=0; USED_STANDARD=0; }

# 写回 issue 正文。
printf '%s\n' "$ISSUE_BODY" >"${TMPD}/body"
CORE_TXT="否（范围不命中 .github/core-paths.txt）"
[ "$CORE" = false ] || CORE_TXT="是（定案：$(printf '%s' "${ADRS:-无}" | tr '\n' ' ')）"
python3 -I -X utf8 - "${TMPD}" "$CORE_TXT" "$DECISION" "${REASONS%；}" "$PRIO" "$PRIO_WHY" <<'PY'
import re, sys, pathlib
d = pathlib.Path(sys.argv[1]); core_txt, decision, reasons, prio, prio_why = sys.argv[2:7]
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

scope, accept, repro = f("范围"), f("验收场景"), f("复现路径")
extra = []
b = set_field(body, "范围", scope, block=True)
if b is None:
    extra.append("**范围（只许动这些）**：\n```\n" + scope + "\n```\n")
else:
    body = b
b = set_field(body, "复现路径", repro)
if b is None:
    extra.append("**复现路径**：\n" + repro + "\n")
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
for k in ("做法", "涉及端", "数据", "用户可见行为", "隐私", "风险", "影响", "时间性", "ADR", "产品定案", "标准依据", "owner 定案"):
    if f(k):
        sec.append("**" + k + "**：" + f(k) + "\n")
if decision == "needs:product":
    sec.append("**需要产品负责人拍板**（" + reasons + "）：\n")
    sec.append("1. " + f("选项一"))
    sec.append("2. " + f("选项二") + "\n")
sec.append("**优先级**：`P" + prio + "`（" + prio_why + "）\n")
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
# 打优先级标签：去掉这张卡上其它的 P0–P3，再加新的（替换，不叠加）。
OLD_P=""
for l in $(printf '%s' "$ISSUE_LABELS" | tr ',' ' '); do
  case "$l" in P[0-3]) [ "$l" = "P${PRIO}" ] || OLD_P="${OLD_P:+${OLD_P},}${l}" ;; esac
done
if [ -n "$OLD_P" ]; then
  gh issue edit "$N" -R "$REPO" --add-label "P${PRIO}" --remove-label "$OLD_P" >/dev/null || die_stuck "给 #${N} 换优先级标签失败"
else
  gh issue edit "$N" -R "$REPO" --add-label "P${PRIO}" >/dev/null || die_stuck "给 #${N} 打优先级标签失败"
fi
case "$DECISION" in
  blocked)
    case "${REASONS}" in
      *复现路径*)
        msg="Bug 卡缺「复现路径」（方案里要有 100% 复现的步骤/命令）。复现不了就先补日志/护栏，或转 needs:product 找人对齐，再重跑 just triage" ;;
      *)
        msg="范围命中核心（.github/core-paths.txt），方案没有引用 origin/main 上「已采纳」的 ADR。先按 AGENTS.md 红线 6 写 ADR（docs/decisions/）并定案，再重跑 just triage" ;;
    esac
    bash "${FLOW_DIR}/owner-stuck.sh" "$msg" --issue "$N" ||
      die_stuck "把 #${N} 打成 status:blocked 失败"
    ;;
  needs:product)
    [ "$CORE" = false ] || gh issue edit "$N" -R "$REPO" --add-label core >/dev/null
    gh issue edit "$N" -R "$REPO" --add-label needs:product >/dev/null || die_stuck "给 #${N} 打 needs:product 失败"
    ;;
  ready)
    [ "$CORE" = false ] || gh issue edit "$N" -R "$REPO" --add-label core >/dev/null
    [ "$USED_OWNER" = 0 ] && [ "$USED_STANDARD" = 0 ] ||
      gh issue edit "$N" -R "$REPO" --add-label decided:owner >/dev/null || die_stuck "给 #${N} 打 decided:owner 失败"
    had_needs=0
    has_label needs:product && had_needs=1
    set_status "$N" status:ready || die_stuck "把 #${N} 换成 status:ready 失败"
    # 重跑分拣时，旧的「等产品拍板」不能和 ready / decided:owner 叠在一起（#1551）。
    if [ "$had_needs" = 1 ]; then
      gh issue edit "$N" -R "$REPO" --remove-label needs:product >/dev/null || die_stuck "摘掉 #${N} 的 needs:product 失败"
    fi
    ;;
esac
printf 'TRIAGE %s %s\nPRIORITY %s P%s\n' "$N" "$DECISION" "$N" "$PRIO"
