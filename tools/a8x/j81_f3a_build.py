#!/usr/bin/env python3
"""Build the position-independent F3a blob for kernel/j81-gpu (plan: research/2026-11-26-j81-f3a-plan.md).

The blob is the first 0x101000 bytes of the module's 8 MiB DMA region:
  0x000000..0x0a5fff  firmware heap image (GPU VA 0xe1c0000000 + offset; every pointer in it is heap-relative, so no physical address)
  0x100000            header: magic 'F3A1', nwords, rel_idx, ev_ctl_off, ev_buf_off, heap_used, cat_hi_idx, cat_lo_idx
  0x100040            ConfigRAM word template (31 words; BIF_CAT_BASE0 words are patched by the module's f3load)
Firmware bytes (the Apple META LDR) come from a private, git-ignored file; the blob is written to a private directory too.

Layout and field values: requests 4 (appendix-t2-ddk.md sec. 3/4), 8, 12, 13. Every value marked GUESS below is not decoded from the
kext yet (research request 14): the first-boot run may fail on exactly those.

usage: j81_f3a_build.py LDR_IMAGE OUT_DIR [CFG_2F0] [WINDOWS]   (OUT_DIR must not exist and must be git-ignored; CFG_2F0 = u64 for config +0x2f0, default 0; WINDOWS=1 fills the MMIO window table and tells the module to map the pages)
"""
import hashlib
import struct
import subprocess
import sys
from pathlib import Path

HEAP_USED = 0xA6000
HDR = 0x100000
BLOB_SIZE = HDR + 0x1000
FW = 0xC0000000  # fwaddr(x) = heap_offset | 0xC0000000 (heap region)

# heap object offsets (all 4 KiB aligned; sizes from request 4 appendix t2)
FWBUF = 0x000000          # 0x212b4 from the layout tool, ends 0x22000
ROOT, STATE, CONFIG = 0x022000, 0x024000, 0x027000
BLK990, BLK8E0, BLK8C0, BLK938, BLK28, BLK84 = 0x028000, 0x029000, 0x02A000, 0x02B000, 0x02C000, 0x02D000
BLK218, BLK3F8, BLK3F0, BLK400 = 0x02E000, 0x02F000, 0x030000, 0x031000   # sizes unresolved (accel slots 0x760/0x990): 4 KiB each, zero
RINGS = {  # name: (ctl, buf)
    "TA": (0x040000, 0x041000), "3D": (0x043000, 0x044000), "CL": (0x046000, 0x047000), "DEVCTL": (0x049000, 0x04A000),
    "EVENT": (0x04C000, 0x04D000), "LOG": (0x050000, 0x051000), "FWTRACE": (0x05D000, 0x05E000), "R36": (0x061000, 0x062000),
}
LOG2 = 0x070000           # 0x36000 bytes, ends 0xa6000


def fwaddr(off):
    return FW | off


def main() -> int:
    if len(sys.argv) not in (3, 4, 5):
        print(__doc__)
        return 2
    ldr, out = Path(sys.argv[1]), Path(sys.argv[2])
    cfg2f0 = int(sys.argv[3], 0) if len(sys.argv) >= 4 else 0
    windows = len(sys.argv) == 5 and sys.argv[4] == "1"
    out.mkdir(parents=True, mode=0o700)
    tool = Path(__file__).resolve().parent / "j81_meta_ldr_layout.py"
    tables, priv = out / "tables", out / "priv"
    subprocess.run([sys.executable, "-I", str(tool), str(ldr), "--tables", str(tables), "--private", str(priv), "--pc-phys", "0",
                    "--root-fw-addr", hex(fwaddr(ROOT)), "--state-fw-addr", hex(fwaddr(STATE))], check=True, stdout=subprocess.DEVNULL)
    fwbuf = (priv / "fw-buffer.bin").read_bytes()
    assert len(fwbuf) <= STATE - FWBUF and len(fwbuf) <= ROOT, "firmware buffer overlaps the root block"
    layout = {}
    for line in (tables / "buffer-layout.tsv").read_text().splitlines()[1:]:
        f = line.split("\t")
        layout[f[0]] = f
    coremem_fwaddr = int(layout["coremem"][6], 0)
    coremem_va = int(layout["coremem"][5], 0)
    coremem_size = int(layout["coremem"][4], 0)
    words = []
    for line in (tables / "fender-configram.tsv").read_text().splitlines()[1:]:
        words.append(int(line.split("\t")[1], 0))
    assert len(words) == 31 and words[-1] == 0xFFFF0000
    # indices of the BIF_CAT_BASE0 value words and of the final SOFT_RESET release entry
    cat_hi, cat_lo, rel_idx = 15, 17, 26
    assert words[cat_hi - 1] == 0x00FF1204 and words[cat_lo - 1] == 0x00FF1200 and words[rel_idx] == 0x00FF0104
    img = bytearray(BLOB_SIZE)
    img[FWBUF:FWBUF + len(fwbuf)] = fwbuf

    def p32(base, off, v):
        struct.pack_into("<I", img, base + off, v & 0xFFFFFFFF)

    def p64(base, off, v):
        struct.pack_into("<Q", img, base + off, v)

    # root block (request 4 t2 sec. 3)
    ring_order = ["TA", "3D", "CL", "DEVCTL", "EVENT", "LOG", "FWTRACE", "R36"]
    for i, name in enumerate(ring_order):
        ctl, buf = RINGS[name]
        p32(ROOT, 8 * i, fwaddr(ctl))
        p32(ROOT, 8 * i + 4, fwaddr(buf))
    for off, blk in zip((0x64, 0x68, 0x6C, 0x70, 0x74), (BLK990, BLK8E0, BLK8C0, BLK938, BLK28)):
        p32(ROOT, off, fwaddr(blk))
    p32(ROOT, 0x44C, fwaddr(BLK84))
    p32(ROOT, 0x450, fwaddr(BLK218))
    p32(ROOT, 0x454, fwaddr(CONFIG))
    p32(ROOT, 0x458, fwaddr(BLK3F8))
    p32(ROOT, 0x45C, fwaddr(LOG2))
    p32(ROOT, 0x480, coremem_fwaddr)
    p64(ROOT, 0x484, coremem_va)
    p32(ROOT, 0x48C, coremem_size)
    # state block
    p32(STATE, 0x24, 120)
    p32(STATE, 0x30, 1)           # inferred
    p32(STATE, 0x1044, fwaddr(BLK3F0))
    p32(STATE, 0x1048, fwaddr(BLK400))
    # config block
    for i, v in enumerate((0x500000000, 0x600000000, 0x100000000, 0x100000000, 0x300000000, 0x300000000)):  # GUESS: appendix truncated the low digits
        p64(CONFIG, 8 * i, v)
    for off, v in ((0x250, 1), (0x258, 1), (0x26C, 1), (0x270, 1), (0x274, 1), (0x288, 1), (0x2E4, 0x10), (0x2E8, 0x400), (0x2EC, 0x20), (0x30C, 7)):
        p32(CONFIG, off, v)
    p64(CONFIG, 0x300, 0xE1C0000000)
    p64(CONFIG, 0x2F0, cfg2f0)   # request 4: u64 from an LDR-stream record, 32-bit halves swapped (0x69008c); the host keeps only thread 1's (pc, sp)
    if windows:   # request 14 t2: {u64 phys, u32 fwaddr, u32 size}; partition 9 VA 0xe1c4200000 -> fwaddr 0xc42xxxxx; RGX (index 3) is never mapped (fwaddr 0)
        for i, (phys, fwa, size) in enumerate(((0x201E00000, 0xC4200000, 0x5000), (0x20E101000, 0xC4205000, 0x1000),
                                                (0x20E104000, 0xC4206000, 0x1000), (0x201000000, 0, 0x20000))):
            p64(CONFIG, 0x1C0 + 16 * i, phys)
            p32(CONFIG, 0x1C0 + 16 * i + 8, fwa)
            p32(CONFIG, 0x1C0 + 16 * i + 12, size)
    # +0x2f0 (LDR record), +0x30..+0x1b8, +0x290..: see request 14 t1 (left zero unless set above)
    # list-head blocks: {0, self, 0, self+8} (two empty TAILQ heads), 0x8e0 also +0x778 = 0xffffffff
    for blk in (BLK990, BLK8E0, BLK8C0):
        p32(blk, 4, fwaddr(blk))
        p32(blk, 12, fwaddr(blk) + 8)
    p32(BLK8E0, 0x778, 0xFFFFFFFF)
    # header + ConfigRAM template
    ev_ctl, ev_buf = RINGS["EVENT"]
    struct.pack_into("<9I", img, HDR, 0x31413346, len(words), rel_idx, ev_ctl, ev_buf, HEAP_USED, cat_hi, cat_lo, 1 if windows else 0)
    for i, w in enumerate(words):
        struct.pack_into("<I", img, HDR + 0x40 + 4 * i, w)
    blob = out / "j81-f3a.blob"
    fd = blob.open("xb")
    fd.write(img)
    fd.close()
    blob.chmod(0o600)
    s = sum(struct.unpack_from("<I", img, i)[0] for i in range(0, HEAP_USED, 4)) & 0xFFFFFFFF
    print(f"blob {blob} {len(img):#x} bytes sha256 {hashlib.sha256(img).hexdigest()}")
    print(f"heap checksum (u32 sum over 0..{HEAP_USED:#x}) {s:08x}   [module status f3=...,s{s:08x} must match]")
    print(f"ev_ctl {ev_ctl:#x} ev_buf {ev_buf:#x} root fwaddr {fwaddr(ROOT):#x} state fwaddr {fwaddr(STATE):#x} nwords {len(words)} rel_idx {rel_idx}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
