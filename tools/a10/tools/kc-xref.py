#!/usr/bin/env python3
"""Find code referencing a string in an arm64 kernelcache (ADRP + ADD pairs).

Prelinked (non-fileset) kernelcaches only: segments come from the Mach-O
header. Prints the referencing instruction's VA and the start of the function
around it (nearest preceding `pacibsp`/`stp x29, x30` prologue, heuristic).

  kc-xref.py KERNELCACHE STRING
"""
import struct
import sys


def segments(data):
    count = struct.unpack_from('<I', data, 16)[0]
    pos, found = 32, []
    for _ in range(count):
        cmd, size = struct.unpack_from('<II', data, pos)
        if cmd == 0x19:
            name = data[pos + 8:pos + 24].split(b'\0')[0].decode()
            va, vsize, off, fsize = struct.unpack_from('<QQQQ', data, pos + 24)
            found.append((name, va, off, fsize))
        pos += size
    return found


def va_of(segs, offset):
    for _, va, off, size in segs:
        if off <= offset < off + size:
            return va + offset - off
    return None


def thin(data):
    if data[:4] == b'\xca\xfe\xba\xbe':  # fat: take the arm64 slice
        for i in range(struct.unpack_from('>I', data, 4)[0]):
            cpu, _, offset, size, _ = struct.unpack_from('>IIIII', data, 8 + 20 * i)
            if cpu == 0x100000c:
                return data[offset:offset + size]
    return data


def main():
    data = thin(open(sys.argv[1], 'rb').read())
    needle = sys.argv[2].encode()
    segs = segments(data)
    targets = []
    start = 0
    while (hit := data.find(needle, start)) >= 0:
        begin = data.rfind(b'\0', max(0, hit - 4096), hit) + 1  # string start
        va = va_of(segs, begin)
        if va is not None:  # e.g. copies outside any segment
            targets += [va, va + hit - begin]
        start = hit + 1
    targets = set(t for t in targets if t)
    pages = {t & ~0xfff for t in targets}
    for name, seg_va, off, size in segs:
        if not name.endswith('TEXT_EXEC'):
            continue
        words = struct.unpack_from(f'<{size // 4}I', data, off)
        adrp = {}
        for i, w in enumerate(words):
            pc = seg_va + 4 * i
            if w & 0x9f000000 == 0x90000000:  # ADRP
                imm = ((w >> 29) & 3) | ((w >> 5) & 0x7ffff) << 2
                if imm & (1 << 20):
                    imm -= 1 << 21
                page = (pc & ~0xfff) + (imm << 12)
                if page in pages:
                    adrp[w & 31] = (page, pc)
                else:
                    adrp.pop(w & 31, None)
            elif w & 0xff800000 == 0x91000000 and (w >> 5) & 31 in adrp:  # ADD imm (64-bit)
                page, at = adrp[(w >> 5) & 31]
                shift = 12 if w & (1 << 22) else 0
                address = page + (((w >> 10) & 0xfff) << shift)
                if address in targets:
                    func = pc
                    for j in range(i, max(i - 4096, -1), -1):
                        if words[j] in (0xd503237f,) or words[j] & 0xffc07fff == 0xa9007bfd:
                            func = seg_va + 4 * j
                            if words[j] == 0xd503237f:
                                break
                    print(f'{pc:#x} refs {address:#x} (function ~{func:#x})')


if __name__ == '__main__':
    main()
