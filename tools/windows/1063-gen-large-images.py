#!/usr/bin/env python
"""Generate large, incompressible JPEGs for the #1063 transfer-interruption cases.

Random per-pixel noise at 4000x3000 does not compress; at quality ~87 one JPEG
lands in the 15-20 MB range. No screenshots, no product code involvement.

Usage:
  1063-gen-large-images.py <outdir> <prefix> <count> [start=1] [seed=1063]
"""
import os
import sys

import numpy as np
from PIL import Image

W, H = 4000, 3000
MIN_BYTES = 15 * 1024 * 1024
MAX_BYTES = 20 * 1024 * 1024


def save_in_range(arr, path):
    im = Image.fromarray(arr)
    # 87 is ~19 MB for this noise; walk down/up only if this image's random
    # content lands outside the requested band.
    for q in (87, 86, 85, 84, 88, 89, 90, 83, 82, 91):
        im.save(path, "JPEG", quality=q, subsampling=0, optimize=False)
        size = os.path.getsize(path)
        if MIN_BYTES <= size <= MAX_BYTES:
            return q, size
    raise SystemExit(
        f"cannot hit 15-20MB for {path}: last size {os.path.getsize(path)}"
    )


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    outdir, prefix, count = sys.argv[1], sys.argv[2], int(sys.argv[3])
    start = int(sys.argv[4]) if len(sys.argv) > 4 else 1
    seed = int(sys.argv[5]) if len(sys.argv) > 5 else 1063
    os.makedirs(outdir, exist_ok=True)
    total = 0
    for i in range(start, start + count):
        rng = np.random.default_rng(seed + i)
        arr = rng.integers(0, 256, size=(H, W, 3), dtype=np.uint8)
        name = f"{prefix}_{i:04d}.jpg"
        path = os.path.join(outdir, name)
        q, size = save_in_range(arr, path)
        total += size
        print(f"{name} quality={q} bytes={size} mib={size / 1048576:.2f}")
    print(f"TOTAL files={count} bytes={total} mib={total / 1048576:.2f}")


if __name__ == "__main__":
    main()
