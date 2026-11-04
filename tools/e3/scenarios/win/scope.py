"""读取手机「备份哪些照片」页的 uiautomator dump。

界面结构（0.10.2）：相册是 2 列网格，名字是 TextView，整格可点；选中时格内出现一个
「✓」TextView，控件本身不可见 checked 状态。时间范围是顶部两个 checkable View。

用法：
  scope.py list <dump.xml>            每行：<相册名>\t<selected|->\t<x,y>
  scope.py selected <dump.xml>        每行一个已勾选相册名
  scope.py find <dump.xml> <名字>     打印可点坐标 "x y"（找不到退出 1）
"""
import re
import sys
import xml.etree.ElementTree as ET


def load(path):
    root = ET.parse(path).getroot()
    nodes = list(root.iter("node"))
    parent = {c: p for p in root.iter("node") for c in p}
    return nodes, parent


def bounds(n):
    return tuple(map(int, re.findall(r"\d+", n.get("bounds") or "[0,0][0,0]")))


def center(b):
    return (b[0] + b[2]) // 2, (b[1] + b[3]) // 2


def clickable_ancestor(n, parent):
    cur = n
    while cur is not None:
        if cur.get("clickable") == "true":
            return cur
        cur = parent.get(cur)
    return None


def albums(nodes, parent):
    out = []
    for n in nodes:
        if n.get("class") != "android.widget.TextView":
            continue
        txt = (n.get("text") or "").strip()
        if not txt or txt in ("✓", "‹", "开始备份") or "张" in txt:
            continue
        anc = clickable_ancestor(n, parent)
        if anc is None:
            continue
        b = bounds(anc)
        if b[1] < 500:  # 顶部时间范围 / 标题，不是相册格
            continue
        out.append((txt, b, n))
    return out


def checked(nodes, box):
    for n in nodes:
        if (n.get("text") or "").strip() == "✓":
            cx, cy = center(bounds(n))
            if box[0] <= cx <= box[2] and box[1] <= cy <= box[3]:
                return True
    return False


def main():
    cmd, path = sys.argv[1], sys.argv[2]
    nodes, parent = load(path)
    al = albums(nodes, parent)
    if cmd == "list":
        for name, box, _ in al:
            x, y = center(box)
            print(f"{name}\t{'selected' if checked(nodes, box) else '-'}\t{x},{y}")
    elif cmd == "selected":
        for name, box, _ in al:
            if checked(nodes, box):
                print(name)
    elif cmd == "find":
        want = sys.argv[3]
        for name, box, node in al:
            if name == want:
                print(*center(bounds(node)))
                return
        sys.exit(1)
    else:
        sys.exit(__doc__)


main()
