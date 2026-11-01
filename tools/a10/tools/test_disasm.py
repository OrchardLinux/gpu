"""Offline tests: python3 -m unittest discover -s tools -p 'test_*.py'."""
import struct
import unittest

from disasm import macho_segments


class MachOSegmentsTests(unittest.TestCase):
    @staticmethod
    def thin():
        header = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 1, 72, 0, 0)
        segment = struct.pack('<II16sQQQQIIII', 0x19, 72, b'__TEXT_EXEC',
                              0x100000, 0x1000, 104, 4, 5, 5, 0, 0)
        return header + segment + b'CODE'

    def test_thin(self):
        data, segments = macho_segments(self.thin())
        self.assertEqual(segments, [('__TEXT_EXEC', 0x100000, 104, 4)])
        self.assertEqual(data[104:108], b'CODE')

    def test_fat_offsets_are_slice_relative(self):
        thin = self.thin()
        fat = struct.pack('>7I', 0xcafebabe, 1, 0x100000c, 0, 28, len(thin), 2)
        data, segments = macho_segments(fat + thin)
        self.assertEqual(data, thin)
        self.assertEqual(data[segments[0][2]:], b'CODE')

    def test_reject_non_macho(self):
        with self.assertRaises(ValueError):
            macho_segments(b'not a kernelcache')

    def test_reject_bad_load_command(self):
        data = bytearray(self.thin())
        struct.pack_into('<I', data, 36, 0)
        with self.assertRaises(ValueError):
            macho_segments(data)


if __name__ == '__main__':
    unittest.main()
