#!/usr/bin/env python3
"""Tests for minim.py that need no Apple firmware.

usage: python3 test_minim.py [-v]          (or: python3 -m unittest test_minim)

Every input here is synthetic: standard META words worked out by hand from the
public Meta HTP TRM 2.1.235 encoding diagrams, and halfword streams built from
the branch encoder. Nothing is read from a kernelcache or a firmware image.

With METAG_OBJDUMP pointing at a metag-linux-objdump (build-metag-binutils.sh),
one more test runs the whole region pipeline through it. On macOS the objdump is
a Linux binary: point METAG_OBJDUMP at a wrapper script that runs it in Docker.
"""
import importlib.util
import json
import os
import pathlib
import struct
import tempfile
import unittest

HERE = pathlib.Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location('minim', HERE / 'minim.py')
m = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m)


def halves(*hw):
    return struct.pack('<' + 'H' * len(hw), *hw)


class TrmEncodings(unittest.TestCase):
    """MINIM halfwords against the standard META word the TRM gives for them."""

    GP = [  # (main halfword, extension or None, standard META word, what it is)
        (0x0e02, 0x101, 0x03208005, 'MOVT D1RtP,#0x1000'),
        (0x8402, 0x801, 0x82040005, 'MOVT A0StP,#0x8000'),
        (0x6a52, None, 0x622000a4, 'MULD D0FrT,D0FrT,#0x14'),
        (0x9c81, 0x171, 0xa3015c20, 'MOV D0.5,TXSTAT'),
        (0x93fe, None, 0xa0fffffe, 'Bcc NV, offset -1: never taken, objdump prints NOP'),
        (0x2a8e, 0x1031, 0x262803e2, 'AND D0.5,D0Re0,#0xf'),
        (0x5274, None, 0x5020ca00, 'LSL D0FrT,D0Ar2,D0.5'),
    ]
    DCACHE = [  # TRM 3.7.5: 5-bit Rs, 3-bit Rb
        (0xbd2c, 0x4028, 0xad290028),
        (0xbd2a, 0x4048, 0xad288048),
        (0xbd14, 0x4028, 0xad110028),
        (0xbd23, 0x4048, 0xad20c048),
    ]

    def test_gp(self):
        for c, e, w, what in self.GP:
            with self.subTest(what):
                self.assertEqual(m.expand(c, e), w)

    def test_dcache(self):
        for h, h2, w in self.DCACHE:
            self.assertEqual(m.expand_long(h, h2), w)

    def test_dcache_reserved_fields_rejected(self):
        self.assertIsNone(m.expand_long(0xbd2c, 0x40a8))  # bit 7 reserved
        self.assertIsNone(m.expand_long(0xbd2c, 0x4029))  # bits 2..0 reserved


class Classify(unittest.TestCase):
    def test_every_halfword(self):
        for hw in range(0x10000):
            kind = m.classify(hw)
            if hw >= 0xc000:
                self.assertEqual(kind, 'ext')
            elif hw >> 12 == 0xb:
                self.assertEqual(kind, 'long')
            elif 0x9000 <= hw < 0x9c00:
                self.assertIn(kind, ('bcc', 'b', 'callr'))
                self.assertIsNotNone(m.short_branch(hw))
            elif 0x9c00 <= hw < 0xa000:
                self.assertEqual(kind, 'mset')
                self.assertIsNone(m.short_branch(hw))
            else:
                self.assertEqual(kind, 'gp')
                self.assertIsNone(m.short_branch(hw))


class Branches(unittest.TestCase):
    PC = 0x80001000

    def test_b16_full_range(self):
        for units in range(m.B16_UNITS[0], m.B16_UNITS[1] + 1):
            raw, form = m.encode_branch(self.PC, self.PC + 4 * units, size=2)
            hw = struct.unpack('<H', raw)[0]
            self.assertEqual(form, 'b')
            self.assertEqual(m.short_branch(hw), {'form': 'b', 'cc': None, 'r': 0, 'offset': units})

    def test_bcc16_all_conditions(self):
        for cc in range(1, 16):
            for r in (0, 1):
                for units in range(m.BCC16_UNITS[0], m.BCC16_UNITS[1] + 1):
                    raw, form = m.encode_branch(self.PC, self.PC + 4 * units, cc=cc, r=r, size=2)
                    hw = struct.unpack('<H', raw)[0]
                    self.assertEqual(form, 'bcc')
                    self.assertEqual(m.short_branch(hw), {'form': 'bcc', 'cc': cc, 'r': r, 'offset': units})

    def test_callr16(self):
        for units in (-512, -1, 0, 1, 511):
            hw = 0x9800 | (units & 0x3ff)
            self.assertEqual(m.short_branch(hw), {'form': 'callr', 'cc': None, 'r': 0, 'offset': units})

    def test_b32_boundaries(self):
        lo, hi = m.B32_UNITS
        for units in (lo, lo + 1, -17, -1, 0, 1, 16, 1000, hi - 1, hi):
            for cc in (0, 1, 14):
                raw, form = m.encode_branch(self.PC, self.PC + 4 * units, cc=cc, size=4)
                first, second = struct.unpack('<HH', raw)
                self.assertEqual(form, 'bcc32')
                self.assertEqual(m.classify(first), 'ext')
                self.assertEqual(m.long_branch(first, second)['offset'], units)
                self.assertEqual(m.long_branch(first, second)['cc'], cc)

    def test_shortest_form(self):
        self.assertEqual(m.encode_branch(self.PC, self.PC + 4 * 511)[1], 'b')
        self.assertEqual(m.encode_branch(self.PC, self.PC + 4 * 512)[1], 'bcc32')
        self.assertEqual(m.encode_branch(self.PC, self.PC + 4 * 15, cc=1)[1], 'bcc')
        self.assertEqual(m.encode_branch(self.PC, self.PC + 4 * 16, cc=1)[1], 'bcc32')

    def test_refusals(self):
        bad = [dict(target=self.PC + 2),                                # not 4-byte aligned
               dict(target=self.PC + 4 * (m.B32_UNITS[1] + 1)),         # past S19
               dict(target=self.PC + 4 * 512, size=2),                  # does not fit 2 bytes
               dict(target=self.PC, cc=16),
               dict(target=self.PC, r=2),
               dict(target=self.PC, size=3)]
        for kw in bad:
            with self.subTest(kw), self.assertRaises(ValueError):
                m.encode_branch(self.PC, **kw)


class Storage(unittest.TestCase):
    BASE = 0x10000000

    def stream(self):
        b32, _ = m.encode_branch(self.BASE + 2, self.BASE + 2 + 4 * 1000, cc=2, size=4)
        # storage +0: MULD (2 bytes); +2: Bcc32 (4); +6: DCACHE (4); +10: B -1 (2)
        return halves(0x6a52) + b32 + halves(0xbd2c, 0x4028) + halves(0x9400 | 0x3ff)

    def test_pc_mapping(self):
        rows = m.decode_storage(self.stream(), base=self.BASE)
        self.assertEqual([r['storage'] - self.BASE for r in rows], [0, 2, 6, 10])
        self.assertEqual([r['pc'] - self.BASE for r in rows], [0, 4, 12, 20])
        self.assertEqual([r['size'] for r in rows], [2, 4, 4, 2])
        self.assertEqual(rows[0]['expanded'], 0x622000a4)
        self.assertEqual(rows[2]['expanded'], 0xad290028)
        # branch targets are PCs: pc + 4 * offset
        self.assertEqual(rows[1]['form'], 'bcc32')
        self.assertEqual(rows[1]['target'], rows[1]['pc'] + 4 * 1000)
        self.assertEqual(rows[3]['target'], rows[3]['pc'] - 4)

    def test_decode_one(self):
        data = self.stream()
        r = m.decode_one(data, self.BASE + 6, self.BASE)
        self.assertEqual((r['pc'], r['expanded']), (self.BASE + 12, 0xad290028))

    def test_truncated_and_trailing(self):
        with self.assertRaises(ValueError):
            m.decode_storage(halves(0xc000), base=self.BASE)       # extended, second half missing
        with self.assertRaises(ValueError):
            m.decode_storage(halves(0x6a52) + b'\x00', base=self.BASE)

    def test_pc_storage_helpers(self):
        for storage in (self.BASE, self.BASE + 2, self.BASE + 0x4e0a):
            pc = m.storage_to_pc(storage, self.BASE)
            self.assertEqual(pc, 2 * storage - self.BASE)
            self.assertEqual(m.pc_to_storage(pc, self.BASE), storage)
        self.assertEqual(m.pc_to_storage(0x80009c14, 0x80000000), 0x80004e0a)
        for bad in (self.BASE - 2, self.BASE + 1):
            with self.assertRaises(ValueError):
                m.pc_to_storage(bad, self.BASE)


class Region(unittest.TestCase):
    """run() on a synthetic region: files, placement, statistics."""
    BASE = 0x20000000
    # MULD; zero; NOP; rejected DCACHE (reserved bit); extended SUB with ext bit 12 (rejected)
    DATA = halves(0x6a52, 0x0000, 0x93fe, 0xbd2c, 0x40a8, 0xd000, 0x1000)

    def run_region(self, objdump=None):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        out = pathlib.Path(tmp.name)
        (out / f'{self.BASE:08x}.bin').write_bytes(self.DATA)
        m.OUT, m.OBJDUMP = out, objdump
        try:
            st = m.run(self.BASE)
        finally:
            m.OUT = m.OBJDUMP = None
        return out, st

    def test_files_and_stats(self):
        out, st = self.run_region()
        rows = json.loads((out / f'{self.BASE:08x}.minim.json').read_text())
        self.assertEqual([r['pc'] for r in rows], [hex(self.BASE + d) for d in (0, 4, 8, 12, 20)])
        self.assertEqual([r['expanded'] is None for r in rows], [False, False, False, True, True])
        exp = (out / f'{self.BASE:08x}.expanded.bin').read_bytes()
        self.assertEqual(len(exp), 2 * len(self.DATA))
        self.assertEqual(struct.unpack_from('<I', exp, 0)[0], 0x622000a4)   # at PC offset 0
        self.assertEqual(struct.unpack_from('<I', exp, 8)[0], 0xa0fffffe)   # at PC offset 8
        self.assertEqual((st['instructions'], st['zero_halfwords'], st['nonzero'], st['unknown']), (5, 1, 4, 2))
        self.assertEqual(st['decoded_nonzero_percent'], 50.0)
        self.assertEqual(st, json.loads((out / f'{self.BASE:08x}.minim-stats.json').read_text()))
        reasons = st['unknown_by_reason']
        self.assertEqual(sum(reasons.values()), 2)
        self.assertTrue(any(k.startswith('long sub 0xd') for k in reasons))
        self.assertTrue(any(k.startswith('extended SUB, conditional form') for k in reasons))

    @unittest.skipUnless(os.environ.get('METAG_OBJDUMP'), 'set METAG_OBJDUMP to run objdump')
    def test_objdump(self):
        objdump = os.environ['METAG_OBJDUMP']
        cmd = lambda name, base: [objdump, '-D', '-z', '-b', 'binary', '-m', 'metag',
                                  f'--adjust-vma={base}', str(m.OUT / name)]
        out, _ = self.run_region(cmd)
        lines = (out / f'{self.BASE:08x}.minim.dis').read_text().splitlines()
        self.assertEqual(len(lines), 5)
        self.assertFalse(any(line.endswith(': ?') for line in lines))
        self.assertIn('MULD', lines[0])
        self.assertIn('0x0000 halfword', lines[1])
        self.assertIn('NOP', lines[2])
        self.assertTrue(lines[3].endswith('UNKNOWN') and lines[4].endswith('UNKNOWN'))


if __name__ == '__main__':
    unittest.main()
