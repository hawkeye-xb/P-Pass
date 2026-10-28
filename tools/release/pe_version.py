#!/usr/bin/env python3
"""#788：从 PE 字节里读 StringFileInfo 的 FileVersion（Windows 安装包「自报的版本号」）。

为什么要它：#838 复用 Latest 的 Windows 产物时，必须证明安装包自己报的版本号 = 本次 Windows
的版本号（#809 的教训：清单写的号不等于包里的号）。客户端的防降级判据（#1155，
crates/platform/src/pe_version.rs）读的正是这一项，这里是同一套解析的 Python 移植，CI 在 ubuntu 上跑：
  资源目录：根 → RT_VERSION → 第一个名字 → 第一个语言 → 数据项 → VS_VERSIONINFO
  → StringFileInfo → 各 StringTable → FileVersion（字符串，保留 -test.N 之类的后缀）。
只认字符串；读不到就报错，不拿 VS_FIXEDFILEINFO（只有四段数字）兜底。

用法：
  python3 -I tools/release/pe_version.py <文件>        打印 FileVersion；读不到 ⇒ 退出 1
  python3 -I tools/release/pe_version.py --self-test   解析器自测（构造器造的 PE + 各类坏输入）
  python3 -I tools/release/pe_version.py --make <版本> <输出>   造一个带该 FileVersion 的最小 PE（测试夹具用）
"""

from __future__ import annotations

import struct
import sys

RT_VERSION = 16
IMAGE_DIRECTORY_ENTRY_RESOURCE = 2


class PeError(Exception):
    pass


def _u16(b: bytes, off: int) -> int:
    if off < 0 or off + 2 > len(b):
        raise PeError(f"PE 结构越界（读 u16 @ {off:#x}）")
    return struct.unpack_from("<H", b, off)[0]


def _u32(b: bytes, off: int) -> int:
    if off < 0 or off + 4 > len(b):
        raise PeError(f"PE 结构越界（读 u32 @ {off:#x}）")
    return struct.unpack_from("<I", b, off)[0]


def _align4(n: int) -> int:
    return (n + 3) & ~3


def file_version(data: bytes) -> str:
    """一份 PE 文件里 StringFileInfo 的 FileVersion 字符串。"""
    if len(data) < 0x40 or data[:2] != b"MZ":
        raise PeError("不是 PE 文件（缺 MZ 头）")
    pe_off = _u32(data, 0x3C)
    if data[pe_off:pe_off + 4] != b"PE\0\0":
        raise PeError("不是 PE 文件（缺 PE 签名）")
    coff = pe_off + 4
    num_sections = _u16(data, coff + 2)
    size_opt = _u16(data, coff + 16)
    opt = coff + 20
    magic = _u16(data, opt)
    if magic == 0x10B:
        dd_off = opt + 96
    elif magic == 0x20B:
        dd_off = opt + 112
    else:
        raise PeError(f"未知的 PE 可选头 magic：{magic:#x}")
    res_rva = _u32(data, dd_off + IMAGE_DIRECTORY_ENTRY_RESOURCE * 8)
    if res_rva == 0:
        raise PeError("PE 没有资源目录")
    sections = []
    for i in range(num_sections):
        off = opt + size_opt + i * 40
        sections.append((_u32(data, off + 12), _u32(data, off + 8), _u32(data, off + 16), _u32(data, off + 20)))

    def rva_to_offset(rva: int) -> int:
        for va, vsize, rsize, rptr in sections:
            if va <= rva < va + max(vsize, rsize):
                return rptr + (rva - va)
        raise PeError(f"RVA {rva:#x} 不落在任何节里")

    base = rva_to_offset(res_rva)

    def subdir_by_id(d: int, wanted: int) -> int:
        n = _u16(data, d + 12) + _u16(data, d + 14)
        for i in range(n):
            e = d + 16 + i * 8
            name = _u32(data, e)
            if name & 0x80000000:
                continue  # 字符串名，不是 ID
            if name == wanted:
                sub = _u32(data, e + 4)
                if not sub & 0x80000000:
                    raise PeError(f"资源 ID {wanted} 不是子目录")
                return base + (sub & 0x7FFFFFFF)
        raise PeError(f"PE 资源里没有 ID {wanted}")

    def first_entry(d: int) -> int:
        if _u16(data, d + 12) + _u16(data, d + 14) == 0:
            raise PeError("空资源目录")
        return _u32(data, d + 16 + 4)

    type_dir = subdir_by_id(base, RT_VERSION)
    sub = first_entry(type_dir)
    if not sub & 0x80000000:
        raise PeError("资源项不是子目录")
    name_dir = base + (sub & 0x7FFFFFFF)
    leaf = first_entry(name_dir)
    if leaf & 0x80000000:
        raise PeError("语言项还是子目录，资源树形状不符")
    de = base + leaf
    blob_off = rva_to_offset(_u32(data, de))
    blob = data[blob_off:blob_off + _u32(data, de + 4)]
    if len(blob) != _u32(data, de + 4):
        raise PeError("版本资源长度越界")
    return file_version_from_blob(blob)


def _block(buf: bytes, off: int):
    """解析一个版本块：返回 (key, value 字节, children 字节, wLength)。"""
    w_length, w_value_length, w_type = _u16(buf, off), _u16(buf, off + 2), _u16(buf, off + 4)
    if w_length < 6 or off + w_length > len(buf):
        raise PeError(f"版本块长度不合法（{w_length}）")
    block = buf[off:off + w_length]
    i = 6
    units = []
    while True:
        u = _u16(block, i)
        i += 2
        if u == 0:
            break
        units.append(u)
    key = struct.pack(f"<{len(units)}H", *units).decode("utf-16-le", errors="replace")
    after_key = _align4(i)
    if after_key > len(block):
        raise PeError("版本块 key 之后越界")
    value_len = w_value_length * 2 if w_type == 1 else w_value_length
    value_end = min(after_key + value_len, len(block))
    children_start = min(_align4(value_end), len(block))
    return key, block[after_key:value_end], block[children_start:], w_length


def _children(buf: bytes):
    off = 0
    while off + 6 <= len(buf):
        key, value, children, length = _block(buf, off)
        yield key, value, children
        if length == 0:
            break
        off += _align4(length)


def _utf16_value(b: bytes) -> str:
    units = []
    for i in range(0, len(b) - 1, 2):
        u = struct.unpack_from("<H", b, i)[0]
        if u == 0:
            break
        units.append(u)
    return struct.pack(f"<{len(units)}H", *units).decode("utf-16-le", errors="replace")


def file_version_from_blob(blob: bytes) -> str:
    key, _, children, _ = _block(blob, 0)
    if key != "VS_VERSION_INFO":
        raise PeError(f"版本块根 key 不是 VS_VERSION_INFO：{key}")
    sfi = next((c for k, _, c in _children(children) if k == "StringFileInfo"), None)
    if sfi is None:
        raise PeError("版本资源里没有 StringFileInfo")
    for _, _, table in _children(sfi):
        for k, value, _ in _children(table):
            if k.lower() == "fileversion":
                v = _utf16_value(value).strip()
                if not v:
                    raise PeError("FileVersion 是空串")
                return v
    raise PeError("版本资源里没有 FileVersion 字符串")


# ── 测试夹具：最小 PE（与 crates/platform/src/pe_version.rs 的 test_pe 同形）──────────


def build_version_blob(version: str, key: str = "FileVersion") -> bytes:
    def utf16z(s: str) -> bytes:
        return s.encode("utf-16-le") + b"\0\0"

    def pad(b: bytearray):
        while len(b) % 4:
            b.append(0)

    def block(k: str, value: bytes, value_units: int, ty: int, children: bytes) -> bytes:
        b = bytearray(b"\0\0" + struct.pack("<HH", value_units, ty) + utf16z(k))
        pad(b)
        b += value
        pad(b)
        b += children
        pad(b)
        struct.pack_into("<H", b, 0, len(b))
        return bytes(b)

    v = utf16z(version)
    strings = block(key, v, len(v) // 2, 1, b"") + block("ProductVersion", v, len(v) // 2, 1, b"")
    table = block("040904B0", b"", 0, 1, strings)
    sfi = block("StringFileInfo", b"", 0, 1, table)
    return block("VS_VERSION_INFO", bytes(52), 52, 0, sfi)


def build_pe(version_blob: bytes, payload: bytes = b"") -> bytes:
    """PE32+、一个 .rsrc 节；payload 追加在文件末尾（像 NSIS 安装包的 overlay），不影响解析。"""
    pe = bytearray(0x200 + 0x400)
    pe[0:2] = b"MZ"
    struct.pack_into("<I", pe, 0x3C, 0x80)
    pe[0x80:0x84] = b"PE\0\0"
    coff = 0x84
    struct.pack_into("<H", pe, coff + 2, 1)
    struct.pack_into("<H", pe, coff + 16, 240)
    opt = coff + 20
    struct.pack_into("<H", pe, opt, 0x20B)
    for off, val in ((32, 0x1000), (36, 0x200), (56, 0x2000), (60, 0x200), (108, 16)):
        struct.pack_into("<I", pe, opt + off, val)
    struct.pack_into("<H", pe, opt + 68, 2)
    res = opt + 112 + 2 * 8
    struct.pack_into("<II", pe, res, 0x1000, 0x800)
    sec = opt + 240
    pe[sec:sec + 8] = b".rsrc\0\0\0"
    struct.pack_into("<IIII", pe, sec + 8, 0x400, 0x1000, 0x400, 0x200)
    struct.pack_into("<I", pe, sec + 36, 0x40000040)
    base = 0x200
    struct.pack_into("<H", pe, base + 14, 1)
    struct.pack_into("<II", pe, base + 16, RT_VERSION, 0x80000018)
    d1 = base + 0x18
    struct.pack_into("<H", pe, d1 + 14, 1)
    struct.pack_into("<II", pe, d1 + 16, 1, 0x80000030)
    d2 = base + 0x30
    struct.pack_into("<H", pe, d2 + 14, 1)
    struct.pack_into("<II", pe, d2 + 16, 1033, 0x48)
    de = base + 0x48
    struct.pack_into("<III", pe, de, 0x1100, len(version_blob), 1200)
    pe[0x300:0x300 + len(version_blob)] = version_blob
    return bytes(pe) + payload


def make_pe(version: str, payload: bytes = b"") -> bytes:
    return build_pe(build_version_blob(version), payload)


def _self_test() -> int:
    fails = 0

    def check(ok: bool, desc: str):
        nonlocal fails
        print(f"  {'PASS' if ok else 'FAIL'}: {desc}")
        fails += 0 if ok else 1

    def err(data: bytes) -> str:
        try:
            return "ok:" + file_version(data)
        except PeError as e:
            return str(e)

    check(file_version(make_pe("0.10.0")) == "0.10.0", "正式版号原样读出")
    check(file_version(make_pe("0.10.0-test.9")) == "0.10.0-test.9", "预发布后缀不丢（不是四段 fixed info）")
    check(file_version(make_pe("0.10.0", b"\x00nsis-overlay" * 100)) == "0.10.0", "文件尾的 overlay 不影响解析")
    check("MZ" in err(b"not a pe" * 20), "非 PE ⇒ 报错")
    check("FileVersion" in err(build_pe(build_version_blob("0.10.0", key="OtherKey"))), "没有 FileVersion ⇒ 报错（不兜底）")
    check(err(make_pe("")) == "FileVersion 是空串", "空 FileVersion ⇒ 报错")
    bad = bytearray(make_pe("0.10.0"))
    struct.pack_into("<I", bad, 0x200 + 16, 99)  # 根目录里没有 RT_VERSION
    check("ID 16" in err(bytes(bad)), "没有版本资源 ⇒ 报错")
    check("越界" in err(make_pe("0.10.0")[:0x320]), "截断 ⇒ 报错")
    print(f"pe_version self-test: {'全部通过' if not fails else f'{fails} 项失败'}")
    return 1 if fails else 0


def main(argv: list[str]) -> int:
    if argv[:1] == ["--self-test"]:
        return _self_test()
    if len(argv) == 3 and argv[0] == "--make":
        with open(argv[2], "wb") as f:
            f.write(make_pe(argv[1], b"\x00fake-nsis-payload:" + argv[1].encode() * 64))
        return 0
    if len(argv) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        with open(argv[0], "rb") as f:
            print(file_version(f.read()))
    except (OSError, PeError) as e:
        print(f"pe_version: {argv[0]}: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
