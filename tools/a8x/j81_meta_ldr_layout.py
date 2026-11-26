#!/usr/bin/env python3
"""Offline META LDR parser and J81 firmware-buffer layout builder.

Reproduces, from a META LDR stream, the "Firmware Image" buffer that the
iPadOS 15.8.5 (19H394) AGXG4G driver builds before it releases META, plus the
boot list the META boot code applies. No device access, no third-party packages.

Every rule below cites the 19H394 instruction that implements it (addresses are
kernel VAs in the AGXG4G kext; see the J81 notes in a8x/):

  pass 1, segment bounds          0xfffffff00668fc0c..0x668fd54
  layout (sizes, offsets, tail)   0xfffffff00668fd58..0x668fe24
  boot-list base = buffer + 0x200 0xfffffff00668ff04
  segment-MMU tuples, n != 2      0xfffffff0066947cc (fw vtable +0x480)
  pass 2, copy / zero / config    0xfffffff00668ffe8..0x669020c
  terminator, tail word           0xfffffff006690218..0x6690318
  firmware-address translator     0xfffffff006691704 (fw vtable +0x1a8)

Outputs:
  --tables DIR   text tables and a JSON manifest (no firmware bytes; payload
                 SHA-256 only). May be public.
  --private DIR  binary blobs: the memory image (one buffer, ready to DMA) and
                 the raw boot list. Created with mode 0700/0600. The tool refuses
                 a private directory inside a Git work tree unless Git ignores it.

Usage:
  j81_meta_ldr_layout.py IMAGE [--offset N --size N] --tables DIR [--private DIR]
      [--gpu-va 0xe1c0000000] [--align 0x1000] [--dm 7]
      [--root-fw-addr A --state-fw-addr A]

Placement assumptions (each is a caller parameter, recorded in the manifest):
  A1 --gpu-va: GPU VA of the buffer. Stock maps it with options 0x60007 into the
     firmware partition; the META boot default maps META 0x40000000 -> GPU VA
     0xe1c0000000 (seg2 OUTA read on J81 hardware, R1), and seg2 is at buffer
     offset 0, so the buffer must start at 0xe1c0000000 for META to find its boot
     code. Default 0xe1c0000000.
  A2 --align: the alignment unit is 1 << (global read via GOT 0x...6f2a698 at
     0x668fd68); its value on J81 was not resolved statically. Default 0x1000.
  A3 --dm: OUTA1 bits 11:8 come from init[+0x30c] & 0xf at emit time; the only
     store seen writes 7 (0x668fa2c) and the hardware seg2 default carries 7.
     Default 7.
  A5 --coremem-base: 19H394 core memory starts at 0x80000080; the 8.1 image at 0x80000000.
  A4 root/state firmware addresses for the tail (last 8 bytes of the aligned seg2
     region) are written by stock from objects the tool does not build; default 0.
"""
import argparse
import hashlib
import json
import os
import struct
import subprocess
import sys

CMD_NAMES = {0: "LOADMEM", 1: "LOADCORE", 2: "LOADMMREG", 3: "START_THREADS", 4: "ZEROMEM", 5: "CONFIG"}
COREMEM_BASE = 0x80000080            # constant at 0x6690040..44
COREMEM_WINDOW = 0x17F << 7          # (addr - 0x80000080) >> 7 must be < 0x17f (0x6690038)
FW_HEAP_VA = 0xE1C0000000
LIST_OFFSET = 0x200                  # 0x668ff04
SEG_MMU = 0x04850000                 # META_CR_MMCU_SEGMENT_N_BASE(0)
MAX_IMAGE = 16 << 20


class LdrError(ValueError):
    pass


def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def fw_address(va, w2=0, flag_1c9=0):
    """fw vtable +0x1a8 (0x6691704): META address for a GPU VA."""
    if va >= 0xE1C3200000:
        slow = va < 0xE1C4200000 or (w2 & 1)
    else:
        slow = w2 != 0
    region = (0x40000000 if flag_1c9 == 0 else 0xC0000000) if slow else 0xC0000000
    return ((va + 0x40000000) & 0xFFFFFFFF) | region


def segment_of(addr):
    return (addr >> 29) & 3


def in_coremem(addr, base=COREMEM_BASE):
    return ((addr - base) & 0xFFFFFFFF) < COREMEM_WINDOW


# Stock hardware-start writes (fw +0xe0, 0x6690bbc; accel +0x740/+0x748). With the J81 default
# "use GPC/Fender" bit set they are not stored to RGX: each goes to Fender ConfigRAM
# (Fender+0x10000, slots 0xa8/0xb0/0xb8/0xc0/0xc8 = 0x669c5dc..0x669c66c) and the list is
# applied by Fender at the next GPC state 0->1 change [inferred, strong].
def stock_rgx_writes(pc_phys):
    return [(64, 0x100, 0x00E7FFFFFFFFFC1D), (64, 0x100, 0x00E7FE071FFFFC1D), (64, 0x100, 0x0000000100000000),
            (32, 0xBF8, 0x1), (64, 0x1200, pc_phys), (64, 0x3800, 0x0003550000300001), (64, 0x3808, 0x1),
            (64, 0x100, 0x0)]


def configram_words(pc_phys, flag=0xFF):
    """Word list written at Fender+0x10000 (32-bit: reg|flag<<16, value; 64-bit: high half first)."""
    words = []
    for width, reg, val in stock_rgx_writes(pc_phys):
        if width == 32:
            words += [(reg & 0xFF00FFFF) | (flag << 16), val & 0xFFFFFFFF]
        else:
            words += [((reg + 4) & 0xFF00FFFF) | (flag << 16), val >> 32,
                      (reg & 0xFF00FFFF) | (flag << 16), val & 0xFFFFFFFF]
    return words + [0xFFFF0000]           # slot 0xb8 terminator (offset not advanced)


def parse(image):
    """Walk the L1 command stream exactly like the 19H394 loader."""
    if len(image) < 16:
        raise LdrError("image shorter than the LDR header")
    hdr = {"dev_id": u32(image, 0), "sl_code": u32(image, 4), "sl_data": u32(image, 8),
           "pc_ctrl": u16(image, 12), "crc": u16(image, 14)}
    recs = []
    off = hdr["sl_data"]
    seen = set()
    while off != 0xFFFFFFFF:
        if off in seen or off + 8 > len(image):
            raise LdrError("bad L1 next pointer %#x" % off)
        seen.add(off)
        cmd_raw = u16(image, off)
        nxt = u32(image, off + 4)
        cmd = cmd_raw & 0x1F               # Apple masks 0x1f (0x668fc78)
        rec = {"offset": off, "cmd_raw": cmd_raw, "next": nxt}
        if cmd_raw & 0x10:
            rec["kind"] = "COMMENT"
            length = u16(image, off + 2)
            text = image[off + 8: off + 8 + max(0, length - 8)]
            if b"/" in text:
                text = text[text.index(b"/"):]
            rec["text"] = text.split(b"\0")[0].decode("ascii", "replace").rsplit("/", 1)[-1]
        elif cmd == 0:
            addr, l2 = u32(image, off + 8), u32(image, off + 12)
            if l2 + 4 > len(image):
                raise LdrError("LOADMEM L2 out of range at %#x" % off)
            n = u16(image, l2 + 2) - 6       # 0x668fc90..9c and 0x6690028..2c
            if n < 0 or l2 + 4 + n > len(image):
                raise LdrError("LOADMEM length out of range at %#x" % off)
            payload = image[l2 + 4: l2 + 4 + n]
            rec.update(kind="LOADMEM", addr=addr, size=n, l2=l2, l2_tag=u16(image, l2),
                       payload=payload, sha256=hashlib.sha256(payload).hexdigest())
        elif cmd == 4:
            rec.update(kind="ZEROMEM", addr=u32(image, off + 8), size=u32(image, off + 12))
        elif cmd == 5:
            l2 = u32(image, off + 8)
            n = u16(image, l2 + 2) - 6
            if n % 12:
                raise LdrError("CONFIG payload not a multiple of 12 at %#x" % off)
            writes = []
            for p in range(l2 + 4, l2 + 4 + n, 12):
                typ, a, v = struct.unpack_from("<III", image, p)
                if typ != 2:                 # 0x6690130: anything but CFG_WRITE fails the load
                    raise LdrError("CONFIG entry type %d (stock accepts only 2=WRITE)" % typ)
                writes.append((a, v))
            rec.update(kind="CONFIG", writes=writes)
        elif cmd == 3:
            l2 = u32(image, off + 8)
            n = u16(image, l2 + 2) - 6
            threads = []
            for p in range(l2 + 4, l2 + 4 + n, 16):
                t, sp, pc, catch = struct.unpack_from("<IIII", image, p)
                threads.append({"thread": t, "sp": sp, "pc": pc, "catch": catch})
            rec.update(kind="START_THREADS", threads=threads)
        else:
            rec["kind"] = CMD_NAMES.get(cmd, "CMD%d" % cmd)
        recs.append(rec)
        off = nxt
    return hdr, recs


def layout(recs, align, gpu_va, dm, root_fw=0, state_fw=0, coremem_base=COREMEM_BASE):
    """coremem_base: 19H394 hard-codes 0x80000080 (0x6690040); the 8.1 image starts its core
    memory at 0x80000000, so the 19H394 rules cannot place it unchanged (pass 0x80000000 for 8.1;
    the 8.1 loader's own core-memory rule was not traced: inferred)."""
    if align & (align - 1) or align < 0x1000:
        raise LdrError("align must be a power of two >= 0x1000")
    segs = {n: {"min": 0xFFFFFFFF, "end": 0, "bytes": 0} for n in range(4)}
    core_min, core_end = 0xFFFFFFFF, 0
    skipped = []
    for r in recs:                           # pass 1 (0x668fc74..0x668fd40)
        if r["kind"] not in ("LOADMEM", "ZEROMEM"):
            continue
        a, n = r["addr"], r["size"]
        if n == 0 or (a >> 27) == 0:
            skipped.append((r["offset"], "zero length or address < 0x08000000"))
            continue
        if (a & 0x80000000) and a < 0x87FFFFFF:
            if in_coremem(a, coremem_base) and r["kind"] == "LOADMEM":
                core_min, core_end = min(core_min, a), max(core_end, a + n)
            else:
                skipped.append((r["offset"], "core-memory %s skipped by stock" % r["kind"]))
            continue
        s, m = segs[segment_of(a)], a & 0x7FFFFFFF
        s["bytes"] += n
        s["min"], s["end"] = min(s["min"], m), max(s["end"], m + n)
    for s in segs.values():                  # 0x668fd58..0x668fde8
        s["size"] = ((s["end"] - s["min"] - 1 + align) & ~(align - 1)) if s["end"] else 0
    order = [2, 0, 1, 3]                     # offsets: seg2 0, seg0 after it, ... (0x668fdf0..0x668fe04)
    pos = 0
    for n in order:
        segs[n]["offset"] = pos
        pos += segs[n]["size"]
    core_size = (core_end - core_min) if core_end else 0
    core_off = pos                           # 0x668fe20..24 (fw+0xa6c)
    total = pos + core_size                  # fw+0xa70
    tail_off = segs[2]["size"] - 8           # fw+0xa5c
    for n in range(4):
        s = segs[n]
        s["gpu_va"] = gpu_va + s["offset"]
        s["fw_addr"] = fw_address(s["gpu_va"]) if s["size"] else None

    img = bytearray(total)
    blist = []
    for n in (0, 1, 3):                      # emitter calls 0x668ff34/60/b8 (seg2 returns at 0x66947d0)
        s, va = segs[n], segs[n]["gpu_va"]
        base = SEG_MMU + 16 * n
        limit = s["size"] - 1 if s["size"] > 0x1000 else 0xFFF
        blist += [(base, (s["min"] | 0xF02) & 0xFFFFFFFF), (base + 4, limit),
                  (base + 8, va & 0xFFFFFFFF), (base + 0xC, ((dm & 0xF) << 8) | (va >> 32))]
    threads = []
    skipped_off = {o for o, _ in skipped}
    for r in recs:                           # pass 2 (0x668ffe8..)
        k = r["kind"]
        if k == "LOADMEM" and r["size"]:
            a = r["addr"]
            if in_coremem(a, coremem_base):
                dst = core_off + (a - coremem_base)
            elif r["offset"] in skipped_off:
                raise LdrError("LOADMEM at %#x (addr %#x) would be misplaced by the 19H394 loader rules; "
                               "check --coremem-base" % (r["offset"], a))
            else:
                s = segs[segment_of(a)]
                dst = s["offset"] + ((a & 0x7FFFFFFF) - s["min"])
            img[dst:dst + r["size"]] = r["payload"]
            if bytes(img[dst:dst + r["size"]]) != r["payload"]:   # stock byte-verifies (0x66901ec)
                raise LdrError("copy verify failed")
        elif k == "ZEROMEM" and r["size"] and not in_coremem(r["addr"], coremem_base):
            a = r["addr"]
            if r["offset"] in skipped_off:
                continue
            s = segs[segment_of(a)]
            dst = s["offset"] + ((a & 0x7FFFFFFF) - s["min"])
            img[dst:dst + r["size"]] = bytes(r["size"])
        elif k == "CONFIG":
            blist += r["writes"]
        elif k == "START_THREADS":
            threads = r["threads"]
    tail_word = fw_address(gpu_va + tail_off)
    raw = b"".join(struct.pack("<II", a, v) for a, v in blist) + bytes(8) + struct.pack("<I", tail_word)
    seg2_payload_end = segs[2]["end"] - segs[2]["min"]
    if LIST_OFFSET < seg2_payload_end or LIST_OFFSET + len(raw) > tail_off:
        raise LdrError("boot list does not fit between seg2 payload and tail")
    img[LIST_OFFSET:LIST_OFFSET + len(raw)] = raw
    struct.pack_into("<II", img, tail_off, root_fw & 0xFFFFFFFF, state_fw & 0xFFFFFFFF)
    return {
        "segments": segs, "order": order, "core": {"meta_base": core_min if core_end else None,
        "size": core_size, "offset": core_off, "gpu_va": gpu_va + core_off,
        "fw_addr": fw_address(gpu_va + core_off, w2=1)}, "total": total,
        "boot_list": blist, "boot_list_raw": raw, "tail_offset": tail_off, "tail_word": tail_word,
        "threads": threads, "skipped": skipped, "image": bytes(img)}


def git_unsafe(path):
    """True if path lies in a Git work tree and is not ignored (path may not exist yet)."""
    d = os.path.abspath(path)
    probe = d
    while not os.path.isdir(probe):
        probe = os.path.dirname(probe)
    try:
        top = subprocess.run(["git", "-C", probe, "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True)
    except FileNotFoundError:
        return False
    if top.returncode != 0:
        return False
    ign = subprocess.run(["git", "-C", probe, "check-ignore", "-q", "--no-index", d])
    return ign.returncode != 0


def write_private(path, name, data):
    os.makedirs(path, mode=0o700, exist_ok=True)
    os.chmod(path, 0o700)
    fd = os.open(os.path.join(path, name), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(data)


def h(v):
    return None if v is None else "%#x" % v


def emit(hdr, recs, lay, args, tables, private):
    os.makedirs(tables, exist_ok=True)
    counts = {}
    for r in recs:
        counts[r["kind"]] = counts.get(r["kind"], 0) + 1
    with open(os.path.join(tables, "ldr-records.tsv"), "w") as f:
        f.write("ldr_offset\tcommand\tmeta_address\tsize\tsegment\tnote\n")
        for r in recs:
            k = r["kind"]
            if k in ("LOADMEM", "ZEROMEM"):
                a = r["addr"]
                seg = "coremem" if in_coremem(a, args.coremem_base) else "seg%d" % segment_of(a)
                note = ("payload sha256 " + r["sha256"]) if k == "LOADMEM" else ""
                f.write("%#x\t%s\t%#010x\t%#x\t%s\t%s\n" % (r["offset"], k, a, r["size"], seg, note))
            elif k == "CONFIG":
                f.write("%#x\tCONFIG\t\t\t\t%d writes\n" % (r["offset"], len(r["writes"])))
            elif k == "START_THREADS":
                f.write("%#x\tSTART_THREADS\t\t\t\t%s\n" % (r["offset"], "; ".join(
                    "T%d pc=%#x sp=%#x" % (t["thread"], t["pc"], t["sp"]) for t in r["threads"])))
            else:
                f.write("%#x\t%s\t\t\t\t%s\n" % (r["offset"], k, r.get("text", "")))
    with open(os.path.join(tables, "ldr-config.tsv"), "w") as f:
        f.write("ldr_offset\torder\tmeta_register\tvalue\n")
        for r in recs:
            if r["kind"] == "CONFIG":
                for i, (a, v) in enumerate(r["writes"], 1):
                    f.write("%#x\t%d\t%#010x\t%#x\n" % (r["offset"], i, a, v))
    with open(os.path.join(tables, "buffer-layout.tsv"), "w") as f:
        f.write("region\tmeta_min\tmeta_end\tbuffer_offset\tsize\tgpu_va\tfw_addr\n")
        for n in lay["order"]:
            s = lay["segments"][n]
            f.write("seg%d\t%s\t%s\t%#x\t%#x\t%#x\t%s\n" % (n, h(s["min"]) if s["end"] else "", h(s["end"]) if s["end"] else "",
                                                         s["offset"], s["size"], s["gpu_va"], h(s["fw_addr"])))
        c = lay["core"]
        f.write("coremem\t%s\t%s\t%#x\t%#x\t%#x\t%s\n" % (h(c["meta_base"]), h((c["meta_base"] or 0) + c["size"]),
                                                       c["offset"], c["size"], c["gpu_va"], h(c["fw_addr"])))
        f.write("boot-list\t\t\t%#x\t%#x\t%#x\t%s\n" % (LIST_OFFSET, len(lay["boot_list_raw"]),
                                                     args.gpu_va + LIST_OFFSET, h(fw_address(args.gpu_va + LIST_OFFSET))))
        f.write("tail(root,state)\t\t\t%#x\t0x8\t%#x\t%s\n" % (lay["tail_offset"], args.gpu_va + lay["tail_offset"], h(lay["tail_word"])))
    with open(os.path.join(tables, "boot-list.tsv"), "w") as f:
        f.write("index\tbuffer_offset\tmeta_register\tvalue\tsource\n")
        for i, (a, v) in enumerate(lay["boot_list"]):
            src = "segment-MMU tuple" if i < 12 else "LDR CONFIG write"
            f.write("%d\t%#x\t%#010x\t%#010x\t%s\n" % (i, LIST_OFFSET + 8 * i, a, v, src))
        i = len(lay["boot_list"])
        f.write("%d\t%#x\t0x00000000\t0x00000000\tterminator\n" % (i, LIST_OFFSET + 8 * i))
        f.write("tail-word\t%#x\t\t%#010x\tfw address of buffer+%#x\n" % (LIST_OFFSET + 8 * i + 8, lay["tail_word"], lay["tail_offset"]))
    manifest = {
        "tool": "j81_meta_ldr_layout.py", "source_image_sha256": hashlib.sha256(args._image).hexdigest(),
        "header": {k: h(v) for k, v in hdr.items()}, "record_counts": counts,
        "config_writes": sum(len(r["writes"]) for r in recs if r["kind"] == "CONFIG"),
        "parameters": {"gpu_va": h(args.gpu_va), "align": h(args.align), "dm": args.dm, "coremem_base": h(args.coremem_base),
                       "root_fw_addr": h(args.root_fw_addr), "state_fw_addr": h(args.state_fw_addr)},
        "assumptions": ["A1 buffer GPU VA = gpu_va (stock: firmware partition, must equal META 0x40000000 boot mapping)",
                        "A2 align = 1 << unresolved global (GOT 0x6f2a698)", "A3 OUTA1 DM = dm (init+0x30c)",
                        "A4 tail root/state addresses supplied by caller, default 0"],
        "buffer": {"size": h(lay["total"]), "gpu_va": h(args.gpu_va),
                   "regions": [{"name": "seg%d" % n, "offset": h(lay["segments"][n]["offset"]), "size": h(lay["segments"][n]["size"]),
                                "meta_min": h(lay["segments"][n]["min"]) if lay["segments"][n]["end"] else None,
                                "gpu_va": h(lay["segments"][n]["gpu_va"]), "fw_addr": h(lay["segments"][n]["fw_addr"])} for n in lay["order"]]
                   + [{"name": "coremem", "offset": h(lay["core"]["offset"]), "size": h(lay["core"]["size"]),
                       "meta_base": h(lay["core"]["meta_base"]), "gpu_va": h(lay["core"]["gpu_va"]),
                       "fw_addr": h(lay["core"]["fw_addr"]),
                       "note": "stock passes fw_addr, gpu_va, size to the firmware at init block +0x480/+0x484/+0x48c"}],
                   "boot_list": {"offset": h(LIST_OFFSET), "size": h(len(lay["boot_list_raw"])),
                                 "pairs": [[h(a), h(v)] for a, v in lay["boot_list"]],
                                 "terminator_offset": h(LIST_OFFSET + 8 * len(lay["boot_list"])),
                                 "tail_word": h(lay["tail_word"])},
                   "tail": {"offset": h(lay["tail_offset"]), "root_fw_addr": h(args.root_fw_addr), "state_fw_addr": h(args.state_fw_addr)}},
        "entry_points": {"boot_pc_meta": "0x40000000 (META_BOOT master boot; seg2 at buffer offset 0)",
                         "threads": [{k: h(v) if k != "thread" else v for k, v in t.items()} for t in lay["threads"]],
                         "note": "stock host keeps only thread 1 (pc, sp) at fw+0xb48 (0x6690084)"},
        "skipped_records": [[h(o), why] for o, why in lay["skipped"]],
        "image_sha256": hashlib.sha256(lay["image"]).hexdigest(),
        "fender_configram": {"base": "Fender+0x10000", "pc_phys": h(args.pc_phys),
                             "words": [h(w) for w in configram_words(args.pc_phys)],
                             "note": "stock J81 hardware-start list; applied at GPC state 0->1 [inferred]"},
    }
    with open(os.path.join(tables, "fender-configram.tsv"), "w") as f:
        f.write("fender_offset\tword\tmeaning\n")
        names = {0x100: "SOFT_RESET", 0xBF8: "META_BOOT", 0x1200: "BIF_CAT_BASE0", 0x3800: "SLC_CTRL_MISC", 0x3808: "0x3808"}
        i = 0
        for width, reg, val in stock_rgx_writes(args.pc_phys):
            parts = ([("reg", reg), ("value", val)] if width == 32 else
                     [("reg+4", reg + 4), ("value[63:32]", val >> 32), ("reg", reg), ("value[31:0]", val & 0xFFFFFFFF)])
            for (what, _), w in zip(parts, configram_words(args.pc_phys)[i:i + len(parts)]):
                f.write("%#x\t%#010x\t%s %s\n" % (0x10000 + 4 * i, w, names[reg], what))
                i += 1
        f.write("%#x\t0xffff0000\tterminator\n" % (0x10000 + 4 * i))
    with open(os.path.join(tables, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=1)
    if private:
        write_private(private, "fw-buffer.bin", lay["image"])
        write_private(private, "boot-list.bin", lay["boot_list_raw"])
    return manifest


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("image")
    p.add_argument("--offset", type=lambda x: int(x, 0), default=0)
    p.add_argument("--size", type=lambda x: int(x, 0), default=None)
    p.add_argument("--tables", required=True)
    p.add_argument("--private")
    p.add_argument("--gpu-va", type=lambda x: int(x, 0), default=FW_HEAP_VA)
    p.add_argument("--align", type=lambda x: int(x, 0), default=0x1000)
    p.add_argument("--dm", type=int, default=7)
    p.add_argument("--pc-phys", type=lambda x: int(x, 0), default=0,
                   help="page-catalogue physical address for BIF_CAT_BASE0 in the ConfigRAM list")
    p.add_argument("--coremem-base", type=lambda x: int(x, 0), default=COREMEM_BASE)
    p.add_argument("--root-fw-addr", type=lambda x: int(x, 0), default=0)
    p.add_argument("--state-fw-addr", type=lambda x: int(x, 0), default=0)
    args = p.parse_args(argv)
    if args.private and git_unsafe(args.private):
        p.error("--private is inside a Git work tree and not ignored; refusing to write firmware bytes there")
    with open(args.image, "rb") as f:
        f.seek(args.offset)
        data = f.read(args.size if args.size is not None else MAX_IMAGE + 1)
    if len(data) > MAX_IMAGE:
        p.error("image larger than 16 MiB; pass --offset/--size")
    args._image = data
    hdr, recs = parse(data)
    lay = layout(recs, args.align, args.gpu_va, args.dm, args.root_fw_addr, args.state_fw_addr, args.coremem_base)
    m = emit(hdr, recs, lay, args, args.tables, args.private)
    print(json.dumps({"record_counts": m["record_counts"], "config_writes": m["config_writes"],
                      "buffer_size": m["buffer"]["size"], "boot_list_pairs": len(lay["boot_list"]),
                      "image_sha256": m["image_sha256"]}, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
