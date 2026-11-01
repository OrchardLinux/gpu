#!/usr/bin/env python3
"""Recover the GPU virtual address of each captured region (render captures).

CPU and GPU mappings differ per region, but runs of regions are mapped
linearly. Known anchors (STREAM_LINK targets, PPP state) fix some regions;
every other region is tried at each anchor's CPU-to-GPU offset, and kept when
GPU addresses found in the capture land in it at non-zero, aligned data.

  render-vamap.py CAPTURE_DIR [REGION=GPU_BASE ...]
"""
import pathlib
import struct
import sys


def main():
    root = next((pathlib.Path(sys.argv[1]) / 'iocalls').glob('call_*_regions'))
    regions = sorted((int(p.stem[2:], 16), p.read_bytes()) for p in root.glob('r_*.bin'))
    anchors = {int(k.lstrip('R')): int(v, 0) for k, v in (a.split('=') for a in sys.argv[2:])}
    # GPU addresses in the capture: 64-bit values in the 0x1_0000_0000 window
    refs = set()
    for _, data in regions:
        for o in range(0, len(data) - 8, 4):
            q = struct.unpack_from('<Q', data, o)[0]
            if q >> 32 == 1:
                refs.add(q)
    shifts = sorted({base - regions[i][0] for i, base in anchors.items()})
    for i, (cpu, data) in enumerate(regions):
        best = []
        for shift in shifts:
            gpu = cpu + shift
            hits = [r for r in refs if gpu <= r < gpu + len(data)]
            useful = sum(1 for r in hits if any(data[r - gpu:r - gpu + 16]))
            best.append((useful, len(hits), gpu))
        best.sort(reverse=True)
        fixed = ' (anchor)' if i in anchors else ''
        print(f'R{i:<2} cpu {cpu:#x} size {len(data):#7x} -> ' +
              ', '.join(f'{g:#x}: {u}/{n}' for u, n, g in best[:3]) + fixed)


if __name__ == '__main__':
    main()
