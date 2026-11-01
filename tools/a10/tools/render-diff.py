#!/usr/bin/env python3
"""Diff render-variant captures (ios-capture `session.py render`).

Regions move between runs, so they are paired by order. Words equal to an
address inside the run's own regions are rebased to (region index, offset)
before comparing, so relocation alone does not show up as a difference.

  render-diff.py OUT/ios-render                 # region layout per variant
  render-diff.py OUT/ios-render VARIANT [REF]   # word diffs against REF (base)
"""
import pathlib
import struct
import sys


def load(directory):
    regions = []
    for path in sorted(next((directory / 'iocalls').glob('call_*_regions')).glob('r_*.bin')):
        regions.append((int(path.stem[2:], 16), path.read_bytes()))
    return regions


def rebase(regions):
    """Map a 32-bit word or 64-bit pair onto 'R<i>+off' when it points into a region."""
    spans = [(base, base + len(data), i) for i, (base, data) in enumerate(regions)]

    def name(value):
        for start, end, i in spans:
            if start <= value < end:
                return f'R{i}+{value - start:#x}'
        # Many streams hold addresses >> 2 or >> 4, or only the low 32 bits.
        for shift in (2, 4):
            for start, end, i in spans:
                if start <= value << shift < end and value << shift & 0xfff:
                    return f'R{i}+{(value << shift) - start:#x}>>{shift}'
        for start, end, i in spans:
            if (start & 0xffffffff) <= value < (end & 0xffffffff) and start >> 32:
                return f'R{i}+{value - (start & 0xffffffff):#x}(lo)'
        return None
    return name


def words(data):
    return struct.unpack(f'<{len(data) // 4}I', data[:len(data) // 4 * 4])


def layout(root):
    for variant in sorted(p for p in root.iterdir() if p.is_dir()):
        regions = load(variant)
        print(f'{variant.name:12}', ' '.join(f'{len(d) // 1024}K' for _, d in regions))


def diff(root, variant, reference='base'):
    ours, theirs = load(root / variant), load(root / reference)
    if [len(d) for _, d in ours] != [len(d) for _, d in theirs]:
        print('region layout differs; pairing by order anyway')
    name_ours, name_theirs = rebase(ours), rebase(theirs)
    for i, ((_, a), (_, b)) in enumerate(zip(ours, theirs)):
        wa, wb = words(a), words(b)
        rows = []
        for k, (x, y) in enumerate(zip(wa, wb)):
            if x == y:
                continue
            nx, ny = name_ours(x), name_theirs(y)
            if nx is not None and nx == ny:
                continue
            rows.append(f'  R{i}+{4 * k:#06x}: {reference} {y:08x}{" " + ny if ny else ""}'
                        f'  {variant} {x:08x}{" " + nx if nx else ""}')
        if rows:
            print(f'R{i} ({len(a) // 1024}K): {len(rows)} words differ')
            print('\n'.join(rows[:60]))
            if len(rows) > 60:
                print(f'  ... {len(rows) - 60} more')


if __name__ == '__main__':
    root = pathlib.Path(sys.argv[1])
    if len(sys.argv) == 2:
        layout(root)
    else:
        diff(root, *sys.argv[2:4])
