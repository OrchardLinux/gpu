from pathlib import Path
import shutil
import unittest

from check_pds_reference import check_cdm_xml, check_reference
from pds_probe import (CLEAR_BARRIER, DOUTC, HALT, SKIP_COEFFICIENT_TASK,
                       kernel_words, pds_bytes, probe_plan, render_hook)


BASE = Path(__file__).resolve().parent.parent
MESA = BASE / "out/reference/mesa"


class PDSProbeTests(unittest.TestCase):
    def test_fence_packet_golden(self):
        self.assertEqual(probe_plan("fence")["cdm_words"],
                         [7, 0x804, 0x1000, 0, 0, 0, 0x40000000, 0x80000000])

    def test_empty_packet_golden(self):
        self.assertEqual(probe_plan("empty")["cdm_words"],
                         [4, 0xa02, 0x2000, 0, 0, 0, 0x40000000, 0x80000000])

    def test_dimensions_are_minus_one(self):
        words = kernel_words(code_offset=0x100, data_offset=0x200,
                             groups=(2, 3, 4), local=(2, 3, 4))
        self.assertEqual(words[3:6], [1, 2, 3])
        self.assertEqual(words[6] & 0x7ffffff, 1 << 18 | 2 << 9 | 3)

    def test_alignment(self):
        for code, data in [(1, 16), (16, 1), (-16, 16)]:
            with self.subTest(code=code, data=data), self.assertRaises(ValueError):
                kernel_words(code_offset=code, data_offset=data)

    def test_reject_bad_ranges(self):
        cases = [dict(code_offset=1 << 32), dict(data_chunks=64),
                 dict(max_instances=33), dict(max_instances=0),
                 dict(groups=(0, 1, 1)), dict(groups=(1, 1)),
                 dict(local=(1, 513, 1)), dict(dependency="unknown"),
                 dict(target="unknown")]
        for changes in cases:
            args = dict(code_offset=0x100, data_offset=0x200)
            args.update(changes)
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                kernel_words(**args)

    def test_minimum_pds_data(self):
        with self.assertRaisesRegex(ValueError, "program runs"):
            kernel_words(code_offset=0, data_offset=0x100, data_chunks=0)

    def test_full_instance_slot_encodes_zero(self):
        words = kernel_words(code_offset=0, data_offset=0x100, max_instances=32)
        self.assertEqual(words[6] >> 27, 0)

    def test_instruction_golden_and_little_endian(self):
        self.assertEqual(probe_plan("fence")["pds_words"],
                         [0xc2c00002, 0xd3000000, 0x80000010, 0xf0000005, 0xd3000000])
        self.assertEqual(pds_bytes("short-fence"), bytes.fromhex("050000f0 000000d3"))

    def test_safety_scope_and_fresh_offsets(self):
        seen = set()
        for name in ("fence", "empty", "short-fence"):
            p = probe_plan(name)
            self.assertTrue(p["hardware_tested"])
            self.assertFalse(p["hardware_completed"])
            self.assertIn("NO USC", p["scope"])
            self.assertNotIn(p["code_offset"], seen)
            seen.add(p["code_offset"])
            self.assertEqual(p["code_offset"] % 4096, 0)
            self.assertLessEqual(p["code_offset"] + len(pds_bytes(name)) + 64, 0x4000)
            self.assertTrue(0x84000 <= p["data_scratch_offset"] < 0x88000)
            # No DOUTU instruction: no accidental USC task/code-address zero.
            self.assertFalse(any(w >> 28 == 15 and w & 7 == 2 for w in p["pds_words"]))

    def test_generated_hooks_match_and_preserve_baseline(self):
        for name in ("fence", "empty", "short-fence"):
            p = probe_plan(name)
            hook = render_hook(name)
            self.assertEqual((BASE / f"tools/agx-init{p['candidate_hook']}.sh").read_text(), hook)
            self.assertIn("TESTED: incomplete", hook)
            self.assertIn(". /run/agx-init46.sh", hook)
            self.assertNotIn("agx-init49.sh", hook)

    def test_task_guard_paths_symbolically(self):
        # A narrow control-flow check, NOT an ISA/GPU emulator. The generic
        # reference's IF1 task must halt without clearing the barrier or DOUTC.
        for name in ("fence", "empty"):
            words = probe_plan(name)["pds_words"]
            for if1 in (False, True):
                pc, actions = 0, []
                for _ in range(10):
                    word = words[pc]
                    if word == SKIP_COEFFICIENT_TASK:
                        pc += 1 if if1 else 2
                    elif word == HALT:
                        break
                    else:
                        self.assertIn(word, (CLEAR_BARRIER, DOUTC))
                        actions.append(word)
                        pc += 1
                else:
                    self.fail("candidate did not reach HALT")
                self.assertEqual(actions, [] if if1 else
                                 [CLEAR_BARRIER] + ([DOUTC] if name == "fence" else []))

    @unittest.skipUnless((MESA / "src/imagination/csbgen/rogue/cdm.xml").is_file(),
                         "local Mesa reference checkout unavailable")
    def test_independent_xml_packet_encoding(self):
        self.assertEqual(check_cdm_xml(MESA), ["fence", "empty", "short-fence"])

    @unittest.skipUnless((MESA / "src/imagination/vulkan/pds/pvr_rogue_pds_encode.h").is_file()
                         and shutil.which("cc"), "local Mesa reference/C compiler unavailable")
    def test_unmodified_c_encoder_and_disassembler(self):
        result = check_reference(MESA)
        self.assertEqual([v["word"] for v in result["instructions"]],
                         [SKIP_COEFFICIENT_TASK, HALT, CLEAR_BARRIER, DOUTC,
                          0xd1804d5c, 0xd0800000, 0xd1000000])
        self.assertIn("ptemp[0]", result["instructions"][2]["instruction"])
        self.assertIn("doutc", result["instructions"][3]["instruction"])


if __name__ == "__main__":
    unittest.main()
