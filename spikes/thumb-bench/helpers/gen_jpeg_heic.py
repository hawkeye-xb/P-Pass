#!/usr/bin/env python3
"""Gen 80 JPEG + 60 HEIC via sips (fast). MP4 handled separately."""
import os, subprocess, sys, random

OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/thumb-fixtures"
os.makedirs(OUT, exist_ok=True)
random.seed(42)

def mk_rgb_png(path, w, h, r, g, b):
    import struct, zlib
    raw = b""
    for y in range(h):
        raw += b"\x00"
        raw += bytes([r, g, b]) * w
    def chunk(ct, data):
        c = ct + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xffffffff)
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)

# JPEG
for i in range(80):
    w = random.choice([200, 400, 800, 1200, 1920, 4000])
    h = random.choice([150, 300, 600, 800, 1080, 3000])
    r, g, b = random.randint(0,255), random.randint(0,255), random.randint(0,255)
    tmp = f"/tmp/_tf_{os.getpid()}_{i}.png"
    out = os.path.join(OUT, f"img_{i:04d}.jpg")
    mk_rgb_png(tmp, w, h, r, g, b)
    subprocess.run(["sips", "-s", "format", "jpeg", tmp, "--out", out], check=True, capture_output=True)
    os.unlink(tmp)

# HEIC
for i in range(80, 140):
    w = random.choice([200, 400, 800, 1200, 1920])
    h = random.choice([150, 300, 600, 800, 1080])
    r, g, b = random.randint(0,255), random.randint(0,255), random.randint(0,255)
    tmp = f"/tmp/_tf_{os.getpid()}_{i}.png"
    out = os.path.join(OUT, f"img_{i:04d}.heic")
    mk_rgb_png(tmp, w, h, r, g, b)
    subprocess.run(["sips", "-s", "format", "heic", tmp, "--out", out], check=True, capture_output=True)
    os.unlink(tmp)

files = os.listdir(OUT)
print(f"Generated {len(files)} files in {OUT}")
for ext in [".jpg", ".heic", ".mp4"]:
    n = sum(1 for f in files if f.endswith(ext))
    print(f"  {ext}: {n}")
