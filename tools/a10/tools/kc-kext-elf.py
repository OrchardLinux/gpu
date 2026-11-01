#!/usr/bin/env python3
"""Wrap one prelinked kext's segments (by VA) in a minimal AArch64 ELF so a
disassembler loads them at their kernel addresses. Prelinked (non-fileset)
kernelcaches only.

  kc-kext-elf.py KERNELCACHE KEXT_HEADER_VA OUT.elf
"""
import struct
import sys

sys.path.insert(0, __file__.rsplit('/', 1)[0])
xref = __import__('kc-xref')


def main():
    data = xref.thin(open(sys.argv[1], 'rb').read())
    segs = xref.segments(data)

    def offset(va):
        for _, v, o, s in segs:
            if v <= va < v + s:
                return o + va - v
        raise ValueError(f'{va:#x} not mapped')

    header = offset(int(sys.argv[2], 0))
    count = struct.unpack_from('<I', data, header + 16)[0]
    pos, parts = header + 32, []
    for _ in range(count):
        cmd, size = struct.unpack_from('<II', data, pos)
        if cmd == 0x19:
            name = data[pos + 8:pos + 24].split(b'\0')[0].decode()
            va, vsize = struct.unpack_from('<QQ', data, pos + 24)
            prot = struct.unpack_from('<I', data, pos + 60)[0]
            if vsize:
                start = offset(va)
                parts.append((name, va, data[start:start + vsize], prot))
        pos += size
    phoff, phsize = 64, 56
    body = phoff + phsize * len(parts)
    out, blobs = bytearray(), b''
    entry = next(va for name, va, _, _ in parts if name == '__TEXT_EXEC')
    out += b'\x7fELF\x02\x01\x01' + bytes(9)
    out += struct.pack('<HHIQQQIHHHHHH', 2, 183, 1, entry, phoff, 0, 0, 64, phsize,
                       len(parts), 64, 0, 0)
    cursor = body
    for name, va, blob, prot in parts:
        flags = (4 if prot & 1 else 0) | (2 if prot & 2 else 0) | (1 if prot & 4 else 0)
        out += struct.pack('<IIQQQQQQ', 1, flags, cursor, va, va, len(blob), len(blob), 0x4000)
        cursor += len(blob)
        blobs += blob
        print(f'{name:14} {va:#x} {len(blob):#x}')
    open(sys.argv[3], 'wb').write(out + blobs)


if __name__ == '__main__':
    main()
