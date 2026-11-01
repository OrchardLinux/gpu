import struct
import unittest

from gpu_evidence import check_trace, decode_fault, read_trace, validate


def record(event, args=(0, 0, 0, 0), timestamp=1):
    return struct.pack("<9I", 5, timestamp, 0, *args, event, 0)


def capture(rows):
    return b"".join(rows).ljust(512 * 36, b"\0")


def good_capture():
    return capture([
        record(7, timestamp=1),
        record(0x102, (3, 0x80000000, 4, 0), 2),
        record(8, timestamp=3),
        record(0x103, (3, 0x80000000, 0, 0), 4),
        record(0x100000e, (1, 0, 0, 0), 5),
    ])


def good_log():
    queue = bytearray(44)
    struct.pack_into("<I", queue, 0, 3)
    struct.pack_into("<I", queue, 28, 0x144080)
    rows = []
    for offset in range(0, len(queue), 16):
        rows.append(f"{offset:08x}  {queue[offset:offset + 16].hex(' ')}  |fixture|")
    return "\n".join([
        "MODE=real, completion stamps:",
        "00000000  01 00 00 00 01 00 00 00  |fixture|",
        "00000008",
        "Compute scheduling entry:", *rows,
        "0000002c",
        "0 /sys/kernel/debug/apple_gpu_iop/crashlog",
        "RUN_EXIT=0",
        "0x0000000000000000",
    ])


class EvidenceTests(unittest.TestCase):
    def test_controlled_faults(self):
        cases = [
            (0x119, "0x0", 4, 1, "read"),
            (0x0000400000000119, "0x400000", 4, 1, "read"),
            (0x0300000000003229, "0x300000000", 8, 2, "read"),
            (0xff251, "0x0", 9, 1, "write"),
            (0x0300400000000299, "0x300400000", 10, 1, "read"),
        ]
        for value, address, req, level, access in cases:
            with self.subTest(value=hex(value)):
                d = decode_fault(value)
                self.assertTrue(d["valid"])
                self.assertEqual((d["address"], d["requestor"], d["level"], d["access"]),
                                 (address, req, level, access))

    def test_fault_range_and_zero(self):
        self.assertFalse(decode_fault(0)["valid"])
        for value in (-1, 1 << 64):
            with self.assertRaises(ValueError):
                decode_fault(value)

    def test_ordered_hardware_trace(self):
        self.assertEqual(check_trace(read_trace(good_capture()))["finalize"], 2)

    def test_cpu_cancellation_is_not_hardware_completion(self):
        data = capture([record(8), record(0x100000e, (1, 0, 0, 0), 2)])
        with self.assertRaisesRegex(ValueError, "start"):
            check_trace(read_trace(data))

    def test_initial_irq_is_not_compute_finished(self):
        data = capture([record(7), record(0x102, (3, 8, 0xffffffff, 0), 2)])
        with self.assertRaisesRegex(ValueError, "compute_irq"):
            check_trace(read_trace(data))

    def test_finalize_cannot_precede_irq(self):
        rows = [record(7), record(8, timestamp=2),
                record(0x102, (3, 0x80000000, 4, 0), 3)]
        with self.assertRaisesRegex(ValueError, "finalize"):
            check_trace(read_trace(capture(rows)))

    def test_truncated_gapped_and_full_rings(self):
        for data in [b"", b"\0" * 36 + good_capture()[:-36],
                     record(7) * 512]:
            with self.subTest(size=len(data)), self.assertRaises(ValueError):
                read_trace(data)

    def test_backwards_timestamps(self):
        with self.assertRaisesRegex(ValueError, "chronological"):
            read_trace(capture([record(7, timestamp=2), record(8)]))

    def test_validate_good_capture(self):
        result = validate(good_log().replace("\n", "\r\n"), good_capture())
        self.assertEqual(result["stamps"], [1, 1])
        self.assertIn("NOT USC", result["scope"])

    def test_reject_incomplete_faulted_and_duplicate_logs(self):
        for old, new in [
            ("RUN_EXIT=0", "RUN_EXIT=2"),
            ("RUN_EXIT=0", "RUN_EXIT=0\nRUN_EXIT=0"),
            ("0x0000000000000000", "0x0300400000000299"),
            ("01 00 00 00 01 00 00 00", "00 00 00 00 00 00 00 00"),
            ("00000000  03 00", "00000000  02 00"),
            ("0 /sys/kernel/debug", "1 /sys/kernel/debug"),
        ]:
            with self.subTest(replacement=new), self.assertRaises(ValueError):
                validate(good_log().replace(old, new), good_capture())


if __name__ == "__main__":
    unittest.main()
