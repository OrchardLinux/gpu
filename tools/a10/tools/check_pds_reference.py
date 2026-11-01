#!/usr/bin/env python3
"""Compare offline candidate words with unmodified, local Mesa C encoders.

Compile a temporary header/disassembler harness, not Mesa's full driver or its
full compute-program generator. Tiny shims supply inline/logging macros only;
instruction definitions, packing and disassembly are from the reference checkout.
No network, device, or reference source modification. Requires a C compiler.
"""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

from pds_probe import CLEAR_BARRIER, DOUTC, HALT, MESA_COMMIT, SKIP_COEFFICIENT_TASK, probe_plan


SOURCE = r'''
#include <stdio.h>
#include <stdlib.h>
#include "pvr_rogue_pds_encode.h"
static void error(struct pvr_dissassembler_error e) {
    fprintf(stderr, "reference decode error: %s\n", e.text);
    exit(2);
}
int main(void) {
    uint32_t words[] = {
        pvr_pds_inst_encode_bra(PVR_ROGUE_PDSINST_PREDICATE_IF1, 1,
                               PVR_ROGUE_PDSINST_PREDICATE_KEEP, 2),
        pvr_pds_inst_encode_halt(0),
        pvr_pds_inst_encode_add64(0, PVR_ROGUE_PDSINST_ALUM_UNSIGNED,
            PVR_ROGUE_PDSINST_MAD_SNA_ADD, 0, 0,
            PVR_ROGUE_PDSINST_REGS64TP_PTEMP64_LOWER),
        pvr_pds_inst_encode_dout(0, 0, 0, 0, PVR_ROGUE_PDSINST_DSTDOUT_DOUTC),
        pvr_pds_inst_encode_limm(0, 0, 0x1357, 0),
        pvr_pds_inst_encode_st(0, 0),
        pvr_pds_inst_encode_wdf(0),
    };
    for (unsigned i = 0; i < sizeof(words) / sizeof(words[0]); ++i) {
        char text[512] = {0};
        struct pvr_instruction *inst = pvr_pds_disassemble_instruction2(NULL, error, words[i]);
        if (!inst) return 3;
        pvr_pds_disassemble_instruction(text, sizeof(text), inst);
        printf("%08x\t%s\n", words[i], text);
        pvr_pds_free_instruction(inst);
    }
    return 0;
}
'''


def check_cdm_xml(mesa):
    """Independently pack candidate packets from the local Rogue XML fields."""
    root = ET.parse(Path(mesa) / "src/imagination/csbgen/rogue/cdm.xml").getroot()
    enums = {e.attrib["name"]: {v.attrib["name"]: int(v.attrib["value"], 0)
                              for v in e.findall("value")} for e in root.findall("enum")}
    structs = {s.attrib["name"]: s for s in root.findall("struct")}

    def pack(name, values):
        result = 0
        for field in structs[name].findall("field"):
            a = field.attrib
            value = values.get(a["name"], a.get("default", 0))
            if isinstance(value, str):
                value = enums[a["type"]][value]
            shift = int(a.get("shift", "0"))
            if value & ((1 << shift) - 1):
                raise ValueError(f"unaligned XML address in {name}.{a['name']}")
            value >>= shift
            start, end = int(a["start"]), int(a["end"])
            if not 0 <= value < 1 << (end - start + 1):
                raise ValueError(f"value outside XML field {name}.{a['name']}")
            result |= value << start
        return result

    checked = []
    for name in ("fence", "empty", "short-fence"):
        p = probe_plan(name)
        f = p["flags"]
        words = [
            pack("KERNEL0", {"pds_data_size": 1, "usc_target": f["target"].upper(),
                             "fence": f.get("fence", False)}),
            pack("KERNEL1", {"data_addr": p["data_offset"],
                             "sd_type": f["dependency"].upper(),
                             "usc_common_shared": f.get("shared", False)}),
            pack("KERNEL2", {"code_addr": p["code_offset"]}),
            pack("KERNEL3", {"workgroup_x": 0}),
            pack("KERNEL4", {"workgroup_y": 0}),
            pack("KERNEL5", {"workgroup_z": 0}),
            pack("KERNEL8", {"max_instances": 8}),
            pack("STREAM_TERMINATE", {}),
        ]
        if words != p["cdm_words"]:
            raise ValueError(f"candidate {name} disagrees with Mesa CDM XML")
        checked.append(name)
    return checked


def check_reference(mesa, compiler="cc"):
    mesa = Path(mesa).resolve()
    head = subprocess.run(["git", "-C", str(mesa), "rev-parse", "HEAD"],
                          check=True, capture_output=True, text=True).stdout.strip()
    if head != MESA_COMMIT:
        raise ValueError(f"reference checkout must be pinned at {MESA_COMMIT}, got {head}")
    subprocess.run(["git", "-C", str(mesa), "diff", "--quiet", "HEAD", "--",
                    "src/imagination/vulkan/pds", "src/imagination/csbgen/rogue/cdm.xml",
                    "src/imagination/vulkan/pvr_arch_cmd_buffer.c",
                    "src/imagination/vulkan/pvr_arch_device.c",
                    "src/imagination/include/hwdef/rogue_hw_defs.h"],
                   check=True, capture_output=True, timeout=15)
    xml_checked = check_cdm_xml(mesa)
    pds = mesa / "src/imagination/vulkan/pds"
    for name in ("pvr_rogue_pds_encode.h", "pvr_rogue_pds_defs.h",
                 "pvr_pds_disasm.c", "pvr_pds_printer.c"):
        if not (pds / name).is_file():
            raise ValueError(f"missing local reference file {pds / name}")
    cc = shutil.which(compiler)
    if not cc:
        raise ValueError(f"C compiler not found: {compiler}")
    with tempfile.TemporaryDirectory(prefix="gpu-pds-reference-") as tmp:
        root = Path(tmp)
        (root / "util").mkdir()
        (root / "util/macros.h").write_text(
            "#define ALWAYS_INLINE inline __attribute__((always_inline))\n"
            "#define BITFIELD_BIT(b) (UINT32_C(1) << (b))\n")
        (root / "util/log.h").write_text("/* Logging unused: DUMP_PDS is disabled. */\n")
        (root / "check.c").write_text(SOURCE)
        subprocess.run([cc, "-std=c11", "-O2", "-I", str(root), "-I", str(pds),
                        str(root / "check.c"), str(pds / "pvr_pds_disasm.c"),
                        str(pds / "pvr_pds_printer.c"), "-o", str(root / "check")],
                       check=True, capture_output=True, text=True, timeout=60)
        result = subprocess.run([str(root / "check")], check=True, capture_output=True,
                                text=True, timeout=10)
    decoded = []
    for line in result.stdout.splitlines():
        word, _, instruction = line.partition("\t")
        decoded.append({"word": int(word, 16), "instruction": instruction})
    expected = [SKIP_COEFFICIENT_TASK, HALT, CLEAR_BARRIER, DOUTC,
                0xd1804d5c, 0xd0800000, 0xd1000000]
    if [d["word"] for d in decoded] != expected:
        raise ValueError("Python candidates disagree with Mesa C encoder output")
    return {
        "scope": "offline reference encoder/disassembler comparison; NOT hardware validation",
        "reference_head": head,
        "cdm_xml_checked": xml_checked,
        "instructions": decoded,
        "candidate_profiles": [probe_plan(n) for n in ("fence", "empty", "short-fence")],
    }


def main():
    default = Path(__file__).resolve().parent.parent / "out/reference/mesa"
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mesa", type=Path, default=default)
    parser.add_argument("--cc", default="cc")
    args = parser.parse_args()
    try:
        result = check_reference(args.mesa, args.cc)
    except (OSError, ValueError, subprocess.SubprocessError) as e:
        detail = getattr(e, "stderr", None) or str(e)
        parser.exit(1, f"FAIL: {detail}\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
