# 大字体与减少动态效果取证（#1801）：系统字体 1.5x + 动画全关，设置页（顶部与滚动后）与
# 备份范围页逐页 dump + 截图。
# 判据（当前实现下全绿）：关键文本（三个开关行、两个单次入口行）在控件树里、相册卡带类型
# desc 与 checked、crash buffer 干净；同时把所有 <48dp 的可点节点打成 WARN 清单——
# 这是量表记录，不是判定。
#
# 已知问题照实记录、不判死（#1801 round3 §三b 1.5x 下「备份范围」行折行错位、§四1 选中
# 时间 Chip 触控区缩到 32dp——都是已取证未修的观察项；等修掉后把对应判据从 WARN 收紧成 FAIL）。
# 文本是否视觉截断（Ellipsis/断词）在 dump 里看不出来（a11y 文本始终是全文），要看截图，归 E3 人工。
#
# 需要：候选 debug 包与配对桩（同 a11y-semantics）。语种默认 zh-CN en-US 两语都跑。
DESC="1.5x 大字体+减少动态效果逐页取证：关键信息仍在、无崩溃、<48dp 可点节点量表（WARN）"
COUNTER=off
LOCALES="${E3_A11Y_LOCALES:-zh-CN en-US}"

setup() {
  [ -f "$(cand_apk)" ] || { echo "缺候选 debug 包：apps/android assembleDebug（或 just verify 编包）；E3_ANDROID_APK 可指定路径"; return 77; }
  ensure_paired "$EV" || return 1
  A shell cmd locale get-app-locales "$PKG" >"$EV/locale-before.txt" 2>/dev/null
  A shell settings get system font_scale >"$EV/font-scale-before.txt" 2>/dev/null
  A shell settings get global window_animation_scale >"$EV/anim-before.txt" 2>/dev/null
  logcat_clear
}

set_locale() {
  app_stop
  A shell cmd locale set-app-locales "$PKG" --locales "$1" >/dev/null || { echo "set-app-locales $1 失败"; return 1; }
}

parse_locales() { sed -n 's/.*\[\([^]]*\)\].*/\1/p' "$1" 2>/dev/null | tail -1 | tr -d ' '; }

restore_locale() {
  local before
  before=$(parse_locales "$EV/locale-before.txt")
  case "$before" in
    "" | "empty") A shell cmd locale clear-app-locales "$PKG" >/dev/null 2>&1 ;;
    *) A shell cmd locale set-app-locales "$PKG" --locales "$before" >/dev/null 2>&1 ;;
  esac
}

density_dpi() { A shell wm density | grep -oE '[0-9]+' | tail -1; }

# 屏幕中间上滑一屏（按实测屏幕高算坐标，不写死 1080x2340）
swipe_up() {
  local wh
  wh=$(A shell wm size | grep -oE '[0-9]+' | tail -2 | tr '\n' ' ')
  set -- $wh
  local w="${1:-1080}" h="${2:-2340}"
  A shell input swipe $((w / 2)) $((h * 7 / 10)) $((w / 2)) $((h * 3 / 10)) 300
}

act() {
  A shell settings put system font_scale 1.5
  # 减少动态效果（卡上「减少动态效果」一项）：三个动画缩放全关
  A shell settings put global window_animation_scale 0
  A shell settings put global transition_animation_scale 0
  A shell settings put global animator_duration_scale 0
  for loc in $LOCALES; do
    set_locale "$loc" || return 1
    local d="$EV/$loc"
    mkdir -p "$d"
    A shell cmd locale get-app-locales "$PKG" >"$d/locale-set.txt" 2>/dev/null
    app_start
    sleep 5
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
    app_stop
  done
  logcat_save "$EV/logcat.txt"
  A logcat -d -b crash >"$EV/crash.txt" 2>/dev/null
}

teardown() {
  local fs an
  fs=$(cat "$EV/font-scale-before.txt" 2>/dev/null | tr -d '\r')
  an=$(cat "$EV/anim-before.txt" 2>/dev/null | tr -d '\r')
  [ -n "$fs" ] && [ "$fs" != "null" ] && A shell settings put system font_scale "$fs" 2>/dev/null
  [ -n "$an" ] && [ "$an" != "null" ] && A shell settings put global window_animation_scale "$an" 2>/dev/null
  A shell settings put global transition_animation_scale 1 2>/dev/null
  A shell settings put global animator_duration_scale 1 2>/dev/null
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
                  entry=['从相册选择', '从文件选择'], kind='相册'),
    'en-US': dict(switch=['Auto backup', 'Back up only on Wi-Fi', 'Notifications'],
                  entry=['Choose from Photos', 'Choose from Files'], kind='Album'),
}

def load(path):
    try:
        return ET.parse(path).getroot()
    except Exception:
        return None

def text_of(n): return n.get('text') or ''
def cd_of(n): return n.get('content-desc') or ''
def label_of(n): return text_of(n) + '␟' + cd_of(n)
def bounds(n): return tuple(map(int, re.findall(r'\d+', n.get('bounds') or '[0,0][0,0]')))
def height_dp(n, dpi): x1, y1, x2, y2 = bounds(n); return (y2 - y1) * 160.0 / dpi

for d in sorted(root_dir.iterdir()):
    if not d.is_dir(): continue
    if d.name not in LANG:
        fails.append(f"目录 {d.name} 不是已知语种（判据表只认 {sorted(LANG)}）")
        continue
    L = LANG[d.name]
    names = [n for n in ('settings.xml', 'settings-scrolled.xml', 'scope-open.xml') if (d / n).is_file()]
    if not names:
        fails.append(f"{d.name} 一份 dump 都没有（act 没跑完？）")
        continue
    if not (d / 'density.txt').is_file():
        fails.append(f"{d.name}/density.txt 缺失，触控目标换算不了")
        continue
    dpi = float((d / 'density.txt').read_text().strip() or 0)
    if dpi <= 0:
        fails.append(f"{d.name}/density.txt 内容不是 dpi")
        continue

    all_nodes = []
    for n in names:
        root = load(d / n)
        if root is None:
            fails.append(f"{d.name}/{n} 解析失败")
            continue
        all_nodes.append((n, list(root.iter('node'))))

    # 1. 关键文本仍在（三开关行 + 两入口行，跨设置页两屏合并看）
    texts = set()
    for _, ns in all_nodes:
        if 'settings' in _: texts.update(text_of(x) for x in ns)
    for label in L['switch'] + L['entry']:
        check(label in texts, f"{d.name} 1.5x 下关键文本「{label}」必须仍在控件树里（截断到读不出来才算红）")

    # 2. 范围页相册卡带类型 desc 与 checkable（选中语义不丢）
    scope_path = d / 'scope-open.xml'
    scope_root = load(scope_path) if scope_path.is_file() else None
    if scope_root is None:
        fails.append(f"{d.name}/scope-open.xml 缺失或解析失败")
    else:
        nodes = list(scope_root.iter('node'))
        parent = {c: p for p in scope_root.iter('node') for c in p}
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

    # 3. <48dp 可点节点量表（WARN 记录，不判死——已知问题见文件头）
    for n, ns in all_nodes:
        for x in ns:
            if x.get('clickable') == 'true' and height_dp(x, dpi) < 48.0:
                warns.append(f"WARN {d.name}/{n} 可点节点高 {height_dp(x, dpi):.1f}dp <48dp text={text_of(x)!r} cd={cd_of(x)!r} bounds={x.get('bounds')}")

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
