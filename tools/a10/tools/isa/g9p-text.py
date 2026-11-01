#!/usr/bin/env python3
"""Print the USC code of each function in a metal-tt applegpu_g9p binary.

metal-tt -arch applegpu_g9p writes a Mach-O GPU executable; each function is
a nested Mach-O (MH_MAGIC_64) whose __TEXT,__text section is the function's
USC code (COMPUTE.md, "Native G9P code"). Prints one line per function:
name, size and the code as little-endian 16-bit words, trailing 0xc000
padding dropped.

  g9p-text.py FILE.g9p.bin [--raw]
"""
import struct
import sys

MH_MAGIC_64 = 0xfeedfacf
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2


def parse(data, base):
    """(name, code bytes) of the nested Mach-O at @base, or None."""
    if struct.unpack_from('<I', data, base)[0] != MH_MAGIC_64:
        return None
    ncmds = struct.unpack_from('<I', data, base + 16)[0]
    pos, text, name = base + 32, None, None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', data, pos)
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from('<I', data, pos + 64)[0]
            for s in range(nsects):
                sp = pos + 72 + 80 * s
                sect = data[sp:sp + 16].split(b'\0')[0]
                seg = data[sp + 16:sp + 32].split(b'\0')[0]
                ssize, off = struct.unpack_from('<QI', data, sp + 40)
                if sect == b'__text' and seg == b'__TEXT':
                    text = data[base + off:base + off + ssize]
        elif cmd == LC_SYMTAB:
            symoff, nsyms, stroff, _ = struct.unpack_from('<IIII', data, pos + 8)
            for k in range(nsyms):
                strx = struct.unpack_from('<I', data, base + symoff + 16 * k)[0]
                s = data[base + stroff + strx:].split(b'\0')[0].decode(errors='replace')
                if s and not s.startswith('ltmp'):
                    name = s
                    break
        pos += size
    return (name or '?', text) if text is not None else None


def main():
    data = open(sys.argv[1], 'rb').read()
    raw = '--raw' in sys.argv
    start = 4
    while (i := data.find(struct.pack('<I', MH_MAGIC_64), start)) >= 0:
        start = i + 4
        found = parse(data, i)
        if not found:
            continue
        name, code = found
        words = list(struct.unpack(f'<{len(code) // 2}H', code[:len(code) // 2 * 2]))
        while not raw and words and words[-1] == 0xc000:
            words.pop()
        print(f'{name} ({len(code)} bytes): ' + ' '.join(f'{w:04x}' for w in words))


if __name__ == '__main__':
    main()
