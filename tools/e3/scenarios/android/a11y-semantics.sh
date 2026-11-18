# 读屏语义回归（#1801）：设置页 / 备份范围页逐页 uiautomator dump，判 TalkBack 消费的语义口径：
#   开关行整行一个语义节点——checkable + checked 报开合、名称合并在行子树、行内 Switch 不单独暴露；
#   相册卡 checkable + checked 选中态、带「相册/Album」类型 desc、选中卡带「已选择/Selected」角标；
#   单次入口两行整行可点（Role.Button 的 a11y 体现 = className Button）、不是勾选项；
#   上述可点行触控目标 ≥48dp。
# 判据全部来自 #1801 第三轮真机实测（.evidence/1801/round3/ 的 dump 与报告 §五），
# E2 侧有同一口径的 instrumented 测试（apps/android app/src/androidTest .../ui/accessibility/）。
#
# 需要：候选 debug 包（apps/android assembleDebug 或 just verify 编出；E3_ANDROID_APK 可指定路径）
# 与配对桩（ensure_paired 自动起桩/装包/配对，范围固定为专用测试相册）。
# 语种：默认 zh-CN；E3_A11Y_LOCALES="zh-CN en-US" 可跑两语（判据按语种查表）。
# 大字体档位的场景见 a11y-bigfont。
DESC="逐页读屏语义：开关行整行报名称与开合、相册卡带类型与选中态、单次入口可点、触控目标 ≥48dp"
COUNTER=off
LOCALES="${E3_A11Y_LOCALES:-zh-CN}"

setup() {
  # 没编候选包就整场 SKIP（77）：语义回归必须在候选包上跑，不能拿旧包出绿。
  [ -f "$(cand_apk)" ] || { echo "缺候选 debug 包：apps/android assembleDebug（或 just verify 编包）；E3_ANDROID_APK 可指定路径"; return 77; }
  ensure_paired "$EV" || return 1
  A shell cmd locale get-app-locales "$PKG" >"$EV/locale-before.txt" 2>/dev/null
  logcat_clear
}

set_locale() {
  app_stop
  A shell cmd locale set-app-locales "$PKG" --locales "$1" >/dev/null || { echo "set-app-locales $1 失败"; return 1; }
}

# get-app-locales 回读形如「[zh-CN]」；空（没设过 per-app locale）回「[empty]」或空括号。
# 还原时还原成解析出的语种；原本没设过就 clear 掉，不留本场留下的语种。
parse_locales() { sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$1" 2>/dev/null | tail -1 | tr -d ' '; }

restore_locale() {
  local before
  before=$(parse_locales "$EV/locale-before.txt")
  case "$before" in
    "" | "empty")
      A shell cmd locale clear-app-locales "$PKG" >/dev/null 2>&1
      ;;
    *)
      A shell cmd locale set-app-locales "$PKG" --locales "$before" >/dev/null 2>&1
      ;;
  esac
}

density_dpi() { A shell wm density | grep -oE '[0-9]+' | tail -1; }

# 范围页第一张相册卡的中心：按类型 desc（相册/Album）找卡，向上找 checkable+clickable 的卡节点。
# 不能用 ui.py square——相册卡不是正方形，时间筛选 chip 也会先被匹配。
scope_first_card_xy() {
  python3 -I - "$UI_XML" <<'PY'
import re, sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
parent = {c: p for p in root.iter('node') for c in p}
def center(n):
    x1, y1, x2, y2 = map(int, re.findall(r'\d+', n.get('bounds') or '[0,0][0,0]'))
    return (x1 + x2) // 2, (y1 + y2) // 2
for n in root.iter('node'):
    if (n.get('content-desc') or '') in ('相册', 'Album'):
        cur = n
        while cur is not None:
            if cur.get('checkable') == 'true' and cur.get('clickable') == 'true':
                print(*center(cur))
                sys.exit(0)
            cur = parent.get(cur)
sys.exit(1)
PY
}

act() {
  for loc in $LOCALES; do
    set_locale "$loc" || return 1
    local d="$EV/$loc"
    mkdir -p "$d"
    A shell cmd locale get-app-locales "$PKG" >"$d/locale-set.txt" 2>/dev/null
    app_start
    sleep 4
    ui_dump >/dev/null && dismiss_update
    # 设置 tab（底部第二个）：照片页 → 设置页
    tap_text "设置|Settings" || { ui_dump "$d/nav-fail.xml"; return 1; }
    sleep 1.5
    density_dpi >"$d/density.txt"
    ui_dump "$d/settings.xml"
    shot "$d/settings.png"
    # 备份范围行 → 范围页（相册卡）
    tap_text "备份范围|Backup range" || { ui_dump "$d/scope-nav-fail.xml"; return 1; }
    sleep 1.5
    ui_dump "$d/scope-open.xml"
    shot "$d/scope-open.png"
    # 点第一张相册卡翻转选中态，再 dump 一次——两态对照才有「选中」语义可判
    local xy
    if xy=$(scope_first_card_xy); then
      fg_guard && tap_xy "$xy"
      sleep 1.5
      ui_dump "$d/scope-toggled.xml"
      shot "$d/scope-toggled.png"
    else
      echo "范围页没有相册卡可点（测试相册没入库？）"; return 1
    fi
    app_stop
  done
  logcat_save "$EV/logcat.txt"
  A logcat -d -b crash >"$EV/crash.txt" 2>/dev/null
}

teardown() {
  restore_locale
  # 本场不改字号；这里只防其它场景留下的 1.5x 残留读数没有依据，不强制恢复。
  app_stop 2>/dev/null
  :
}

judge() {
  python3 -I - "$1" <<'PYEOF'
import re, sys
import xml.etree.ElementTree as ET
from pathlib import Path

root_dir = Path(sys.argv[1])
fails, oks = [], []

def check(cond, msg):
    (oks if cond else fails).append(msg)

LANG = {
    'zh-CN': dict(switch=['自动备份', '仅 Wi-Fi 时备份', '通知'],
                  entry=['从相册选择', '从文件选择'], kind='相册', selected='已选择'),
    'en-US': dict(switch=['Auto backup', 'Back up only on Wi-Fi', 'Notifications'],
                  entry=['Choose from Photos', 'Choose from Files'], kind='Album', selected='Selected'),
}

def load(path):
    try:
        root = ET.parse(path).getroot()
    except Exception as e:
        return None
    parent = {c: p for p in root.iter('node') for c in p}
    children = {}
    for n, p in parent.items():
        children.setdefault(p, []).append(n)
    return list(root.iter('node')), parent, children

def text_of(n): return n.get('text') or ''
def cd_of(n): return n.get('content-desc') or ''
def bounds(n): return tuple(map(int, re.findall(r'\d+', n.get('bounds') or '[0,0][0,0]')))
def height_dp(n, dpi): x1, y1, x2, y2 = bounds(n); return (y2 - y1) * 160.0 / dpi

def ancestor(n, parent, pred):
    cur = n
    while cur is not None:
        if pred(cur): return cur
        cur = parent.get(cur)
    return None

def subtree(root, children):
    out, stack = [], [root]
    while stack:
        cur = stack.pop()
        out.append(cur)
        stack.extend(children.get(cur, []))
    return out

for d in sorted(root_dir.iterdir()):
    if not d.is_dir(): continue
    if d.name not in LANG:
        fails.append(f"目录 {d.name} 不是已知语种（判据表只认 {sorted(LANG)}）")
        continue
    L = LANG[d.name]
    for name in ('settings.xml', 'scope-open.xml', 'scope-toggled.xml'):
        if not (d / name).is_file():
            fails.append(f"{d.name}/{name} 缺证据（act 没跑完？）")
    if not (d / 'density.txt').is_file():
        fails.append(f"{d.name}/density.txt 缺失，触控目标换算不了")
        continue
    dpi = float((d / 'density.txt').read_text().strip() or 0)
    if dpi <= 0:
        fails.append(f"{d.name}/density.txt 内容不是 dpi：{(d / 'density.txt').read_text()!r}")
        continue
    loaded = load(d / 'settings.xml') if (d / 'settings.xml').is_file() else None
    if loaded is None:
        fails.append(f"{d.name}/settings.xml 缺失或解析失败")
        continue
    settings, sparent, schildren = loaded

    # 1. 开关行：名称 → 最近 checkable 祖先 = 整行；行子树里只有行自己一个 checkable；行高 ≥48dp
    for label in L['switch']:
        row = None
        for n in (x for x in settings if text_of(x) == label):
            row = ancestor(n, sparent, lambda c: c.get('checkable') == 'true')
            if row is not None: break
        check(row is not None, f"{d.name} 开关行「{label}」必须整行 checkable（名称合并在行上）")
        if row is None: continue
        sub = subtree(row, schildren)
        check(sum(1 for c in sub if c.get('checkable') == 'true') == 1,
              f"{d.name} 开关行「{label}」行内开关不许单独暴露 checkable 子节点")
        check(row.get('clickable') == 'true', f"{d.name} 开关行「{label}」必须整行可点")
        check(height_dp(row, dpi) >= 48.0,
              f"{d.name} 开关行「{label}」高 {height_dp(row, dpi):.1f}dp < 48dp（触控目标）")

    # 2. 单次入口两行：整行可点、不是勾选项、带 Role.Button 的 a11y 体现（className Button）
    for label in L['entry']:
        row = None
        for n in (x for x in settings if text_of(x) == label):
            row = ancestor(n, sparent, lambda c: c.get('clickable') == 'true')
            if row is not None: break
        check(row is not None, f"{d.name} 单次入口行「{label}」必须整行可点")
        if row is None: continue
        check(row.get('checkable') != 'true', f"{d.name} 入口行「{label}」不是勾选项")
        sub = subtree(row, schildren)
        check(any((c.get('class') or '').endswith('Button') for c in sub),
              f"{d.name} 入口行「{label}」要带 Role.Button 的 a11y 体现（className Button）")
        check(height_dp(row, dpi) >= 48.0,
              f"{d.name} 入口行「{label}」高 {height_dp(row, dpi):.1f}dp < 48dp（触控目标）")

    # 3. 相册卡：带类型 desc 的卡 = checkable + clickable；两份 dump 合计有选中与未选两态；
    #    选中卡子树带「已选择」角标、未选卡没有
    cards_by_state = {True: [], False: []}
    for name in ('scope-open.xml', 'scope-toggled.xml'):
        p = d / name
        if not p.is_file(): continue
        loaded = load(p)
        if loaded is None:
            fails.append(f"{d.name}/{name} 解析失败")
            continue
        nodes, parent, children = loaded
        seen = set()
        for n in (x for x in nodes if cd_of(x) == L['kind']):
            card = ancestor(n, parent, lambda c: c.get('checkable') == 'true')
            if card is None:
                check(False, f"{d.name}/{name} 带「{L['kind']}」desc 的卡没有 checkable 祖先（选中语义不在卡上）")
                continue
            if id(card) in seen: continue
            seen.add(id(card))
            check(card.get('clickable') == 'true', f"{d.name}/{name} 相册卡必须整卡可点")
            cards_by_state[card.get('checked') == 'true'].append((name, card, children))
    check(len(cards_by_state[True] + cards_by_state[False]) >= 1,
          f"{d.name} 范围页要有带「{L['kind']}」类型 desc 的相册卡（测试相册没入库或没进范围页）")
    check(len(cards_by_state[True]) >= 1 and len(cards_by_state[False]) >= 1,
          f"{d.name} 两份范围页 dump 合计要有选中与未选两态（act 的卡片翻转没生效？）")
    for name, card, children in cards_by_state[True]:
        check(any(cd_of(c) == L['selected'] for c in subtree(card, children)),
              f"{d.name}/{name} 选中卡子树要带「{L['selected']}」角标 desc")
    for name, card, children in cards_by_state[False]:
        check(not any(cd_of(c) == L['selected'] for c in subtree(card, children)),
              f"{d.name}/{name} 未选卡子树不许有「{L['selected']}」角标 desc")

for m in oks: print("ok", m)
for m in fails: print("FAIL", m)
sys.exit(1 if fails else 0)
PYEOF
}
