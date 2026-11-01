#!/usr/bin/env python3
"""Offline disassembly of a thin/fat ARM64 kernelcache or raw Thumb firmware.

uv run --no-project --with capstone python tools/disasm.py KERNEL VA [SIZE]
uv run --no-project --with capstone python tools/disasm.py --thumb FIRMWARE OFFSET [SIZE]
Addresses are unslid. No firmware or proprietary disassembly is redistributed.
"""
import argparse
import struct
from pathlib import Path


def macho_segments(data):
    """Return (thin image, [(name, VA, file offset, file size)])."""
    if data[:4] == b"\xca\xfe\xba\xbe":
        count = struct.unpack_from(">I", data, 4)[0]
        for i in range(count):
            cpu, _, offset, size, _ = struct.unpack_from(">IIIII", data, 8 + i * 20)
            if cpu == 0x100000c:
                data = data[offset:offset + size]
                break
        else:
            raise ValueError("no ARM64 slice")
    if data[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError("expected a 64-bit little-endian Mach-O")
    segments = []
    pos = 32
    for _ in range(struct.unpack_from("<I", data, 16)[0]):
        cmd, size = struct.unpack_from("<II", data, pos)
        if size < 8 or pos + size > len(data):
            raise ValueError("invalid load command")
        if cmd == 0x19:
            name = data[pos + 8:pos + 24].split(b"\0")[0].decode()
            va, _, offset, length = struct.unpack_from("<QQQQ", data, pos + 24)
            segments.append((name, va, offset, length))
        pos += size
    return data, segments


def main():
    from capstone import Cs, CS_ARCH_ARM, CS_ARCH_ARM64, CS_MODE_THUMB, CS_MODE_ARM
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--thumb", action="store_true")
    parser.add_argument("image", type=Path)
    parser.add_argument("address", type=lambda s: int(s, 0))
    parser.add_argument("size", nargs="?", type=lambda s: int(s, 0), default=0x200)
    args = parser.parse_args()
    data = args.image.read_bytes()
    address = args.address
    if args.thumb:
        address &= ~1
        offset = address
        decoder = Cs(CS_ARCH_ARM, CS_MODE_THUMB)
    else:
        data, segments = macho_segments(data)
        for _, va, start, length in segments:
            if va <= address and address + args.size <= va + length:
                offset = start + address - va
                break
        else:
            parser.error("address range is not file-backed")
        decoder = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    for ins in decoder.disasm(data[offset:offset + args.size], address):
        print(f"{ins.address:#018x}: {ins.mnemonic:9} {ins.op_str}")


if __name__ == "__main__":
    main()
