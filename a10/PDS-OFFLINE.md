# Offline PDS investigation and hardware follow-up 50–61

Updated 2026-10-29. The original investigation below was offline, while the device
was unavailable. **It subsequently returned in DFU; probes 50–61 have now run.**
50–52 all stall with verified matching payloads. 53's store marker is unchanged;
54's unguarded store produces no expected write fault. PDS branch target fetch is
shown by 55, but PDS retirement and the DOUTU→USC path are not established
(56–61), and no PDS/USC dispatch or shader result completes. Baseline 46 passes
before and after these tests; the device was left in that working state on
`/dev/cu.usbmodem1301`. Full records, geometry, clock diagnostics and
rebuilt-module details: [COMPUTE.md](COMPUTE.md).

## What the reference comparison establishes

Reference: Mesa mirror commit `1c3a936490f9f0951188218e136cd03bca497386`, locally
under `out/reference/mesa`. No Mesa source was modified or submitted upstream.
This is standalone experiment tooling, not a Mesa driver/compiler contribution.

There are concrete mismatches between the earlier probes and Mesa's task setup:

| Earlier probe | Source evidence | Consequence / limitation |
|---|---|---|
| 47: PDS data size = 0 | `pvr_pds_compute_shader`, near the end of the function: “Require at least one DWORD of PDS data so the program runs.” The CDM allocation rounds bytes up to 16-byte chunks. | A zero-data HALT probe is not a valid reference-matching empty PDS task. This is a definite setup mismatch, not a proven explanation of all stalls. |
| 48: DOUTC without fence bit | `pvr_arch_compute_generate_fence`, `pvr_arch_cmd_buffer.c:2289`: `.is_fence = true`, `.sd_type = PDS`, target ANY. | 48's KERNEL0 = 6 misses fence bit 0; KERNEL1 = 0x100 misses PDS dependency bits 3:2 = 1. |
| 48: DOUTC/HALT only | Device compute fence setup uses `pvr_pds_compute_shader` with `.fence = true`, `.clear_pds_barrier = true`, and no USC kick. | The normal compute-fence program is not the short `pvr_pds_generate_doutc` helper used for the old candidate. It handles task type and resets a persistent barrier register first. |
| 47/48: `one_wg_per_task = 1`, max instances = 1 | The normal direct-kernel emitter leaves `one_wg_per_task` unset; for this zero-coefficient, one-item reference case the flat-slot calculation gives max instances 8. | Not established as invalid on G9P, but unnecessary differences from the reference. New candidates use the reference shape. |
| 47: global counts = 1 | Emitter subtracts 1 from global group counts as well as local sizes. | It requested 2×2×2 groups. 48 already corrected this to 1×1×1. |

**The original instruction constants are not a generic Rogue packing error.**
Using the unmodified reference C encoder and disassembler verifies:

| Word | Reference decoding |
|---|---|
| `0xc2c00002` | BRA if !IF1, KEEP predicate, relative +2 |
| `0xd3000000` | HALT |
| `0x80000010` | ADD64 ptemp[0].64 = const[0].64 + const[0].64 |
| `0xf0000005` | DOUTC from const[0].64 / const[0].32 |

That agreement does **not** establish that this G9P implements the same PDS ISA
or feature profile. The old valid-code probes did not complete; this is still an
open hardware question.

## Reference call paths and task behavior

Normal compute fence:

1. `pvr_arch_device.c`, `pvr_device_init_compute_fence_program`: initializes the
   program with fence and clear-barrier enabled; USC kick remains false.
2. `pvr_arch_pds_compute_shader_create_and_upload` calls
   `pvr_pds_compute_shader` for sizes, data and code.
3. `pvr_arch_cmd_buffer.c`, `pvr_arch_compute_generate_fence`: submits it with
   fence bit, PDS sequential dependency, ANY target and one work item.

For a minimal program with no input-register transfers, the resulting control
flow is:

```text
0: BRA !IF1, KEEP, +2
1: HALT                         # coefficient-update task path
2: ADD64 ptemp64[0] = 0 + 0      # regular task: reset persistent barrier
3: DOUTC                        # fence profile only
4: HALT
```

The empty profile omits DOUTC and has four instructions. The short-fence profile
contains only DOUTC/HALT; it is a comparison candidate, not the normal generated
compute-fence program. Its success/failure relative to the full program may help
isolate the task guard/barrier reset, subject to cache/feature differences.

The host tests symbolically check these two IF1 control-flow paths. That narrow
check is **not a PDS or GPU emulator**.

The reference includes a no-USC empty PDS program, so it is **not justified to
conclude that every completed PDS dispatch necessarily needs a USC task**. The
A10-specific behavior remains untested.

## Original candidate plans: now tested, all incomplete

`tools/pds_probe.py` produces both inspectable JSON plans and deterministic hooks.
All source **working baseline 46**, not failed/fault-injecting hooks 47–49. GPU
VA 0 stays unmapped. The stream remains at GPU VA 0x200000; Q scratch/fence stays
at 0x203000; no USC task/DOUTU is emitted.

| Candidate | Purpose | PDS code/data offsets | CDM KERNEL0 / KERNEL1 / KERNEL2 |
|---|---|---|---|
| `agx-init50.sh` / `fence` | Full reference-shaped fence | 0x1000 / 0x800 | 0x7 / 0x804 / 0x1000 |
| `agx-init51.sh` / `empty` | Reference-shaped empty/shared-allocation task, zero requested shared storage | 0x2000 / 0xa00 | 0x4 / 0xa02 / 0x2000 |
| `agx-init52.sh` / `short-fence` | Short old DOUTC/HALT with corrected fence/dependency fields | 0x3000 / 0xe00 | 0x7 / 0xe04 / 0x3000 |

All three use encoded group counts 0/0/0 and KERNEL8 = 0x40000000: one local
work item, max-instance cap 8. They end with Rogue terminate 0x80000000.
PDS data allocation is one 16-byte chunk with explicit zero constants.

PDS heap base is GPU VA 0x300000000, backed by the existing owned scratch page
at scratch PA+0x84000. Programs/constants remain inside this read-only,
SLC-bypass 16 KiB GPU mapping; no new physical range is exposed. Code offsets
use distinct 4 KiB subpages, unlike repeatedly reused old offset 0. This reduces
a potential stale instruction-cache confound but **does not prove coherency or
replace a validated cache invalidation sequence**. Power-state cycling must not
be assumed to invalidate every instruction cache without evidence.

## Offline tooling and checks

Run from `examples/gpu-001` (in the orchard checkout):

```sh
python3 tools/pds_probe.py plan fence
python3 tools/pds_probe.py hook fence
python3 tools/check_pds_reference.py
python3 -m unittest discover -s tools -p 'test_*.py' -v
```

The reference check:

- Requires the pinned, unmodified local Mesa reference and a C compiler; no
  downloads, serial ports, USB access or target execution.
- Compiles the original C inline encoders, original disassembler and printer in
  a temporary directory. Small shims supply only inline/bit/logging macros.
- Confirms Python instruction words agree with those C encoders and disassemble
  as intended. It does not compile the full driver or full compute generator.
- Independently packs the CDM packets from the actual `cdm.xml` field definitions
  and compares all three candidate packets with the Python output.
- Leaves the reference checkout unchanged. Result:
  `out/resume/offline-pds-reference.json` (local, ignored).

**27 host tests pass:** the previous 14 plus 13 PDS plan/packing/safety/control-flow
and reference-comparison tests. The C and XML reference tests are skipped if their
local dependencies are missing; neither was skipped in this session. All shell
hooks pass host syntax checks. These are offline results only.

## Original device-session plan (50–52 now executed without completion)

1. Inspect actual boot mode and USB port; restore the RAM environment and matching
   module/hooks if `/run` was lost. First rerun 46 and verify the known baseline.
2. Stage the new candidate hooks, then try **50 first**. Capture full 64-bit MMU
   fault, both stamps, queue/IP, shared unit state, host event producer, SKU trace,
   and actual code/data/stream bytes. A timeout with no fault is still a failure.
3. Use 51 and 52 as comparisons, inspecting outcomes before choosing the next
   run. Keep the 46 baseline intact; do not call a new candidate a fix until tested.
4. The existing `gpu_evidence.py validate` can check the carrier command's
   recorded completion path. It does not prove which PDS bytes executed or a
   shader-written result; preserve matching payload captures and controls too.
5. Only after a non-empty PDS dispatch is proven, construct a real minimal USC
   shader and verify a known memory result. Do **not** issue DOUTU to offset 0:
   the mapped page contains PDS instructions, not a validated USC program.

## Hardware follow-up and current interpretation

The above test order was executed after the user returned the device. All three
probes **50–52** return 2, with zero stamps/event producer, no fault/crash, and a
trace stopping after StartCompute. SHA-256-verified payload captures match the
plans exactly. Thus the source-identified setup mismatches were real differences,
but correcting them did **not** resolve the stall.

53 uses a fresh mapped PDS page and an owned writable output page. Generic Rogue
LIMM/ST/WDF should change an initialized 0xabadbeef sentinel to 0x1357; it does not.
54 removes the guard and aims ST at unmapped VA 0x400000; the expected write fault
also does not occur. These results do not prove whether code is skipped, the ISA
or descriptor is unsuitable, unit/task initialization is missing, or visibility
is wrong. The C reference now additionally verifies LIMM 0xd1804d5c, ST 0xd0800000
and WDF 0xd1000000; that remains a generic-reference check, not an A10 proof.

Live post-stall forcing of the PDS clock alone, then selected PDS/USC/MCU/CDM/BIF
clock fields, did not produce a marker, completion or write fault. Original
CLK_CTRL 0xa02a82000a2a2a0a was restored and independently read back. This does not
rule out every startup/enable/cache dependency. No permanent clock change was
added to a hook.

`pds_probe.py` and generated hook comments now mark 50–52 **hardware tested,
not completed**, rather than untested. Frozen `offline-pds-reference.json` is the
historical pre-device report; current reference output is
`out/resume/pds50-54-encoder-reference.json`. Payload/baseline checks are recorded
in `out/resume/pds50-54-observations.json`. 27 host tests still pass.

Next investigation: G9P-specific PDS ISA/task/feature initialization or native
instruction-progress evidence, not another assumption that generic HALT is enough.
Do not issue a USC task to an unvalidated code address. No shader compatibility,
rendering support, or full acceleration is established by these failed probes.
