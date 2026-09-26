#!/usr/bin/env python3
"""Generate RECLAIM's asset catalog: colour sets + an original app icon.

The icon is rasterised from signed-distance fields in pure Python (no PIL on
this machine) and written out as a hand-encoded RGBA PNG.

Concept, per the brief: a minimal circular storage ring, broken at the base like
a gauge, with an upward arrow rising through it. Original artwork.
"""

import json
import math
import os
import struct
import zlib

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
CATALOG = os.path.join(ROOT, "RECLAIM", "Resources", "Assets.xcassets")

# --------------------------------------------------------------------------
# Colour sets
# --------------------------------------------------------------------------

# name: (light hex, dark hex)
COLORS = {
    "Canvas":       ("FAF9F6", "0E0E10"),
    "Surface":      ("FFFFFF", "1A1A1D"),
    "Ink":          ("141416", "F5F4F1"),
    "InkSecondary": ("6B6B70", "9C9CA3"),
    "InkTertiary":  ("9A9AA0", "6E6E75"),
    "Accent":       ("0F9B8E", "2BD4C0"),
    "AccentSoft":   ("E4F5F2", "123B37"),
    "Destructive":  ("D1443C", "FF6B60"),
    "Hairline":     ("E9E7E1", "2C2C31"),
    "RingTrack":    ("EDEBE4", "232328"),
}


def hex_to_components(h):
    return {
        "red":   "0x%02X" % int(h[0:2], 16),
        "green": "0x%02X" % int(h[2:4], 16),
        "blue":  "0x%02X" % int(h[4:6], 16),
        "alpha": "1.000",
    }


def color_entry(hex_value, appearances=None):
    entry = {
        "idiom": "universal",
        "color": {"color-space": "srgb", "components": hex_to_components(hex_value)},
    }
    if appearances:
        entry["appearances"] = appearances
    return entry


def write_json(path, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        json.dump(payload, fh, indent=2)
        fh.write("\n")


def build_colors():
    for name, (light, dark) in COLORS.items():
        write_json(
            os.path.join(CATALOG, "%s.colorset" % name, "Contents.json"),
            {
                "colors": [
                    color_entry(light),
                    color_entry(dark, [{"appearance": "luminosity", "value": "dark"}]),
                ],
                "info": {"author": "xcode", "version": 1},
            },
        )


# --------------------------------------------------------------------------
# PNG encoding
# --------------------------------------------------------------------------

def write_png(path, width, height, pixels):
    """pixels: bytearray of RGBA8, length width*height*4."""
    raw = bytearray()
    stride = width * 4
    for y in range(height):
        raw.append(0)  # filter type 0 (None)
        raw += pixels[y * stride:(y + 1) * stride]

    def chunk(tag, data):
        out = struct.pack(">I", len(data)) + tag + data
        return out + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(png)


# --------------------------------------------------------------------------
# Signed distance helpers
# --------------------------------------------------------------------------

def smoothstep(edge0, edge1, x):
    if edge1 == edge0:
        return 0.0 if x < edge0 else 1.0
    t = (x - edge0) / (edge1 - edge0)
    t = max(0.0, min(1.0, t))
    return t * t * (3.0 - 2.0 * t)


def seg_distance(px, py, ax, ay, bx, by):
    """Distance from point to line segment ab."""
    vx, vy = bx - ax, by - ay
    wx, wy = px - ax, py - ay
    denom = vx * vx + vy * vy
    t = 0.0 if denom == 0 else max(0.0, min(1.0, (wx * vx + wy * vy) / denom))
    cx, cy = ax + t * vx, ay + t * vy
    return math.hypot(px - cx, py - cy)


def over(dst, src, alpha):
    """Composite src over dst with the given coverage."""
    return tuple(dst[i] + (src[i] - dst[i]) * alpha for i in range(3))


def build_icon():
    N = 1024
    cx = cy = N / 2.0

    ring_r = 322.0          # ring centreline radius
    ring_half = 40.0        # half stroke width
    gap_half_deg = 34.0     # half-width of the gauge gap at the base

    # Arrow geometry
    shaft_top = cy - 176.0
    shaft_bottom = cy + 196.0
    shaft_half = 37.0
    head_len = 168.0
    head_half = 37.0

    ink_top = (0x10, 0x12, 0x14)
    ink_bottom = (0x1B, 0x1F, 0x23)
    teal = (0x2E, 0xD3, 0xBE)
    teal_deep = (0x14, 0xA8, 0x97)
    off_white = (0xF7, 0xF6, 0xF2)

    px = bytearray(N * N * 4)
    aa = 1.6  # antialias width in pixels

    for y in range(N):
        fy = y + 0.5
        # Vertical gradient ground
        g = fy / N
        base = (
            ink_top[0] + (ink_bottom[0] - ink_top[0]) * g,
            ink_top[1] + (ink_bottom[1] - ink_top[1]) * g,
            ink_top[2] + (ink_bottom[2] - ink_top[2]) * g,
        )
        dy = fy - cy
        row = y * N * 4
        for x in range(N):
            fx = x + 0.5
            dx = fx - cx
            col = base

            # --- Ring (annulus minus a gap at the base) ---
            r = math.hypot(dx, dy)
            d_ring = abs(r - ring_r) - ring_half
            if d_ring < aa:
                # Angle measured from straight down, in degrees
                ang = math.degrees(math.atan2(dx, dy))
                if abs(ang) > gap_half_deg:
                    cov = 1.0 - smoothstep(-aa, aa, d_ring)
                    if cov > 0:
                        # Subtle top-to-bottom tonal shift on the ring
                        t = max(0.0, min(1.0, (fy - (cy - ring_r)) / (2 * ring_r)))
                        rc = (
                            teal[0] + (teal_deep[0] - teal[0]) * t,
                            teal[1] + (teal_deep[1] - teal[1]) * t,
                            teal[2] + (teal_deep[2] - teal[2]) * t,
                        )
                        col = over(col, rc, cov)
                else:
                    # Round off the two ring ends bordering the gap
                    for sign in (-1.0, 1.0):
                        a = math.radians(sign * gap_half_deg)
                        ex = cx + ring_r * math.sin(a)
                        ey = cy + ring_r * math.cos(a)
                        d_cap = math.hypot(fx - ex, fy - ey) - ring_half
                        cov = 1.0 - smoothstep(-aa, aa, d_cap)
                        if cov > 0:
                            col = over(col, teal_deep, cov)

            # --- Upward arrow ---
            d_shaft = seg_distance(fx, fy, cx, shaft_top, cx, shaft_bottom) - shaft_half
            apex_y = shaft_top
            d_left = seg_distance(fx, fy, cx, apex_y, cx - head_len * 0.72,
                                  apex_y + head_len * 0.72) - head_half
            d_right = seg_distance(fx, fy, cx, apex_y, cx + head_len * 0.72,
                                   apex_y + head_len * 0.72) - head_half
            d_arrow = min(d_shaft, d_left, d_right)
            if d_arrow < aa:
                cov = 1.0 - smoothstep(-aa, aa, d_arrow)
                if cov > 0:
                    col = over(col, off_white, cov)

            i = row + x * 4
            px[i] = int(max(0, min(255, col[0])))
            px[i + 1] = int(max(0, min(255, col[1])))
            px[i + 2] = int(max(0, min(255, col[2])))
            px[i + 3] = 255

    icon_dir = os.path.join(CATALOG, "AppIcon.appiconset")
    os.makedirs(icon_dir, exist_ok=True)
    write_png(os.path.join(icon_dir, "AppIcon.png"), N, N, px)
    write_json(
        os.path.join(icon_dir, "Contents.json"),
        {
            "images": [{
                "filename": "AppIcon.png",
                "idiom": "universal",
                "platform": "ios",
                "size": "1024x1024",
            }],
            "info": {"author": "xcode", "version": 1},
        },
    )


def main():
    write_json(os.path.join(CATALOG, "Contents.json"),
               {"info": {"author": "xcode", "version": 1}})
    build_colors()
    build_icon()
    print("Wrote colour sets: %s" % ", ".join(sorted(COLORS)))
    print("Wrote AppIcon.appiconset/AppIcon.png (1024x1024)")


if __name__ == "__main__":
    main()
