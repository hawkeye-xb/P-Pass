# 读屏语义回归（#1801）：设置页 / 备份范围页 / 两个单次入口选择器 / 看图页逐页 uiautomator dump，
# 判 TalkBack 消费的语义口径：
#   开关行整行一个语义节点——checkable + checked 报开合、名称合并在行子树、行内 Switch 不单独暴露；
#   相册卡 checkable + checked 选中态、带「相册/Album」类型 desc、选中卡带「已选择/Selected」角标；
#   单次入口两行整行可点（Role.Button 的 a11y 体现 = className Button）、不是勾选项；
#   点卡真的翻转选中态——同一张卡（按 bounds 认卡）在点前点后两份 dump 里 checked 相反，
#   点击 no-op（两份 dump 一模一样）判红；
#   上述可点行触控目标 ≥48dp。
# 判据全部来自 #1801 第三轮真机实测（.evidence/1801/round3/ 的 dump 与报告 §五），
# E2 侧有同一口径的 instrumented 测试（apps/android app/src/androidTest .../ui/accessibility/）。
#
# 需要：候选 debug 包（apps/android assembleDebug 或 just verify 编出；E3_ANDROID_APK 可指定路径）
# 与配对桩（ensure_paired 自动起桩/装包/配对，范围固定为专用测试相册）。
# 语种：默认 zh-CN en-US 两语都跑（判据按语种查表）；E3_A11Y_LOCALES 可覆盖。
# 选择器页（系统 Photo Picker / SAF）是系统组件，判据只认「点进去了且界面在」：
# dump 可解析、有可点节点——不按文案判（系统页语言不随 App 语种）。
# 大字体档位的场景见 a11y-bigfont。
DESC="逐页读屏语义：开关行整行报名称与开合、相册卡带类型与选中态、单次入口可点、点卡真翻转、触控目标 ≥48dp"
COUNTER=off
LOCALES="${E3_A11Y_LOCALES:-zh-CN en-US}"

setup() {
  # 没编候选包就整场 SKIP（77）：语义回归必须在候选包上跑，不能拿旧包出绿。
  [ -f "$(cand_apk)" ] || { echo "缺候选 debug 包：apps/android assembleDebug（或 just verify 编包）；E3_ANDROID_APK 可指定路径"; return 77; }
  ensure_paired "$EV" || return 1
  # 看图页要有内容可点：照片 tab 显示的是已备份的照片，桩里至少要有 3 张
  # （重配对抹掉 App 数据后账本会空，看图页走不动；走法同 android-thumb 的素材准备）。
  ensure_photos 3 R4 || { echo "桩里备不出照片，看图页会是空网格"; return 1; }
  A shell cmd locale get-app-locales "$PKG" >"$EV/locale-before.txt" 2>/dev/null
  logcat_clear
}

set_locale() {
  app_stop
  A shell cmd locale set-app-locales "$PKG" --locales "$1" >/dev/null || { echo "set-app-locales $1 失败"; return 1; }
}

# get-app-locales 回读形如「[zh-CN]」；空（没设过 per-app locale）回「[empty]」或空括号。
# 还原时还原成解析出的语种；原本没设过就还原成空列表（跟随系统）——
# Android 15+ 的 cmd locale 没有 clear-app-locales 子命令，set-app-locales 不带
# --locales 即恢复为空列表（PR #1885 评审核实）。
parse_locales() { sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$1" 2>/dev/null | tail -1 | tr -d ' '; }

restore_locale() {
  local before
  [ -f "$EV/locale-before.txt" ] || return 0
  before=$(parse_locales "$EV/locale-before.txt")
  case "$before" in
    "" | "empty")
      A shell cmd locale set-app-locales "$PKG" >/dev/null 2>&1
      ;;
    *)
      A shell cmd locale set-app-locales "$PKG" --locales "$before" >/dev/null 2>&1
      ;;
  esac
}

density_dpi() { A shell wm density | grep -oE '[0-9]+' | tail -1; }

# 范围页第一张相册卡：按类型 desc（相册/Album）找卡，向上找 checkable+clickable 的卡节点。
# 不能用 ui.py square——相册卡不是正方形，时间筛选 chip 也会先被匹配。
# 输出四段：中心 x、中心 y、卡 bounds 原文、点前 checked——bounds 是「认卡」凭据，
# judge 用同一 bounds 在点前/点后两份 dump 里对同一张卡判翻转。
scope_first_card() {
  python3 -I - "$UI_XML" <<'PY'
import re, sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
parent = {c: p for p in root.iter('node') for c in p}
for n in root.iter('node'):
    if (n.get('content-desc') or '') in ('相册', 'Album'):
        cur = n
        while cur is not None:
            if cur.get('checkable') == 'true' and cur.get('clickable') == 'true':
                x1, y1, x2, y2 = map(int, re.findall(r'\d+', n.get('bounds') or '[0,0][0,0]'))
                print((x1 + x2) // 2, (y1 + y2) // 2, cur.get('bounds'), cur.get('checked'))
                sys.exit(0)
            cur = parent.get(cur)
sys.exit(1)
PY
}

# 底部 tab 只认「文本恰好是 [label] 且有可点祖先」的节点：设置页的英雄句里也有
# 「照片」二字，ui_find 按子串会先命中它、点在不可点的空处（round4 踩过）。
# 先重新 dump：UI_XML 可能还是上一个页面（比如范围页）的旧内容。
tap_bottom_tab() {
  ui_dump >/dev/null || return 1
  local xy
  xy=$(python3 -I - "$UI_XML" "$1" <<'PY'
import re, sys
import xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
parent = {c: p for p in root.iter('node') for c in p}
want = sys.argv[2]
for n in root.iter('node'):
    if n.get('text') == want or n.get('content-desc') == want:
        cur = n
        while cur is not None:
            if cur.get('clickable') == 'true':
                x1, y1, x2, y2 = map(int, re.findall(r'\d+', cur.get('bounds')))
                print((x1 + x2) // 2, (y1 + y2) // 2)
                sys.exit(0)
            cur = parent.get(cur)
sys.exit(1)
PY
) || return 1
  fg_guard && tap_xy "$xy"
}

# 看图页：照片 tab → 网格第一格 → 大图页 dump + 截图（走法同 tools/e3/lib/android-thumb.sh observe）。
capture_viewer() {
  local d="$1" xy
  tap_bottom_tab 照片 || tap_bottom_tab Photos || { ui_dump "$d/viewer-nav-fail.xml"; return 1; }
  sleep 2
  ui_dump >/dev/null && dismiss_update
  xy=$(first_cell_xy) || { ui_dump "$d/viewer-nav-fail.xml"; echo "网格没有第一格可点"; return 1; }
  fg_guard && tap_xy "$xy" || return 1
  sleep 4
  ui_dump "$d/viewer.xml"
  shot "$d/viewer.png"
  fg_guard && A shell input keyevent BACK
  sleep 2
}

# 回到本 App 前台：系统选择器有时一次 BACK 吃不掉（动画期丢键/叠在 App 任务上）；
# 前台是桌面说明 App 没起来（冷启动偶发慢于窗口期），重新拉起。循环最多 4 次，
# 还出不来就报错，不带病继续点 App 的控件。
back_to_app() {
  local i
  for i in 1 2 3 4; do
    fg | grep -q "${PKG//./\\.}" && return 0
    if fg | grep -q "launcher"; then
      app_start
      sleep 2
    else
      A shell input keyevent BACK
      sleep 1.5
    fi
  done
  fg | grep -q "${PKG//./\\.}" || { echo "退不回 App 前台（前台：$(fg)）"; return 1; }
}

# 系统选择器只取证不点选：dump + 截图后原路 BACK，不碰里面的任何控件。
capture_picker() {
  local d="$1" label="$2" out="$3"
  tap_text "$label" || { ui_dump "$d/$out-nav-fail.xml"; return 1; }
  sleep 3
  ui_dump "$d/$out.xml"
  shot "$d/$out.png"
  back_to_app || { ui_dump "$d/$out-exit-fail.xml"; return 1; }
  sleep 1
}

act() {
  for loc in $LOCALES; do
    set_locale "$loc" || return 1
    # 逐页取证写 $OUT（judge 读的就是这个目录）；运行级状态（配对、原语种快照）才进 $EV
    local d="$OUT/$loc"
    mkdir -p "$d"
    A shell cmd locale get-app-locales "$PKG" >"$d/locale-set.txt" 2>/dev/null
    app_start
    sleep 4
    ui_dump >/dev/null && dismiss_update
    # 上一场留下的系统页（选择器等）可能还叠在前台：先回到 App 再点
    back_to_app || return 1
    ui_dump >/dev/null && dismiss_update
    # 设置 tab（底部第二个）：照片页 → 设置页
    tap_text "设置|Settings" || { ui_dump "$d/nav-fail.xml"; return 1; }
    sleep 1.5
    density_dpi >"$d/density.txt"
    ui_dump "$d/settings.xml"
    shot "$d/settings.png"
    # 单次入口两行逐个点进系统选择器（Photo Picker / SAF），取证后 BACK 出来
    capture_picker "$d" "从相册选择|Choose from Photos" "picker-photos" || return 1
    capture_picker "$d" "从文件选择|Choose from Files" "picker-files" || return 1
    # 备份范围行 → 范围页（相册卡）
    tap_text "备份范围|Backup range" || { ui_dump "$d/scope-nav-fail.xml"; return 1; }
    sleep 1.5
    ui_dump "$d/scope-open.xml"
    shot "$d/scope-open.png"
    # 点第一张相册卡翻转选中态：先把「认卡凭据」记下来（bounds + 点前 checked），
    # 再 dump 一次——judge 按同一 bounds 判这张卡 checked 真的翻转了
    local card
    if card=$(scope_first_card); then
      set -- $card
      echo "$3 $4" >"$d/flip.txt"
      fg_guard && tap_xy "$1 $2"
      sleep 1.5
      ui_dump "$d/scope-toggled.xml"
      shot "$d/scope-toggled.png"
    else
      echo "范围页没有相册卡可点（测试相册没入库？）"; return 1
    fi
    A shell input keyevent BACK
    sleep 1.5
    capture_viewer "$d" || return 1
    app_stop
  done
  logcat_save "$OUT/logcat.txt"
  A logcat -d -b crash >"$OUT/crash.txt" 2>/dev/null
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
                  entry=['从相册选择', '从文件选择'], kind='相册', selected='已选择',
                  viewer_back='返回'),
    'en-US': dict(switch=['Auto backup', 'Back up only on Wi-Fi', 'Notifications'],
                  entry=['Choose from Photos', 'Choose from Files'], kind='Album', selected='Selected',
                  viewer_back='Back'),
}
# 每个语种目录必须齐的取证（缺哪份点名哪份，不再忽略缺失文件）
REQUIRED = ['settings.xml', 'scope-open.xml', 'scope-toggled.xml',
            'picker-photos.xml', 'picker-files.xml', 'viewer.xml', 'density.txt']

def load(path):
    try:
        root = ET.parse(path).getroot()
    except Exception:
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

locale_dirs = [d for d in sorted(root_dir.iterdir()) if d.is_dir() and d.name in LANG]
if not locale_dirs:
    fails.append(f"没有任何语种证据目录（判据表只认 {sorted(LANG)}；act 没跑完？）")

for d in locale_dirs:
    L = LANG[d.name]
    for name in REQUIRED:
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

    # 3. 单次入口点进去的选择器页（系统 Photo Picker / SAF，系统组件不按文案判）：
    #    dump 可解析、界面上至少有一个可点节点——「点进去了」的语义证据
    for name in ('picker-photos.xml', 'picker-files.xml'):
        p = d / name
        if not p.is_file(): continue
        loaded = load(p)
        if loaded is None:
            fails.append(f"{d.name}/{name} 解析失败")
            continue
        nodes, _, _ = loaded
        check(any(x.get('clickable') == 'true' for x in nodes),
              f"{d.name}/{name} 里没有任何可点节点（没点进选择器？）")

    # 4. 看图页：dump 可解析、带「返回」出口——真实形状是可点容器在外、cd=返回 在子树
    viewer = d / 'viewer.xml'
    if viewer.is_file():
        loaded = load(viewer)
        if loaded is None:
            fails.append(f"{d.name}/viewer.xml 解析失败")
        else:
            nodes, parent, children = loaded
            def subtree_has_back(x):
                stack = [x]
                while stack:
                    cur = stack.pop()
                    if cd_of(cur) == L['viewer_back']:
                        return True
                    stack.extend(children.get(cur, []))
                return False
            check(any(x.get('clickable') == 'true' and subtree_has_back(x) for x in nodes),
                  f"{d.name}/viewer.xml 要带可点的「{L['viewer_back']}」出口（没走到看图页？）")

    # 5. 相册卡：带类型 desc 的卡 = checkable + clickable；选中卡子树带「已选择」角标、未选卡没有
    dumps = {}
    for name in ('scope-open.xml', 'scope-toggled.xml'):
        p = d / name
        if not p.is_file(): continue
        loaded = load(p)
        if loaded is None:
            fails.append(f"{d.name}/{name} 解析失败")
            continue
        dumps[name] = loaded
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
    check(len(dumps) == 2, f"{d.name} 范围页 open/toggled 两份 dump 必须齐（有翻转对照才有「选中」语义可判）")
    if len(dumps) == 2:
        # 5a. 选中态角标与状态一致（两份 dump 合计看）
        for name, (nodes, parent, children) in dumps.items():
            for n in (x for x in nodes if cd_of(x) == L['kind']):
                card = ancestor(n, parent, lambda c: c.get('checkable') == 'true')
                if card is None: continue
                sub = subtree(card, children)
                if card.get('checked') == 'true':
                    check(any(cd_of(c) == L['selected'] for c in sub),
                          f"{d.name}/{name} 选中卡子树要带「{L['selected']}」角标 desc")
                else:
                    check(not any(cd_of(c) == L['selected'] for c in sub),
                          f"{d.name}/{name} 未选卡子树不许有「{L['selected']}」角标 desc")
        # 5b. 点卡必须真翻转（#1885 评审：两份 dump 合计有选中与未选两态判不出点击 no-op）——
        #     按 act 记下的认卡凭据（bounds）找到同一张卡，checked 必须相反
        flip_line = (d / 'flip.txt').read_text().split() if (d / 'flip.txt').is_file() else []
        if len(flip_line) != 2:
            fails.append(f"{d.name}/flip.txt 缺失或格式不对（act 没记下被点卡的凭据？）")
        else:
            bnds, before = flip_line
            def card_checked(nodes, parent, bnds):
                for x in nodes:
                    if x.get('bounds') == bnds and x.get('checkable') == 'true' and x.get('clickable') == 'true':
                        return x.get('checked')
                return None
            c_open = card_checked(dumps['scope-open.xml'][0], dumps['scope-open.xml'][1], bnds)
            c_tog = card_checked(dumps['scope-toggled.xml'][0], dumps['scope-toggled.xml'][1], bnds)
            check(c_open is not None and c_open == before,
                  f"{d.name} 点前 dump 里找不到被点卡 {bnds}（checked={before}）——页面变过？")
            check(c_tog is not None and c_tog != before,
                  f"{d.name} 被点卡 {bnds} 的 checked 点后必须翻转（点前 {before}，点后 {c_tog}）——点击没生效？")

for m in oks: print("ok", m)
for m in fails: print("FAIL", m)
sys.exit(1 if fails else 0)
PYEOF
}
