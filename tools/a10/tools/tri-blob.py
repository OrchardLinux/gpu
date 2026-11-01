#!/usr/bin/env python3
"""Pack an iPadOS render capture into apple/gpu-tri.bin for apple_selftest=7.

Regions are mapped at their iOS GPU addresses (RENDER.md, "GPU address of
every region"). Addresses below 4 GiB are code-heap offsets; the driver maps
those at both its PDS and USC bases.

  tri-blob.py CAPTURE_DIR OUT
"""
import pathlib
import struct
import sys

# Region index -> GPU address, from the selector-9 replies (alloc-base)
GPU = {
    2: 0x0, 3: 0x1_00000000, 4: 0x1_00014000, 5: 0x1_0001c000, 6: 0x14000,
    7: 0x28000, 8: 0x1_00004000, 9: 0x2_00004000, 10: 0x1_00040000,
    11: 0x1_0004c000, 12: 0x1_00058000, 13: 0x1_00064000, 14: 0x30000,
    15: 0x3c000, 16: 0x1_00070000, 17: 0x1_000f4000, 18: 0x1_00100000,
    19: 0x1_0010c000, 20: 0x1_00118000, 21: 0x1_00124000, 22: 0x1_00130000,
    23: 0x1_0013c000, 24: 0x1_00148000, 25: 0x1_00154000,
}


def main():
    root = next((pathlib.Path(sys.argv[1]) / 'iocalls').glob('call_*_regions'))
    regions = sorted(root.glob('r_*.bin'))
    # A capture directory can hold region sets of earlier runs (another
    # process, CPU addresses gigabytes apart): keep the newest set.
    cpu = [int(r.stem[2:], 16) for r in regions]
    first = max(i for i in range(len(cpu)) if i == 0 or cpu[i] - cpu[i - 1] > 1 << 32)
    if max(range(len(cpu)), key=lambda i: regions[i].stat().st_mtime) < first:
        first = 0
    regions = regions[first:]
    out = bytearray(b'TRI1' + struct.pack('<I', len(GPU)))
    starts = sorted(GPU.values())
    for index, gpu in sorted(GPU.items()):
        data = regions[index].read_bytes()
        # Captured CPU regions can be larger than the GPU resource: stop at
        # the next resource (R3 at 0x1_00000000 would cover R8 at +0x4000).
        following = [s for s in starts if s > gpu]
        if following:
            data = data[:following[0] - gpu]
        out += struct.pack('<QII', gpu, len(data), int(gpu < 1 << 32)) + data
    pathlib.Path(sys.argv[2]).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(sys.argv[2]).write_bytes(out)
    print(f'{sys.argv[2]}: {len(GPU)} regions, {len(out)} bytes')


if __name__ == '__main__':
    main()
