#!/usr/bin/env python3
"""Tests for j81_meta_ldr_layout.py.

Synthetic tests always run (no firmware needed). Real-image tests run when the
private images are named by environment variables, otherwise they are skipped:
  J81_LDR_19H394  raw 19H394 LDR (AGXFirmwareKextG4G __TEXT.__const, 0x1cbb4 bytes)
  J81_LDR_81      raw iOS 8.1 G4G LDR image
Expected counts come from research/j81-meta-boot/RESULT.md (requests 5/7).
"""
import json
import os
import struct
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import j81_meta_ldr_layout as T  # noqa: E402


def _read(path, mode="rb"):
    with open(path, mode) as f:
        return f.read()


def build_ldr(records):
    """records: list of (kind, fields). Returns a synthetic LDR stream."""
    hdr = bytearray(16)
    body = bytearray()
    l2s = bytearray()
    base = 16
    l1_size = 24
    l1_count = len(records)
    l2_base = base + l1_size * l1_count
    l1 = []
    for kind, f in records:
        off = base + l1_size * len(l1)
        nxt = off + l1_size if len(l1) + 1 < l1_count else 0xFFFFFFFF
        if kind == "load":
            l2off = l2_base + len(l2s)
            payload = f["data"]
            l2s += struct.pack("<HH", 0x8000, len(payload) + 6) + payload + b"\0\0"
            while len(l2s) % 4:
                l2s += b"\0"
            l1.append(struct.pack("<HHIII8x", 0, l1_size, nxt, f["addr"], l2off))
        elif kind == "zero":
            l1.append(struct.pack("<HHIII8x", 4, l1_size, nxt, f["addr"], f["size"]))
        elif kind == "config":
            l2off = l2_base + len(l2s)
            p = b"".join(struct.pack("<III", f.get("type", 2), a, v) for a, v in f["writes"])
            l2s += struct.pack("<HH", 0x8005, len(p) + 6) + p + b"\0\0"
            while len(l2s) % 4:
                l2s += b"\0"
            l1.append(struct.pack("<HHII12x", 5, l1_size, nxt, l2off))
        elif kind == "threads":
            l2off = l2_base + len(l2s)
            p = b"".join(struct.pack("<IIII", t, sp, pc, 0) for t, sp, pc in f["threads"])
            l2s += struct.pack("<HH", 0x8003, len(p) + 6) + p + b"\0\0"
            while len(l2s) % 4:
                l2s += b"\0"
            l1.append(struct.pack("<HHII12x", 3, l1_size, nxt, l2off))
        elif kind == "comment":
            l1.append(struct.pack("<HHI16x", 0x10, l1_size, nxt))
    struct.pack_into("<IIIHH", hdr, 0, 0x01AA5500, 0x10, base, 0, 0)
    return bytes(hdr + b"".join(l1) + l2s)


SYNTH = [
    ("config", {"writes": [(0x04800070, 0xF0F0)]}),
    ("comment", {}),
    ("zero", {"addr": 0xE0001000, "size": 0x100}),
    ("load", {"addr": 0xE0001FF0, "data": b"\x11" * 16}),
    ("load", {"addr": 0x20000000, "data": b"\x22" * 0x40}),
    ("load", {"addr": 0xC0000000, "data": b"\x33" * 0x38}),
    ("load", {"addr": 0x10000000, "data": b"\x44" * 0x1800}),
    ("zero", {"addr": 0x10001800, "size": 0x100}),
    ("load", {"addr": 0x80000080, "data": b"\x55" * 0x20}),
    ("zero", {"addr": 0x8000A000, "size": 0x3C8}),
    ("config", {"writes": [(0x04830018, 1), (0x048000E8, 0x80)]}),
    ("threads", {"threads": [(1, 0x8000B3C8, 0x20000000), (0, 0x8000A3C8, 0x10000000)]}),
]


class Synthetic(unittest.TestCase):
    def setUp(self):
        self.img = build_ldr(SYNTH)
        self.hdr, self.recs = T.parse(self.img)
        self.lay = T.layout(self.recs, 0x1000, T.FW_HEAP_VA, 7, 0x11111111, 0x22222222)

    def test_counts(self):
        kinds = [r["kind"] for r in self.recs]
        self.assertEqual(kinds.count("LOADMEM"), 5)
        self.assertEqual(kinds.count("ZEROMEM"), 3)
        self.assertEqual(kinds.count("CONFIG"), 2)
        self.assertEqual(kinds.count("START_THREADS"), 1)

    def test_layout_order_and_sizes(self):
        s = self.lay["segments"]
        self.assertEqual([s[n]["offset"] for n in (2, 0, 1, 3)], [0, 0x1000, 0x3000, 0x4000])
        self.assertEqual(s[0]["size"], 0x2000)   # 0x1900 rounded up
        self.assertEqual(s[3]["min"], 0x60001000)
        self.assertEqual(self.lay["core"]["size"], 0x20)
        self.assertEqual(self.lay["core"]["offset"], 0x5000)
        self.assertEqual(self.lay["total"], 0x5020)
        self.assertEqual(len([x for x in self.lay["skipped"] if "core-memory" in x[1]]), 1)

    def test_copy_and_zero(self):
        im = self.lay["image"]
        self.assertEqual(im[0:0x38], b"\x33" * 0x38)              # seg2 at offset 0
        self.assertEqual(im[0x1000:0x1010], b"\x44" * 16)          # seg0
        self.assertEqual(im[0x3000:0x3040], b"\x22" * 0x40)        # seg1
        self.assertEqual(im[0x4000 + 0xFF0:0x4000 + 0x1000], b"\x11" * 16)  # seg3 min 0x60001000
        self.assertEqual(im[0x5000:0x5020], b"\x55" * 0x20)        # coremem

    def test_boot_list(self):
        bl = self.lay["boot_list"]
        self.assertEqual(len(bl), 12 + 3)
        self.assertEqual(bl[0], (0x04850000, 0x10000F02))
        self.assertEqual(bl[1], (0x04850004, 0x1FFF))
        self.assertEqual(bl[2], (0x04850008, 0xC0001000))
        self.assertEqual(bl[3], (0x0485000C, 0x7E1))
        self.assertEqual(bl[4][0], 0x04850010)
        self.assertEqual(bl[8], (0x04850030, 0x60001F02))
        self.assertEqual(bl[12:], [(0x04800070, 0xF0F0), (0x04830018, 1), (0x048000E8, 0x80)])
        im = self.lay["image"]
        end = T.LIST_OFFSET + 8 * len(bl)
        self.assertEqual(im[end:end + 8], bytes(8))
        tail = self.lay["tail_offset"]
        self.assertEqual(tail, 0xFF8)
        self.assertEqual(struct.unpack_from("<I", im, end + 8)[0], 0xC0000FF8)
        self.assertEqual(struct.unpack_from("<II", im, tail), (0x11111111, 0x22222222))

    def test_translator(self):
        self.assertEqual(T.fw_address(0xE1C0001000), 0xC0001000)
        self.assertEqual(T.fw_address(0xE1C0001000, w2=1), 0x40001000)
        self.assertEqual(T.fw_address(0xE1C3200000), 0x43200000)
        self.assertEqual(T.fw_address(0xE1C4200000), 0xC4200000)

    def test_configram(self):
        w = T.configram_words(0x123456000)
        self.assertEqual(len(w), 31)                       # 30 words + terminator (stock: +0x10000..+0x10078)
        self.assertEqual(w[:2], [0x00FF0104, 0x00E7FFFF])  # SOFT_RESET high half first
        self.assertEqual(w[12:14], [0x00FF0BF8, 1])         # META_BOOT
        self.assertEqual(w[14:18], [0x00FF1204, 0x1, 0x00FF1200, 0x23456000])
        self.assertEqual(w[-1], 0xFFFF0000)

    def test_config_type_rejected(self):
        bad = build_ldr([("config", {"writes": [(1, 2)], "type": 1})])
        with self.assertRaises(T.LdrError):
            T.parse(bad)

    def test_private_dir_refused_inside_repo(self):
        with tempfile.TemporaryDirectory() as d:
            subprocess.run(["git", "init", "-q", d], check=True)
            src = os.path.join(d, "x.ldr")
            with open(src, "wb") as f:
                f.write(self.img)
            r = subprocess.run([sys.executable, "-I", T.__file__, src, "--tables", os.path.join(d, "t"),
                                "--private", os.path.join(d, "priv")], capture_output=True, text=True)
            self.assertNotEqual(r.returncode, 0)
            self.assertFalse(os.path.exists(os.path.join(d, "priv", "fw-buffer.bin")))

    def test_cli_outputs(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "x.ldr")
            with open(src, "wb") as f:
                f.write(self.img)
            T.main([src, "--tables", os.path.join(d, "t"), "--private", os.path.join(d, "p")])
            m = json.loads(_read(os.path.join(d, "t", "manifest.json"), "r"))
            self.assertEqual(m["buffer"]["size"], "0x5020")
            self.assertEqual(os.stat(os.path.join(d, "p", "fw-buffer.bin")).st_mode & 0o777, 0o600)
            for name in os.listdir(os.path.join(d, "t")):
                self.assertNotIn(b"\x44" * 16, _read(os.path.join(d, "t", name)))


@unittest.skipUnless(os.environ.get("J81_LDR_19H394"), "J81_LDR_19H394 not set")
class Real19H394(unittest.TestCase):
    def test_counts_and_layout(self):
        img = _read(os.environ["J81_LDR_19H394"])
        self.assertEqual(len(img), 0x1CBB4)
        hdr, recs = T.parse(img)
        kinds = [r["kind"] for r in recs]
        self.assertEqual((len(recs), kinds.count("LOADMEM"), kinds.count("ZEROMEM"), kinds.count("CONFIG"),
                          kinds.count("COMMENT"), kinds.count("START_THREADS")), (88, 67, 13, 2, 5, 1))
        self.assertEqual(sum(len(r["writes"]) for r in recs if r["kind"] == "CONFIG"), 27)
        self.assertEqual((hdr["dev_id"], hdr["sl_data"]), (0x01AA5500, 0x1190))
        lay = T.layout(recs, 0x1000, T.FW_HEAP_VA, 7)
        s = lay["segments"]
        self.assertEqual((s[0]["min"], s[0]["end"]), (0x10000000, 0x10017970))
        self.assertEqual((s[1]["min"], s[1]["end"]), (0x20000000, 0x20001448))
        self.assertEqual((s[2]["min"], s[2]["end"]), (0x40000000, 0x40000038))
        self.assertEqual((s[3]["min"], s[3]["end"]), (0x60001000, 0x60002000))
        self.assertEqual((lay["core"]["meta_base"], lay["core"]["size"]), (0x80000080, 0x52B4))
        self.assertEqual(len([x for x in lay["skipped"] if "core-memory" in x[1]]), 3)
        self.assertEqual(len(lay["boot_list"]), 12 + 27)
        self.assertEqual(lay["threads"][0], {"thread": 1, "sp": 0x8000B3C8, "pc": 0x20000000, "catch": 0})


@unittest.skipUnless(os.environ.get("J81_LDR_81"), "J81_LDR_81 not set")
class Real81(unittest.TestCase):
    def test_counts(self):
        img = _read(os.environ["J81_LDR_81"])
        hdr, recs = T.parse(img)
        kinds = [r["kind"] for r in recs]
        self.assertEqual((len(recs), kinds.count("LOADMEM"), kinds.count("ZEROMEM"), kinds.count("CONFIG"),
                          kinds.count("COMMENT"), kinds.count("START_THREADS")), (80, 58, 14, 2, 5, 1))
        self.assertEqual(sum(len(r["writes"]) for r in recs if r["kind"] == "CONFIG"), 27)
        with self.assertRaises(T.LdrError):          # 19H394 rules cannot place the 8.1 core memory
            T.layout(recs, 0x1000, T.FW_HEAP_VA, 7)
        lay = T.layout(recs, 0x1000, T.FW_HEAP_VA, 7, coremem_base=0x80000000)
        self.assertEqual(len([x for x in lay["skipped"] if "core-memory" in x[1]]), 3)
        self.assertEqual(lay["core"]["meta_base"], 0x80000000)
        self.assertEqual(len(lay["boot_list"]), 12 + 27)


if __name__ == "__main__":
    unittest.main()
