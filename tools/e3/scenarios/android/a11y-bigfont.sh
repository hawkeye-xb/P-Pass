# 大字体与减少动态效果取证（#1801）：系统字体 1.5x + 动画全关，设置页（顶部与滚动后）、
# 备份范围页与看图页逐页 dump + 截图。
# 判据（当前实现下全绿）：
#   1. 关键文本（三个开关行、两个单次入口行）在控件树里；
#   2. 相册卡带类型 desc 与 checkable（选中语义不丢）；
#   3. 看图页走到且带「返回」可点节点；
#   4. crash buffer 干净；
#   5. 触控目标 48dp 硬判红——任何可点节点 <48dp 都 FAIL，只有一条显式豁免：
#      a) 被滚动视口裁掉半截的行（dump 只见可见部分，真实高度要对相邻行看，
#         不是真小目标）——仍记 WARN 量表；
#   6. 最大字体「无关键截断」归人工判定：dump 里 a11y 文本永远是全文，视觉截断
#      （Ellipsis/断词）只能看截图。judge 强制要求 manual-bigfont.md 里有且只有一行
#      「判定：无关键截断」或「判定：有关键截断」——不写、写别的 = 红；写了「有关键截断」= 红。
#      （#1885 评审阻断 4：不许留空、不许只有 WARN 量表没有结论。）
#      跑法因此是两步：`tools/e3/run …`（act + 判定，此时 judge 红在「缺人工判定」）→
#      看本轮截图后在场景 main 目录（judge 读的目录）写 manual-bigfont.md →
#      `tools/e3/run judge android/a11y-bigfont <main目录>` 出最终结论；两次输出都留在证据里。
#   7. 系统设置回读（#1888）：act 逐语种把实际生效的 font_scale 与三个动画缩放 `settings get`
#      回读进 `${lang}/scales.txt`，judge 断言 font_scale=1.5、三个动画缩放=0——put 静默失败
#      （写入没生效）会让证据其实是 1.0x，不许判过。
#
# 需要：候选 debug 包与配对桩（同 a11y-semantics）。语种默认 zh-CN en-US 两语都跑。
DESC="1.5x 大字体+减少动态效果逐页取证：关键信息仍在、无崩溃、48dp 硬判红、截断归人工判定"
COUNTER=off
LOCALES="${E3_A11Y_LOCALES:-zh-CN en-US}"

setup() {
  [ -f "$(cand_apk)" ] || { echo "缺候选 debug 包：apps/android assembleDebug（或 just verify 编包）；E3_ANDROID_APK 可指定路径"; return 77; }
  ensure_paired "$EV" || return 1
  # 看图页要有内容可点：照片 tab 显示的是已备份的照片，桩里至少要有 3 张
  # （重配对抹掉 App 数据后账本会空，看图页走不动；走法同 android-thumb 的素材准备）。
  ensure_photos 3 R4 || { echo "桩里备不出照片，看图页会是空网格"; return 1; }
  # 原值快照：恢复时按快照还原，不硬编码（#1885 评审：用户自己调过的动画/字号不许被本场改掉）
  A shell cmd locale get-app-locales "$PKG" >"$EV/locale-before.txt" 2>/dev/null
  A shell settings get system font_scale >"$EV/font-scale-before.txt" 2>/dev/null
  A shell settings get global window_animation_scale >"$EV/anim-window-before.txt" 2>/dev/null
  A shell settings get global transition_animation_scale >"$EV/anim-transition-before.txt" 2>/dev/null
  A shell settings get global animator_duration_scale >"$EV/anim-animator-before.txt" 2>/dev/null
  logcat_clear
}

set_locale() {
  app_stop
  A shell cmd locale set-app-locales "$PKG" --locales "$1" >/dev/null || { echo "set-app-locales $1 失败"; return 1; }
}

parse_locales() { sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$1" 2>/dev/null | tail -1 | tr -d ' '; }

restore_locale() {
  local before
  [ -f "$EV/locale-before.txt" ] || return 0
  before=$(parse_locales "$EV/locale-before.txt")
  case "$before" in
    # Android 15+ 的 cmd locale 没有 clear-app-locales 子命令；set-app-locales 不带
    # --locales 即恢复为空列表（跟随系统），PR #1885 评审核实。
    "" | "empty") A shell cmd locale set-app-locales "$PKG" >/dev/null 2>&1 ;;
    *) A shell cmd locale set-app-locales "$PKG" --locales "$before" >/dev/null 2>&1 ;;
  esac
}

# restore_setting <空间:键> <快照文件>：按快照还原；快照缺/是 null = 原本没设 → delete 掉本场写的值
restore_setting() {
  local v
  v=$(cat "$3" 2>/dev/null | tr -d '\r')
  if [ -n "$v" ] && [ "$v" != "null" ]; then
    A shell settings put "$1" "$2" "$v" 2>/dev/null
  else
    A shell settings delete "$1" "$2" 2>/dev/null
  fi
}

density_dpi() { A shell wm density | grep -oE '[0-9]+' | tail -1; }

# 回到本 App 前台：系统页（选择器/别的场景残留）可能叠在 App 任务上，BACK 退一层；
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

# 屏幕中间上滑一屏（按实测屏幕高算坐标，不写死 1080x2340）
swipe_up() {
  local wh
  wh=$(A shell wm size | grep -oE '[0-9]+' | tail -2 | tr '\n' ' ')
  set -- $wh
  local w="${1:-1080}" h="${2:-2340}"
  A shell input swipe $((w / 2)) $((h * 7 / 10)) $((w / 2)) $((h * 3 / 10)) 300
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

act() {
  A shell settings put system font_scale 1.5
  # 减少动态效果（卡上「减少动态效果」一项）：三个动画缩放全关
  A shell settings put global window_animation_scale 0
  A shell settings put global transition_animation_scale 0
  A shell settings put global animator_duration_scale 0
  for loc in $LOCALES; do
    set_locale "$loc" || return 1
    # 逐页取证写 $OUT（judge 读的就是这个目录，manual-bigfont.md 也写这里）；原值快照进 $EV
    local d="$OUT/$loc"
    mkdir -p "$d"
    A shell cmd locale get-app-locales "$PKG" >"$d/locale-set.txt" 2>/dev/null
    # #1888：put 只写不回读会被静默失败骗过——字体其实还是 1.0x 也能判过。逐语种回读
    # 实际生效的字号与三个动画缩放，以 key=value 落盘，judge 按语种断言 1.5 与 0。
    {
      echo "font_scale=$(A shell settings get system font_scale 2>/dev/null | tr -d '\r')"
      echo "window_animation_scale=$(A shell settings get global window_animation_scale 2>/dev/null | tr -d '\r')"
      echo "transition_animation_scale=$(A shell settings get global transition_animation_scale 2>/dev/null | tr -d '\r')"
      echo "animator_duration_scale=$(A shell settings get global animator_duration_scale 2>/dev/null | tr -d '\r')"
    } >"$d/scales.txt"
    app_start
    sleep 5
    ui_dump >/dev/null && dismiss_update
    # 上一场留下的系统页（选择器等）可能还叠在前台：先回到 App 再点
    back_to_app || return 1
    ui_dump >/dev/null && dismiss_update
    tap_text "设置|Settings" || { ui_dump "$d/nav-fail.xml"; return 1; }
    sleep 2
    density_dpi >"$d/density.txt"
    ui_dump "$d/settings.xml"
    shot "$d/settings.png"
    swipe_up
    sleep 1.5
    ui_dump "$d/settings-scrolled.xml"
    shot "$d/settings-scrolled.png"
    tap_text "备份范围|Backup range" || { ui_dump "$d/scope-nav-fail.xml"; return 1; }
    sleep 2
    ui_dump "$d/scope-open.xml"
    shot "$d/scope-open.png"
    A shell input keyevent BACK
    sleep 1.5
    capture_viewer "$d" || return 1
    app_stop
  done
  logcat_save "$OUT/logcat.txt"
  A logcat -d -b crash >"$OUT/crash.txt" 2>/dev/null
}

teardown() {
  # 快照在才有得还原（setup 77/失败早退时什么都不改，也不把别人设置抹掉）
  [ -f "$EV/font-scale-before.txt" ] || { restore_locale; app_stop 2>/dev/null; return 0; }
  restore_setting system font_scale "$EV/font-scale-before.txt"
  restore_setting global window_animation_scale "$EV/anim-window-before.txt"
  restore_setting global transition_animation_scale "$EV/anim-transition-before.txt"
  restore_setting global animator_duration_scale "$EV/anim-animator-before.txt"
  restore_locale
  app_stop 2>/dev/null
  :
}

judge() {
  python3 -I - "$1" <<'PYEOF'
import re, sys
import xml.etree.ElementTree as ET
from pathlib import Path

root_dir = Path(sys.argv[1])
fails, oks, warns = [], [], []

def check(cond, msg):
    (oks if cond else fails).append(msg)

LANG = {
    'zh-CN': dict(switch=['自动备份', '仅 Wi-Fi 时备份', '通知'],
                  entry=['从相册选择', '从文件选择'], kind='相册', viewer_back='返回'),
    'en-US': dict(switch=['Auto backup', 'Back up only on Wi-Fi', 'Notifications'],
                  entry=['Choose from Photos', 'Choose from Files'], kind='Album', viewer_back='Back'),
}
REQUIRED = ['settings.xml', 'settings-scrolled.xml', 'scope-open.xml', 'viewer.xml', 'density.txt']
CLIP_TOL = 8  # px：节点边缘贴着滚动视口边缘 ≤8px 视为被裁剪

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

locale_dirs = [d for d in sorted(root_dir.iterdir()) if d.is_dir() and d.name in LANG]
if not locale_dirs:
    fails.append(f"没有任何语种证据目录（判据表只认 {sorted(LANG)}；act 没跑完？）")

for d in locale_dirs:
    L = LANG[d.name]
    # 逐份点名必需 dump——缺任何一份都红，不把「没滚到底/没走到」当完整结果
    for name in REQUIRED:
        if not (d / name).is_file():
            fails.append(f"{d.name}/{name} 缺证据（act 没跑完？）")
    # 7. 系统设置回读（#1888）：字号必须真是 1.5x、三个动画缩放必须真为 0。put 静默失败
    #    会让证据其实是 1.0x 也判过——这里按语种读回 act 写的 scales.txt 断言。
    scales_path = d / 'scales.txt'
    if not scales_path.is_file():
        fails.append(f"{d.name}/scales.txt 缺失——act 必须回读 font_scale 与三个动画缩放（put 静默失败不许判过）")
    else:
        kv = {}
        for ln in scales_path.read_text(errors='replace').splitlines():
            ln = ln.strip()
            if '=' in ln:
                k, v = ln.split('=', 1)
                kv[k.strip()] = v.strip()
        def _num(s):
            try:
                return float(s)
            except (TypeError, ValueError):
                return None
        fs = _num(kv.get('font_scale'))
        check(fs is not None and abs(fs - 1.5) < 1e-9,
              f"{d.name} font_scale 回读必须为 1.5（实际 {kv.get('font_scale')!r}）——put 静默失败不许判过")
        for key in ('window_animation_scale', 'transition_animation_scale', 'animator_duration_scale'):
            av = _num(kv.get(key))
            check(av is not None and av == 0,
                  f"{d.name} {key} 回读必须为 0（实际 {kv.get(key)!r}）——减少动态效果没生效不许判过")
    if not (d / 'density.txt').is_file():
        fails.append(f"{d.name}/density.txt 缺失，触控目标换算不了")
        continue
    dpi = float((d / 'density.txt').read_text().strip() or 0)
    if dpi <= 0:
        fails.append(f"{d.name}/density.txt 内容不是 dpi")
        continue

    all_nodes = []
    for n in ('settings.xml', 'settings-scrolled.xml'):
        if not (d / n).is_file(): continue
        loaded = load(d / n)
        if loaded is None:
            fails.append(f"{d.name}/{n} 解析失败")
            continue
        all_nodes.append((n, loaded))

    # 1. 关键文本仍在（三开关行 + 两入口行，跨设置页两屏合并看）
    texts = set()
    for _, (ns, _, _) in all_nodes:
        texts.update(text_of(x) for x in ns)
    for label in L['switch'] + L['entry']:
        check(label in texts, f"{d.name} 1.5x 下关键文本「{label}」必须仍在控件树里（截断到读不出来才算红）")

    # 2. 范围页相册卡带类型 desc 与 checkable（选中语义不丢）
    scope_path = d / 'scope-open.xml'
    scope_loaded = load(scope_path) if scope_path.is_file() else None
    if scope_loaded is None:
        fails.append(f"{d.name}/scope-open.xml 缺失或解析失败")
    else:
        nodes, parent, _ = scope_loaded
        kind_nodes = [x for x in nodes if cd_of(x) == L['kind']]
        check(len(kind_nodes) >= 1, f"{d.name} 范围页要有带「{L['kind']}」类型 desc 的相册卡")
        for x in kind_nodes:
            cur, card = x, None
            while cur is not None:
                if cur.get('checkable') == 'true':
                    card = cur
                    break
                cur = parent.get(cur)
            check(card is not None, f"{d.name} 带「{L['kind']}」desc 的卡必须有 checkable 祖先（选中语义不丢）")

    # 3. 看图页：走到且带「返回」出口——真实形状是可点容器在外、cd=返回 在子树
    viewer_path = d / 'viewer.xml'
    if viewer_path.is_file():
        loaded = load(viewer_path)
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

    # 4. 触控目标 48dp 硬判红（唯一豁免：被滚动视口裁剪的可见高度，见文件头 5a）
    for name, loaded in all_nodes + ([(scope_path.name, scope_loaded)] if scope_loaded else []) + \
            ([(viewer_path.name, load(viewer_path))] if viewer_path.is_file() and load(viewer_path) else []):
        nodes, parent, children = loaded
        for x in nodes:
            if x.get('clickable') != 'true': continue
            if height_dp(x, dpi) >= 48.0: continue
            desc = f"{d.name}/{name} 可点节点高 {height_dp(x, dpi):.1f}dp <48dp text={text_of(x)!r} cd={cd_of(x)!r} bounds={x.get('bounds')}"
            x1, y1, x2, y2 = bounds(x)
            clipped = False
            cur = parent.get(x)
            while cur is not None:
                if cur.get('scrollable') == 'true':
                    ax1, ay1, ax2, ay2 = bounds(cur)
                    if y2 >= ay2 - CLIP_TOL or y1 <= ay1 + CLIP_TOL:
                        clipped = True
                    break
                cur = parent.get(cur)
            if clipped:
                warns.append(f"WARN {desc} —— 被滚动视口裁剪的可见高度，不是真小目标")
                continue
            fails.append(f"FAIL {desc}（触控目标 <48dp）")

# 5. 最大字体截断 = 人工判定门（判据见文件头 6）：结论必须落在 manual-bigfont.md，不许空着
manual = root_dir / 'manual-bigfont.md'
if not manual.is_file():
    fails.append("manual-bigfont.md 缺失——最大字体截断归人工判定：看本轮截图（settings/settings-scrolled/"
                 "scope-open/viewer 的 .png），在本场景 main 目录写一行「判定：无关键截断」或「判定：有关键截断（哪页哪句）」")
else:
    verdict = [ln.strip() for ln in manual.read_text(errors='replace').splitlines() if ln.strip().startswith('判定')]
    if len(verdict) != 1:
        fails.append(f"manual-bigfont.md 里「判定：」行必须恰好一行，现在是 {len(verdict)} 行")
    elif '有关键截断' in verdict[0]:
        fails.append(f"人工判定为有关键截断：{verdict[0]}")
    elif '无关键截断' not in verdict[0]:
        fails.append(f"manual-bigfont.md 判定行只认「判定：无关键截断」或「判定：有关键截断（…）」，现在是：{verdict[0]!r}")
    else:
        check(True, f"人工判定已记录：{verdict[0]}")

# crash buffer 由 act 存在根目录；非空即红（round3 同口径：crash buffer 0 行）。
# 与语种无关，放在目录循环外——没有 locale 目录的证据（如 fail-crash 反例）也要判到。
crash = root_dir / 'crash.txt'
if crash.is_file():
    body = crash.read_text(errors='replace').strip()
    check(body == '', f"crash buffer 非空（{len(body.splitlines())} 行）")
else:
    fails.append("crash.txt 缺失（act 没存 crash buffer）")

for m in oks: print("ok", m)
for m in warns: print(m)
for m in fails: print("FAIL", m)
sys.exit(1 if fails else 0)
PYEOF
}
