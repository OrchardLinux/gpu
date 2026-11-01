#!/usr/bin/env python3
"""Which microsequence-argument words a firmware handler writes to which RGX
registers. Straight-line data flow only: `ldr rX, [rA, #k]` followed by
`str rX, [rB, #reg]`, where rB was loaded from the RGX base pointer slot
(`ldr rB, [sb]`). Prints `reg <- [rA + k]`; branches are not followed.

  uv run --no-project --with capstone python tools/regflow.py FIRMWARE START SIZE
"""
import re
import sys

from capstone import Cs, CS_ARCH_ARM, CS_MODE_THUMB

LOAD = re.compile(r'(r\d+|ip|lr|sl|fp|sb), \[(r\d+|ip|sl|fp|sb)(?:, #(-?0x[0-9a-f]+|\d+))?\]!?$')
STORE = re.compile(r'(r\d+|ip|lr|sl|fp|sb), \[(r\d+|ip|sl|fp|sb), #(0x[0-9a-f]+|\d+)\]$')
STRD = re.compile(r'(r\d+|ip|lr|sl|fp|sb), (r\d+|ip|lr|sl|fp|sb), \[(r\d+|ip|sl|fp|sb), #(0x[0-9a-f]+|\d+)\]$')


def main():
    data = open(sys.argv[1], 'rb').read()
    start, size = int(sys.argv[2], 0), int(sys.argv[3], 0)
    md = Cs(CS_ARCH_ARM, CS_MODE_THUMB)
    source = {}     # register -> 'base+offset' it was loaded from
    rgx = set()     # registers holding the RGX base
    slot = {'sb'}   # registers holding the address of the RGX base pointer
    for insn in md.disasm(data[start:start + size], start):
        op, args = insn.mnemonic.split('.')[0], insn.op_str
        if op in ('ldr', 'ldrh', 'ldrb') and (m := LOAD.match(args)):
            dest, base, offset = m.group(1), m.group(2), int(m.group(3) or '0', 0)
            if base in slot and offset == 0:
                rgx.add(dest)
                source.pop(dest, None)
            else:
                rgx.discard(dest)
                slot.discard(dest)
                origin = source.get(base, base)
                source[dest] = f'{origin}+{offset:#x}'
        elif op == 'ldrd' and (m := STRD.match(args)):
            a, b, base, offset = m.groups()
            offset = int(offset, 0)
            origin = source.get(base, base)
            source[a], source[b] = f'{origin}+{offset:#x}', f'{origin}+{offset + 4:#x}'
            rgx.discard(a), rgx.discard(b)
        elif op in ('str', 'strb', 'strh') and (m := STORE.match(args)):
            value, base, offset = m.group(1), m.group(2), int(m.group(3), 0)
            if base in rgx:
                print(f'{insn.address:#x} RGX+{offset:#06x} <- {source.get(value, value)}')
        elif op == 'strd' and (m := STRD.match(args)):
            a, b, base, offset = m.groups()
            if base in rgx:
                offset = int(offset, 0)
                print(f'{insn.address:#x} RGX+{offset:#06x} <- {source.get(a, a)}')
                print(f'{insn.address:#x} RGX+{offset + 4:#06x} <- {source.get(b, b)}')
        elif op in ('mov', 'movs', 'movw', 'adds', 'add', 'orr', 'bic', 'lsl', 'lsls', 'lsr', 'lsrs',
                    'and', 'ands', 'orrs', 'sub', 'subs', 'movt', 'bfi', 'ubfx', 'uxtb', 'uxth'):
            dest = args.split(',')[0]
            src = args.split(', ')[1] if len(args.split(', ')) == 2 else None
            copy = op in ('mov', 'movs') and src is not None
            if copy and src in source:
                source[dest] = source[src]
            elif op != 'movt':
                source.pop(dest, None)
            if copy and src in slot:
                slot.add(dest)
            elif dest != 'sb':
                slot.discard(dest)
            if copy and src in rgx:
                rgx.add(dest)
            else:
                rgx.discard(dest)
        elif op in ('bl', 'blx'):
            for r in ('r0', 'r1', 'r2', 'r3', 'ip', 'lr'):
                source.pop(r, None)
                rgx.discard(r)


if __name__ == '__main__':
    main()
