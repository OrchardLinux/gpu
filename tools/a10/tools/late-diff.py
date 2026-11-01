#!/usr/bin/env python3
"""Words that changed in the command regions after the submit trap returned.

post.bin holds the regions copied right after the trap, late.bin the last
copy of a 300 ms watch (capture.m copy_late); both follow post.idx. Only
regions up to 64 KiB are watched.

  late-diff.py CAPTURE_DIR
"""
import pathlib
import struct
import sys


def main():
    root = pathlib.Path(sys.argv[1])
    post = (root / 'post.bin').read_bytes()
    late = (root / 'late.bin').read_bytes()
    at = 0
    entries = [l.split() for l in (root / 'post.idx').read_text().splitlines() if l.strip()]
    for i, (start, size) in enumerate(entries):
        size = int(size, 16)
        if size <= 0x10000:
            a, b = post[at:at + size], late[at:at + size]
            rows = [(o, struct.unpack_from('<I', a, o)[0], struct.unpack_from('<I', b, o)[0])
                    for o in range(0, size, 4) if a[o:o + 4] != b[o:o + 4]]
            if rows:
                print(f'R{i} ({start}, {size:#x}): {len(rows)} words changed')
                for o, x, y in rows[:80]:
                    print(f'  +{o:#06x}: {x:08x} -> {y:08x}')
        at += size


if __name__ == '__main__':
    main()
