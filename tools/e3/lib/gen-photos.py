"""程序生成测试照片（内容各不相同，桌面按 hash 判重）：gen-photos.py <目录> <张数> <前缀>

只用标准库画 PNG，再用 macOS 自带 sips 转成 JPEG（不依赖 Pillow）。文件名 PPR_<前缀>_<序号>.jpg。
"""
import os
import random
import struct
import subprocess
import sys
import tempfile
import zlib

W, H = 800, 600


def png(path, rnd):
    bg = bytes(rnd.randrange(256) for _ in range(3))
    rows = [bytearray(bg * W) for _ in range(H)]
    for _ in range(25):
        x, y = rnd.randrange(W), rnd.randrange(H)
        w, h = rnd.randrange(20, 300), rnd.randrange(20, 200)
        c = bytes(rnd.randrange(256) for _ in range(3))
        for yy in range(y, min(H, y + h)):
            x2 = min(W, x + w)
            rows[yy][x * 3 : x2 * 3] = c * (x2 - x)
    raw = b"".join(b"\0" + bytes(r) for r in rows)

    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 6)))
        f.write(chunk(b"IEND", b""))


def main():
    out, n, prefix = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    os.makedirs(out, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for i in range(n):
            rnd = random.Random(f"{prefix}-{i}-{os.urandom(8).hex()}")
            p = os.path.join(tmp, f"{i}.png")
            png(p, rnd)
            dst = os.path.join(out, f"PPR_{prefix}_{i:03d}.jpg")
            subprocess.run(
                ["sips", "-s", "format", "jpeg", p, "--out", dst],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
    print(out)


main()
