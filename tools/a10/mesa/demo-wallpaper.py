#!/usr/bin/env python3
"""Write a 1536x2048 PNG wallpaper for the effects demo (hypr-demo.sh, no
dependencies): a dusk gradient with large discs and thin stripes, whose sharp
edges show the blur behind translucent windows. Push it as
/run/sid/usr/share/hypr/wall0.png (and wall1, wall2):

  mesa/demo-wallpaper.py OUT.png
"""
import struct
import sys
import zlib

W, H = 1536, 2048
TOP, BOTTOM = (40, 20, 90), (250, 120, 60)
# (centre x, centre y, radius, colour)
DISCS = [
    (300, 400, 260, (255, 70, 120)),
    (1200, 650, 340, (60, 200, 255)),
    (700, 1150, 300, (255, 220, 60)),
    (250, 1650, 220, (120, 255, 140)),
    (1250, 1700, 280, (200, 90, 255)),
]


def chunk(kind, data):
    return (struct.pack('>I', len(data)) + kind + data +
            struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff))


def main():
    rows = []
    for y in range(H):
        t = y / (H - 1)
        bg = bytes(round(a + (b - a) * t) for a, b in zip(TOP, BOTTOM))
        row = bytearray(bg * W)
        # thin diagonal stripes across the middle band
        if 850 <= y < 1450:
            for x in range((y * 2) % 48, W, 48):
                row[x * 3:min(x + 3, W) * 3] = b"\xff" * (min(x + 3, W) - x) * 3
        for cx, cy, r, colour in DISCS:
            dy = y - cy
            if abs(dy) >= r:
                continue
            half = int((r * r - dy * dy) ** 0.5)
            x0, x1 = max(cx - half, 0), min(cx + half, W)
            row[x0 * 3:x1 * 3] = bytes(colour) * (x1 - x0)
        rows.append(b'\0' + bytes(row))
    png = (b'\x89PNG\r\n\x1a\n' +
           chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0)) +
           chunk(b'IDAT', zlib.compress(b''.join(rows), 6)) + chunk(b'IEND', b''))
    with open(sys.argv[1], 'wb') as f:
        f.write(png)


if __name__ == '__main__':
    main()
