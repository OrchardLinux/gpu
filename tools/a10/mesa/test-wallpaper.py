#!/usr/bin/env python3
"""Write a 512x512 yellow/blue checkerboard PNG (no dependencies): a
wallpaper for Hyprland runs, whose sharp edges show blur behind translucent
windows and whose colours show red/blue swaps. Debian's Hyprland package
ships no wall*.png; push it as /run/sid/usr/share/hypr/wall0.png (and
wall1, wall2):

  mesa/test-wallpaper.py OUT.png
"""
import struct
import sys
import zlib

W = H = 512


def chunk(kind, data):
    return (struct.pack('>I', len(data)) + kind + data +
            struct.pack('>I', zlib.crc32(kind + data) & 0xffffffff))


def main():
    rows = []
    for y in range(H):
        row = bytearray([0])
        for x in range(W):
            row += bytes((240, 200, 40) if (x // 32 + y // 32) & 1 else (20, 30, 160))
        rows.append(bytes(row))
    png = (b'\x89PNG\r\n\x1a\n' +
           chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0)) +
           chunk(b'IDAT', zlib.compress(b''.join(rows), 9)) + chunk(b'IEND', b''))
    with open(sys.argv[1], 'wb') as f:
        f.write(png)


if __name__ == '__main__':
    main()
