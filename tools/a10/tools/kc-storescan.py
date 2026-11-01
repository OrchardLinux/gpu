#!/usr/bin/env python3
"""Find arm64 code storing given 32-bit constants at given offsets (microsequence
builders). A store `str wT, [xN, #off]` matches when wT was last set by
`movz wT, #value` (or `orr wT, wzr, #value`) within the preceding 16 words.

  kc-storescan.py KERNELCACHE OFF=VALUE [OFF=VALUE...]   # e.g. 0x48=0x100 0x7c=2
Prints windows (4 KiB) of code holding every requested store.
"""
import struct
import sys

sys.path.insert(0, __file__.rsplit('/', 1)[0])
xref = __import__('kc-xref')


def main():
    data = xref.thin(open(sys.argv[1], 'rb').read())
    wanted = {int(k, 0): int(v, 0) for k, v in (a.split('=') for a in sys.argv[2:])}
    for name, seg_va, off, size in xref.segments(data):
        if not name.endswith('TEXT_EXEC'):
            continue
        words = struct.unpack_from(f'<{size // 4}I', data, off)
        last = {}  # register -> (value, index)
        hits = []
        for i, w in enumerate(words):
            if w & 0xff800000 == 0x52800000 and not (w >> 21) & 3:  # movz w, #imm16
                last[w & 31] = ((w >> 5) & 0xffff, i)
            elif w & 0xffc00000 == 0xb9000000:  # str w, [x, #imm12*4]
                t, offset = w & 31, ((w >> 10) & 0xfff) * 4
                if offset in wanted and t in last and last[t][0] == wanted[offset] and i - last[t][1] < 16:
                    hits.append((i, offset))
        hits.sort()
        for j, (i, _) in enumerate(hits):
            window = {o for k, o in hits if i <= k < i + 1024}
            if window == set(wanted) and (j == 0 or hits[j - 1][0] < i - 1024):
                print(f'{seg_va + 4 * i:#x}')


if __name__ == '__main__':
    main()
