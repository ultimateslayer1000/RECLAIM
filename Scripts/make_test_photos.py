#!/usr/bin/env python3
"""Generate photo fixtures with known duplicate relationships.

Used to verify the scan pipeline against ground truth: we plant a specific
number of exact duplicates and near-duplicates, then assert RECLAIM finds
exactly those groups. Without this, "the scan ran" is all you can claim.

Load into a booted simulator with:
    xcrun simctl addmedia booted /tmp/reclaim-fixtures/*.png

Ground truth produced (see GROUND_TRUTH below):
  - 3 exact copies of one scene        -> one exactDuplicate group of 3
  - 2 exact copies of a second scene   -> one exactDuplicate group of 2
  - 4 near-identical frames of a third -> one similar group of 4
  - 3 unrelated scenes                 -> no group

Pure stdlib: writes PNGs by hand with zlib, because there is no PIL here.
"""

import math
import os
import struct
import zlib

OUT = "/tmp/reclaim-fixtures"
W = H = 640

GROUND_TRUTH = {
    "exact_duplicate_groups": 2,   # sizes 3 and 2
    "exact_duplicate_photos": 5,
    "similar_group_photos": 4,
    "unrelated_photos": 3,
    "total": 12,
}


def write_png(path, pixels, width=W, height=H):
    raw = bytearray()
    stride = width * 3
    for y in range(height):
        raw.append(0)
        raw += pixels[y * stride:(y + 1) * stride]

    def chunk(tag, data):
        out = struct.pack(">I", len(data)) + tag + data
        return out + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(png)


def render(seed, shift_x=0, shift_y=0, brightness=1.0):
    """Deterministic synthetic 'scene'.

    Structured content with strong edges and gradients — a flat colour field
    would hash identically for every scene and prove nothing.
    """
    px = bytearray(W * H * 3)
    for y in range(H):
        for x in range(W):
            u = x + shift_x
            v = y + shift_y
            r = (math.sin((u * 0.021) + seed) * 0.5 + 0.5) * 255
            g = (math.cos((v * 0.017) + seed * 1.7) * 0.5 + 0.5) * 255
            b = (math.sin(((u + v) * 0.013) + seed * 2.3) * 0.5 + 0.5) * 255
            # Blocky overlay so there is real high-frequency structure.
            if ((u // 64) + (v // 64)) % 2 == 0:
                r, g, b = r * 0.65, g * 0.85, b * 1.0
            i = (y * W + x) * 3
            px[i] = max(0, min(255, int(r * brightness)))
            px[i + 1] = max(0, min(255, int(g * brightness)))
            px[i + 2] = max(0, min(255, int(b * brightness)))
    return px


def main():
    os.makedirs(OUT, exist_ok=True)
    for name in os.listdir(OUT):
        if name.endswith(".png"):
            os.remove(os.path.join(OUT, name))

    written = []

    # --- Group A: three byte-identical copies of one scene ---
    scene_a = render(seed=1.0)
    for n in range(3):
        path = os.path.join(OUT, "dupA_%d.png" % n)
        write_png(path, scene_a)
        written.append(path)

    # --- Group B: two identical copies of a different scene ---
    scene_b = render(seed=4.2)
    for n in range(2):
        path = os.path.join(OUT, "dupB_%d.png" % n)
        write_png(path, scene_b)
        written.append(path)

    # --- Group C: four near-identical frames (re-framed + exposure drift),
    #     the "same shot taken several times" case Vision should cluster.
    #
    #     The shift must be large enough to change the perceptual hash, or these
    #     collapse into the exact-duplicate pass and never exercise Vision at
    #     all: dHash reduces to a 9x8 grid, so on a 640px image one grid cell is
    #     ~71px and a 3px shift is invisible to it. 40px per step moves roughly
    #     half a cell per frame while keeping the scene obviously the same. ---
    for n in range(4):
        path = os.path.join(OUT, "similar_%d.png" % n)
        write_png(path, render(seed=8.5, shift_x=n * 40, shift_y=n * 24,
                               brightness=1.0 - n * 0.05))
        written.append(path)

    # --- Unrelated scenes: must NOT be grouped ---
    for n, seed in enumerate([20.0, 33.3, 47.7]):
        path = os.path.join(OUT, "unique_%d.png" % n)
        write_png(path, render(seed=seed))
        written.append(path)

    print("Wrote %d fixtures to %s" % (len(written), OUT))
    for key, value in GROUND_TRUTH.items():
        print("  %-24s %s" % (key, value))


if __name__ == "__main__":
    main()
