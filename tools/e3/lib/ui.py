"""uiautomator dump 读取：ui.py <命令> <dump.xml> [参数]

  texts                 所有 text / content-desc，一行一个
  has <子串>             有没有（退出码）
  find <子串|正则>        打印可点位置中心 "x y"：命中节点自己可点就用自己，否则向上找最近的可点祖先
                        （Compose 的文字节点常不可点，可点的是外层；只看自身会漏判，见 test.2 c1 ×）
  grep <正则>            打印第一条匹配正则的文字
  class <类名后缀>        打印第一个该类节点的中心（如 EditText）
  square                打印第一个方形大格子（网格单元）的中心
"""
import re
import sys
import xml.etree.ElementTree as ET


def load(path):
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, FileNotFoundError):
        return [], {}
    parent = {c: p for p in root.iter() for c in p}
    return [n for n in root.iter("node")], parent


def label(n):
    return (n.get("text") or "") + "␟" + (n.get("content-desc") or "")


def bounds(n):
    return tuple(map(int, re.findall(r"\d+", n.get("bounds") or "[0,0][0,0]")))


def center(n):
    x1, y1, x2, y2 = bounds(n)
    return (x1 + x2) // 2, (y1 + y2) // 2


def clickable_self_or_ancestor(n, parent):
    cur = n
    while cur is not None:
        if cur.get("clickable") == "true":
            return cur
        cur = parent.get(cur)
    return n


def main():
    cmd, path = sys.argv[1], sys.argv[2]
    ns, parent = load(path)
    if cmd == "texts":
        for n in ns:
            for k in ("text", "content-desc"):
                v = n.get(k)
                if v:
                    print(v)
    elif cmd == "has":
        sys.exit(0 if any(sys.argv[3] in label(n) for n in ns) else 1)
    elif cmd == "grep":
        pat = re.compile(sys.argv[3])
        for n in ns:
            if pat.search(n.get("text") or ""):
                print(n.get("text"))
                return
        sys.exit(1)
    elif cmd == "find":
        want = sys.argv[3]
        hits = [n for n in ns if want in (n.get("text"), n.get("content-desc"))] or [
            n for n in ns if want in label(n)
        ]
        if not hits:
            try:
                pat = re.compile(want)
                hits = [n for n in ns if pat.search(label(n))]
            except re.error:
                pass
        if not hits:
            sys.exit(1)
        x, y = center(clickable_self_or_ancestor(hits[0], parent))
        print(x, y)
    elif cmd == "class":
        for n in ns:
            if (n.get("class") or "").endswith(sys.argv[3]):
                print(*center(n))
                return
        sys.exit(1)
    elif cmd == "square":
        for n in ns:
            x1, y1, x2, y2 = bounds(n)
            if n.get("clickable") == "true" and abs((x2 - x1) - (y2 - y1)) <= 4 and x2 - x1 > 200:
                print((x1 + x2) // 2, (y1 + y2) // 2)
                return
        sys.exit(1)
    else:
        sys.exit(__doc__)


main()
