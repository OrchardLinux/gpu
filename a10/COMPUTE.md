# Compute submission bring-up — experiments 16–69

Last updated: 2026-10-29, after hardware experiments **50–61**, clock diagnostics,
and a successful final repeat of baseline **46**. This is the current handoff.
The earlier offline findings and their hardware follow-up are also recorded in
[PDS-OFFLINE.md](PDS-OFFLINE.md). [README.md](FIRST-LOOK.md) summarizes status;
[FENDER.md](FENDER.md) retains the earlier power/firmware analysis.

## Current result and blocker

**A native compute shader writes a buffer on the A10 under Linux (experiment
68, binding control 69).** The `store_marker` kernel compiled by Apple's
`metal-tt` for `applegpu_g9p` runs from a hand-built CDM stream and writes
`0x1357` to the bound buffer. The stream reproduces iPadOS's exact records: a
DMA task that loads the buffer binding, then the kernel. Moving the binding
moves the write. No rendering, DRM driver, compiler of our own or accelerated
desktop yet.

Confirmed on the attached J71b:

- Real core power-up, identity reads, and fixed firmware register initialization.
- Control-ring consumption and runtime **ARM coprocessor** VA mappings.
- A compute work descriptor reaches the queue parser, engine scheduler and SKU
  (microsequence) interpreter.
- A **CPU-side cancellation/finalize/end** sequence completes: both stamps become
  1, the host event-ring producer becomes 1, and there is no firmware crash.
  This is experiment 25, not GPU computation.
- **Experiment 46 completes a real terminate-only stream:** compute-finished IRQ
  observed in the firmware trace, FinalizeCompute executes its normal cache-flush
  path, both stamps become 1, queue state becomes 3, host event producer becomes
  1, MMU fault stays 0, firmware crashlog stays empty. This is NOT cancellation.
- Fault injection identifies the actual stream register as **RGX+0x480**, not
  +0x498. The original 0x119 fault was a read at GPU VA 0, where the wrong register
  setup had left the stream. The host-supplied GPU tables now work for this probe.
- A second fault in finalization was caused by missing **Q[0:8]**, copied by
  firmware to RGX+0xe240. Setting this GPU scratch/fence address to mapped VA
  0x203000 fixes it, without mapping GPU VA 0.
- PDS-only kernel probes **50–52** have now been tested: all stall at the IRQ
  wait, stamps/event producer stay zero, no MMU fault or firmware crash. Captured
  stream/program/constants exactly match the reference-checked offline plans.
- Probe **53** attempts an observable PDS-only store to owned memory. Its output
  stays at CPU sentinel 0xabadbeef, not expected marker 0x1357. Probe **54** removes
  the predicate guard and deliberately targets an unmapped address; no expected
  write fault appears. Neither produces an observable result or fault.
- **Experiment 55** separates PDS fetch from completion. A two-way branch at the
  end of the mapped PDS code page (offset 0x3f00) targets unmapped 0x300004000.
  The MMU fault is a read at exactly 0x300004000, requestor 10 (PDS), status
  0x0300004000000289. **Experiment 56** repeats the branch but targets a mapped
  HALT at 0x3f0c: no fault and no completion. The branch target is therefore
  fetched/decoded; PDS instruction retirement is still unproven. **Experiment
  57** forced PDS-related clock fields before the kick; CLK_STATUS stayed 0x200
  and the task still did not complete.
- **Experiments 58–61** tried to kick USC. 58 used a mapped 4-byte PCO control
  NOP with END; 59/60 pointed DOUTU at unmapped 0x300004000 with cc/end and
  sd_type variants; 61 forced PDS and USC clocks before the kick. None faulted,
  completed, or crashed. CLK_STATUS reached 0x600 (USC running) but PDS bit 6
  stayed 0. DOUTU execution and USC code fetch are not established.
- An earlier intentionally unmapped code offset (49) still establishes PDS code
  fetch at **0x300400000**. Code fetch (49), branch target fetch (55), and kernel
  completion (still absent) are separate milestones. No USC shader has been
  launched successfully.

The next blocker is **PDS execution/retirement and a working DOUTU→USC kick**,
not another PDS HALT. 58–61 do not produce an observable USC fetch, and the PDS
clock stays gated. Preserve 46 as the working baseline; 49 is an intentionally
faulting negative control, not its replacement. Linux/USB remain responsive.
The user returned the iPad in DFU and authorized this device session. Linux/USB
are available again, on **/dev/cu.usbmodem1301**. The device was restored to the
successfully repeated **46** state after all probes; temporary clock changes were
restored and read back. Do not leave it in a stalled exploratory dispatch.

## Reproduce and capture

Run host commands from `examples/gpu-001` (in the orchard checkout). The current USB port
is **`/dev/cu.usbmodem1301`** after the latest DFU reboot (previously 21301 and
21201); inspect the host before assuming it is unchanged. The existing RAM payload
booted successfully, Linux readiness was verified, and no device storage is
mounted. `/run/apple_gpu_iop.ko` and hooks 12–54 are staged. A new boot loses
`/run`: restage the matching module and scripts before testing.

All later `agx-initN.sh` files are **BEFORE_INIT hooks**, not standalone initializers.
They source earlier hooks. Stage the whole chain, not just the highest number:

```sh
PORT=/dev/cu.usbmodem1301
for n in $(seq 12 54); do
    python3 tools/serial_put.py "$PORT" "tools/agx-init$n.sh" "/run/agx-init$n.sh"
done
for s in fender-power-on.sh compute-probe.sh compute-run.sh; do
    python3 tools/serial_put.py "$PORT" "tools/$s" "/run/$s"
done
```

Device commands through the serial helper:

```sh
# CPU-side cancellation/completion test; RGX registers are RAM-backed.
python3 tools/serial_cmd.py "$PORT" \
  'HOOK=/run/agx-init25.sh sh /run/compute-probe.sh' 8 45

# Working real-GPU baseline: terminate-only, expected RUN_EXIT=0.
python3 tools/serial_cmd.py "$PORT" \
  'MODE=real HOOK=/run/agx-init46.sh sh /run/compute-run.sh; echo RUN_EXIT=$?; devmem 0x20100e150 64; dd if=/sys/kernel/debug/apple_gpu_iop/scratch bs=1 skip=$((0x57020)) count=4 2>/dev/null | hexdump -C' 8 45

# Exploratory PDS dispatch: currently EXPECTED TO FAIL/return 2.
python3 tools/serial_cmd.py "$PORT" \
  'MODE=real HOOK=/run/agx-init48.sh sh /run/compute-run.sh; echo RUN_EXIT=$?' 8 45
```

`compute-probe.sh` always forces RAM RGX and emulates three fixed-init polling
bits **in RAM**. `compute-run.sh` defaults to RAM; `MODE=real` explicitly enables
real register writes and GPU DMA. It never emulates hardware completion in real
mode. Its real-mode completion gate checks a host stamp, so future successful
runs must also verify GPU results, fault state, and lack of a cancellation path;
a stamp alone is not sufficient evidence of acceleration. The recorded "Unit
state" dump reads the historical private page at scratch+0x56000; current shared
unit state is scratch+0x1e000. An offline label-only change now calls this the
"Legacy/private unit shadow". Do not interpret those private-page zeros as the
current hardware unit's status. The label-only change is now exercised in the
latest session; the underlying private dump remains unsuitable as unit evidence.

The independent earlier bring-up smoke is `sh /run/agx-smoke.sh`. It does not
enqueue a compute job. Do not confuse its PASS with the real compute probe.

Use an idle timeout of at least 8 seconds, longer than the initialization wait.
Save host captures before reboot: `/run` disappears on every boot.

```sh
python3 tools/crashregs.py "$PORT" out/resume/new-crash.bin
python3 tools/serial_get.py "$PORT" /run/compute-registers.bin out/resume/registers.bin
```

`serial_get.py` verifies the device SHA-256 before writing its output. Its remote
path must exist: `compute-registers.bin` is saved by `compute-probe.sh`, not by
`compute-run.sh`. For the live firmware debug ring, first copy scratch
`0x70000..0x74fff` to a file on the device:

```sh
python3 tools/serial_cmd.py "$PORT" \
  'dd if=/sys/kernel/debug/apple_gpu_iop/scratch of=/run/compute-debug.bin bs=4096 skip=112 count=5 2>/dev/null' 8 20
python3 tools/serial_get.py "$PORT" /run/compute-debug.bin out/resume/debug.bin
```

## PDS execution versus completion (55–61)

The earlier "PDS does not execute" reading was too strong for a different
reason: 55 shows the branch target is fetched. 55 places a two-way branch at the
last mapped PDS code words; both paths target 0x300004000, the next unmapped
page. The MMU fault is a read at exactly that address (requestor 10, PDS, status
0x0300004000000289), so the branch was decoded and its target fetched. 56 repeats
the branch to a mapped HALT at 0x3f0c: no fault, still no completion. 57 forces
PDS-related clocks before the kick; CLK_STATUS stays 0x200 and completion fails.

58–61 try to make the next step explicit. 58 points DOUTU at a mapped 4-byte PCO
control NOP/END. 59/60 point DOUTU at an unmapped USC code page and vary cc/end
and the PDS sequential-dependency type. 61 forces PDS and USC clocks before the
kick. None faults or completes. After 61, CLK_STATUS is 0x600 (USC running) but
PDS status bit 6 remains 0. So a PDS-only kernel still does not retire, and the
DOUTU→USC fetch is not established. A native G9P PDS/USC program or a PDS
clock/power fix is now the concrete missing piece. The device was restored to
the 46 baseline after 61.

```sh
for n in 55 56 57 58 59 60 61; do
    python3 tools/serial_put.py "$PORT" "tools/agx-init$n.sh" "/run/agx-init$n.sh"
done
# 55: expect a read fault at 0x300004000 and no completion.
python3 tools/serial_cmd.py "$PORT" \
  'MODE=real HOOK=/run/agx-init55.sh sh /run/compute-run.sh; echo RUN_EXIT=$?; devmem 0x20100e150 64' 8 45
# 56: mapped control; no fault, no completion.
python3 tools/serial_cmd.py "$PORT" \
  'MODE=real HOOK=/run/agx-init56.sh sh /run/compute-run.sh; echo RUN_EXIT=$?' 8 45
```

## Experiment ledger

| Hook / run | Change and observed result |
|---|---|
| 16 | Compute ring 2, queue, pointer list, raw command type 3. RAM RGX initially stalls on self-clearing init bits; manually clearing RAM `+0x11f00/+0xcd8/+0xcb8` reaches abort **0xe706**, null scheduling pool. |
| 17 | Queue+0x0c points to a 128×44-byte scheduling pool, second ARM mapping. Abort **0x18592**: missing T+0x7dc MMU-generation array. |
| 18 | Supplies generation array. Branch to **PC 0**: engine callback table uninitialized. |
| 19 | V+0x45b4 = 1 requests scheduler initialization through 0xd980. Reaches compute prepare callback 0x1338c; abort **0x13414** doing cache maintenance on null command+0x14 context. |
| 20 | Supplies compute context and microsequence. Corrects X+0x1ec/+0x1fc from guessed pointers to scalar fields. Descriptor consumed, but opcode 0 waits for an IRQ; not completion. |
| 21 | End-only opcode 2 instead of opcode 0. Still no completed queue. |
| 22 | P+0x16c0/+0x16c4/+0x16c8 = 1 enable one scheduling unit per engine. No completed queue. |
| 23 | Queue+0x44 = 1 supplies the available-unit mask. Interpreter executes End, then aborts **0xfe84** on a null completion-address argument. |
| 24 | Cancellation-path FinalizeCompute followed by End. First stamp reaches 1; abort **0x9822**, missing host notification stamp address. |
| **25** | Supplies raw command completion descriptor and firmware→host event ring. **Both stamps = 1; event producer = 1; no crash. CPU cancellation only, no GPU execution.** |
| 26 RAM | StartCompute/WaitIRQ/FinalizeCompute/End, provisional Rogue tables and terminate stream. RAM writes include `+0x478 = 1`, `+0x498 = 0x200000`, `+0x4b8 = 0x201000`. Interpreter advances to the wait. |
| 26 real | First real CDM attempt. MMU fault `+0xe150 = 0x119`; firmware abort **0x9480** because an always-used trace ring was missing. No completion. |
| 27 | Supplies that trace ring. Same GPU fault, no firmware crash, no completion. |
| 28 | Adds separate SKU debug ring and U[0] = 3. Captures start/recovery trace records. No completion. |
| 29 | Start/Finalize unit-state pointers now use shared X+0x13c target, not a private page. Same fault. |
| 30 | Forces full context-0 PC/PD/PT invalidation via generation difference 0x400000. Acknowledged generation updates; same fault. |
| 31 | Replaces incorrect P[0..0x27] guesses with exact kext constants. Same fault. |
| 32 | Actually power-cycles **RGX core** through Fender state 0→1. Fault clears to 0 before init, recurs as 0x119 on submission. Confirms it is not merely a stale previous fault. |
| 32 empty kick | After fresh core cycle and initialization, an empty doorbell leaves fault = 0 and no crash. Fault appears only with the real work probe. |
| 33 | Supplies context-store/load PDS addresses as well as terminate PDS addresses. Same fault. |
| 34 | Tries Apple/Asahi-style CDM terminate word 0x40000000 instead of Rogue 0x80000000. **Same fault; does NOT establish Apple CDM compatibility.** |
| 35 | Reverts to hook 33's stream and adds PTE SLC-bypass bit 3. Same 0x119 fault, zero stamps, no firmware crash. |
| 36 | Sets RGX+0x480 to mapped VA 0x202000, initially misidentified as a context-state buffer. It is actually the stream register: the zero-filled page is parsed as a kernel packet. Interpreter reaches IRQ wait; fault moves to PDS heap VA 0x300000000, status 0x0300000000003229. |
| 37 | Maps PDS heap base to an owned read-only HALT page. No MMU fault, but no completion. |
| 38 | Wrong wait-mask detour: mask 8 instead of 4. No completion. Initial 0x102 trace event was misinterpreted; it does not prove compute completion. |
| 39 | Another wrong wait-mask detour: 0x8000, derived from a different firmware handler. No completion. |
| 40 | Puts intentionally unmapped VA 0x400000 in +0x498. No fault: this register is not the active stream base. |
| 41 | Puts the same unmapped VA in +0x480. Fault 0x0000400000000119 identifies exactly VA 0x400000. Strong hardware evidence for the register correction and fault-address decoding. |
| 42 | Actual stream +0x480 = 0x200000; context/storage +0x498 = 0x202000. Rogue terminate produces compute-finished IRQ (pending status 4); wrong wait mask still prevents finalization. |
| 43 | Retests 0x40000000 at the real stream address. Faults reading VA 0, consistent with Rogue STREAM_LINK, not Apple-style termination. Earlier comparison 34 was inconclusive because it targeted the wrong register. |
| 44 | Restores correct IRQ mask 4 with corrected stream. Trace reaches FinalizeCompute (event 8); normal cache-flush path faults writing VA 0, status 0xff251. |
| 45 | Diagnostic only: maps VA 0 to an owned catch page. Full completion, both stamps and host event = 1; no fault/crash. Catch page remains zero. NOT the final fix. |
| **46** | Supplies Q[0:8] = GPU VA 0x203000, consumed as RGX+0xe240 scratch/fence address. Same full real completion **without a null mapping**. Successfully repeated after 49; this is the current working baseline. |
| 47 | Adds one PDS HALT-only kernel packet before terminate. No fault, but no completion. Initial group counts were 1 (actually minus-one encoding, so 2×2×2). No USC shader. |
| 48 | Fixes group counts to 0 (1×1×1), adds provisional Rogue DOUTC/HALT with 16-byte constants. Still no fault or completion. No USC shader. |
| 49 | Negative control: same packet, deliberately unmapped PDS code offset 0x400000. Fault 0x0300400000000299 decodes to GPU VA 0x300400000. Confirms code fetch is reached; does not validate the candidate PDS program or USC ISA. |
| 50 | Full reference-shaped fence: minimum data, fence/PDS dependency, task-type guard and barrier reset, fresh code offset 0x1000. **Stalls**, no fault/crash, no stamps/event; downloaded stream/code/constants match plan exactly. |
| 51 | Reference-shaped empty/shared-allocation task, code offset 0x2000. Same stall, no fault/crash, matching payload. |
| 52 | Short DOUTC/HALT with corrected fence/dependency, code offset 0x3000. Same stall, no fault/crash, matching payload. These setup changes alone did not fix dispatch. |
| 53 | Fresh PDS page and writable owned output page; generic Rogue LIMM/ST/WDF attempts marker 0x1357. No completion/fault/crash; output remains sentinel **0xabadbeef**. No PDS store proven. |
| 53 clock test | Temporarily forces PDS clock field 12 to ON for one second; no marker/fault/progress. Original value restored. |
| **54** | Unguarded LIMM/ST/WDF/HALT with deliberately unmapped store destination 0x400000. No expected write fault, no completion. Does not establish instruction execution; descriptor/ISA/dispatch/cache/enable issues remain possible. |
| 54 clock test | Temporarily forces selected already-AUTO clock fields ON; CLK_STATUS changes, but no fault/marker/progress. Original CLK_CTRL **0xa02a82000a2a2a0a** restored and independently read back. This is not a complete clock/enable-path validation. |
| 46 after 54 | Restores known baseline. Both stamps = 1, queue retired, hardware IRQ/finalize/host trace verified, zero MMU fault/crash. Offline evidence validator passes. |
| **55** | PDS branch at code offset 0x3f00 targets unmapped 0x300004000. Fault 0x0300004000000289: read at 0x300004000, requestor 10 (PDS). Shows branch target fetch; no completion. |
| **56** | Control: same two-way branch targets mapped HALT at 0x3f0c. No fault, no completion. Separates target fetch from kernel retirement. |
| **57** | 56 plus PDS-related clock fields forced ON before the firmware kick. CLK_STATUS stays 0x200, XTPLUS_STATUS 0; still no completion. Clocks restored. |
| **58** | PDS DOUTU to a mapped 4-byte PCO control NOP/END at 0x300002000. No fault, no completion, no crash. DOUTU/USC path not established. |
| **59** | DOUTU points at unmapped USC code 0x300004000; sd_type USC; cc/end variants 0xf8000002, 0xfc000002. No fault, no completion. |
| **60** | Same DOUTU test with sd_type NONE (0x80), DOUTU 0xf4000002/0xfc000002. No fault, no completion. PDS code path alone is not enough. |
| **61** | 60 plus PDS and USC clocks forced ON before the kick. CLK_STATUS 0x600 (USC running), PDS bit 6 still 0; no fault/completion. Clocks restored. |
| **62** | 59 with DOUTU src0 encoded as Rogue specifies: 32-bit offset 0x4000 from the assumed USC code base 0x300000000 (kext P+0x18), temps = 1 block (bit 35). 58–61 had put the VA high word 0x3 into the sample-rate bits. No fault, no completion. |
| **63** | 62 with offset 0x2000 holding **native applegpu_g9p USC code** (empty kernel compiled offline by `metal-tt`). No fault, no completion. The gate is before USC: the PDS task neither retires nor issues DOUTU. |
| 46 after 63 | Baseline restored, RUN_EXIT=0. |
| **65** | Apple's native PDS encoding (DOUTU 0xf4000002, src0 hi 0x10) aimed at unmapped USC 0x300004000. No fault, no completion. |
| **64** | Same with the native empty kernel at USC offset 0x2000. No fault, no completion. The PDS encoding alone is not the gate; the CDM kernel words or CDM context setup likely differ from iOS. Baseline 46 restored afterwards (RUN_EXIT=0). |
| **66** | **First shader dispatch completes.** Apple's exact CDM record (8 words: `0x2103, 0x800, 0x3f00, 0, 0, 0, 0x40000000, 0`, then terminate `0x80000000`), Apple's PDS program (`c2c00002 d3000000 f0000a01 fc000002 d3000000`), PDS data `{0x2000, 0x10, 0x80000000, 0}` and the native G9P empty kernel at USC 0x2000. Both stamps = 1, RUN_EXIT=0, no MMU fault, empty crashlog. |
| **67** | Negative control for 66: PDS data points DOUTU at USC offset 0x4000. **MMU fault at exactly 0x300004000, status 0x0300004000003409** (a different requestor from the PDS fetch fault 0x…289), no completion. This proves the USC fetched and ran 66's shader, and that the USC code base is 0x300000000. Baseline 46 restored afterwards (RUN_EXIT=0). |
| **68** | **First shader-written result.** iOS's two records: record 0 is the DMA-only PDS task (`k0 4`, `k1 0x902`, code `f0001000 f4001808 d3000000`, data `{0x300001000, 0x300001010, 0x10000002, 0x90004001}`), which loads the argument-table entry `{0x204000, 0, 0x10001}` into the common store. Record 1 is 66's kernel running native `store_marker`. Output page (GPU VA 0x204000) reads **`0x00001357`** at +0, with +4 still `0xabadbeef`; both stamps 1, RUN_EXIT=0, no fault. |
| **69** | Control: binding moved to 0x204010. `0x1357` appears exactly at +0x10; +0/+4 keep the sentinel. The store goes through the DMA-loaded binding. Baseline 46 restored afterwards (RUN_EXIT=0). |

Logs and raw captures are under `out/resume/`, ignored by Git. For example:
`compute25-cancel-completed.log`, `compute26-ram-start.log`,
`compute32-real-cycle.log`, `init32-empty-before-dma.log`,
`compute34-real-apple-cdm.log`, and `compute35-real-slc-bypass.log`.

New DFU session: `dfu-resume-boot.log`, `dfu-resume-smoke.log`,
`compute36-context-base.log`, `compute40-unmapped-498.log`,
`compute41-unmapped-480.log`, `compute42-stream-register.log`,
`compute43-apple-terminate.log`, `compute44-real-completion.log`,
`compute45-null-catch.log`, **`compute46-real-completed.log`**,
`compute47-pds-halt.log`, `compute48-pds-doutc.log`,
`compute49-pds-unmapped-code.log`, and **`compute46-repeat-after49.log`**.
SHA-256-verified debug captures accompany 36–39, 42, and 44–49, plus the 46
repeat. The successful repeat proves recovery to the working baseline after the
intentionally faulting negative control.

## Latest hardware session: payloads, store probes, clocks and evidence

The existing boot payload was reused; USB changed to **1301**. The cached module
was missing, so a fresh external module was built without changing its source.
Both the initial and final 46 runs pass `gpu_evidence.py validate` with their
matching captures. There was no device storage mount or firmware modification.

50–52 payload checks compare the SHA-256-verified device captures with
`pds_probe.py`: all eight stream words, all PDS code words and zero constants
match exactly. Thus a host upload/plan mismatch is not the observed cause.
Shared compute status remains 1, stamps/event producer zero, queue state 2 and
microsequence at the IRQ wait. Trace contains StartCompute but no FinalizeCompute.

53 adds only owned mappings:

- GPU output VA **0x204000** → scratch PA+0x98000, 16 KiB, flags 9 (RW/SLC bypass).
- PDS heap+0x4000 → scratch PA+0xa0000, 16 KiB, flags 13 (read-only/SLC bypass).
- Code offset 0x4000, data offset 0x4800; KERNEL0=0x107 includes one temp chunk.
- Generic Rogue `LIMM temp0=0x1357; ST; WDF` sits after the task guard, before
  DOUTC/HALT. The ST descriptor at scratch+0xa0800 is `(1 << 40) | 0x204000`:
  one dword from temp0, write-through policy. CPU sentinel is 0xabadbeef.
- Output remains 0xabadbeef. This is **not** a shader or a proven GPU store.

54 uses fresh code/data offsets **0x5000/0x5800** in that same new PDS page,
removes the predicate guard and DOUTC, and changes the descriptor destination to
**unmapped GPU VA 0x400000**. If the assumed generic ST path executes, it should
produce a write fault; no such fault was observed. This negative result cannot
by itself distinguish unsupported ISA, task/enable/feature setup, instruction
visibility, or a descriptor assumption. Do not label it successful execution.

Clock diagnostics were live **after** the stall, not before dispatch:

- After 53: force only CLK_CTRL bits 13:12 to ON for one second. No marker or fault.
- After 54: force fields at shifts 52,48,46,40,26,24,20,16,12 to ON for one second.
  CLK_STATUS changes to 0x101700; no marker/fault/progress appears.
- Both restore original CLK_CTRL **0xa02a82000a2a2a0a**. Independent later readback
  confirms restoration. No permanent clock workaround was added to any hook.
- These tests do not rule out a startup requirement or establish all G9P clock
  field interpretations. Register +0x630 still reads zero; clock-gated readback
  is not sufficient evidence that its firmware initialization write failed.

Saved under `out/resume/` (ignored):

- `dfu-pds50-boot.log`, `module-rebuild-50.log`, `module-rebuild-50/apple_gpu_iop.ko`.
- `compute46-pds50-session.log`, `compute46-pds50-debug.bin` (initial baseline).
- `compute50-fence-real.log`, `compute51-empty-real.log`, `compute52-short-fence-real.log`.
- `compute53-store-real.log`, `compute54-unguarded-write-fault.log`.
- `computeNN-state.bin` and `computeNN-stream.bin`, NN=50..54; state starts at
  scratch+0x70000. 50–52 capture 24 pages; 53/54 capture 52 pages (through +0xa3fff).
  The stream capture starts at +0x60000, one page. All downloads were SHA-256 verified.
- `compute53-pds-clock-on.log`, `compute54-clocks-on.log`, `compute54-clock-restored.log`.
- `compute46-after54.log`, `compute46-after54-debug.bin` (final working state).
- `pds50-54-observations.json` verifies all payloads, unchanged sentinels, unchanged
  module source, and both baselines. `pds50-54-encoder-reference.json` records the
  current seven-instruction C/reference comparison and tested-failed profile metadata.

To rebuild the module if its cache/artifact is gone, run from the **orchard checkout root**
(the shared kernel work tree is described in `kernel/build`):

```sh
kwork=${XDG_CACHE_HOME:-$HOME/.cache}/orchard/kernel-work/apple-16k-$(sed -n 's/^commit=//p' kernel/upstream.lock | cut -c1-12)
mout=$(mktemp -d "$PWD/examples/gpu-001/out/resume/module-build.XXXXXX")
cp examples/gpu-001/kernel/gpu-iop/Makefile examples/gpu-001/kernel/gpu-iop/apple_gpu_iop.c "$mout/"
podman run --rm --network none --userns keep-id \
  -v "$kwork/source:/src:ro" \
  -v "$kwork/output:/out:rw" \
  -v "$mout:/modules:rw" \
  localhost/orchard-hardware-kernel-toolchain:bookworm \
  bash -euc 'make -C /src O=/out -j2 LLVM=-19 ARCH=arm64 LOCALVERSION=-orchard-apple M=/modules modules'
```

This requires the existing matching kernel output/Module.symvers. Do not substitute
an unrelated kernel/module just because the release string looks similar.

## Queue and microsequence layout recovered

All addresses below are firmware VAs unless explicitly labeled PA. They describe
our synthetic layout; they are not an upstream ABI.

| Object | Firmware VA | Scratch offset |
|---|---|---|
| Work ring 2 (256 × 20 bytes) | 0x129000 | 0x29000, two pages |
| Queue (at least 0x8c bytes) | 0x12b000 | 0x2b000 |
| Queue state | 0x12c000 | 0x2c000 |
| Command-pointer ring | 0x12d000 | 0x2d000 |
| Queue status/tracking | 0x12e000 | 0x2e000 |
| Raw compute command (0x2c8 bytes) | 0x12f000 | 0x2f000 |
| Scheduling pool (128 × 44 bytes) | 0x140000 | 0x50000 |
| GPU context generations | 0x142000 | 0x52000 |
| Compute context (at least 0x84 bytes) | 0x143000 | 0x53000 |
| Microsequence | 0x144000 | 0x54000 |
| Completion stamps | 0x145000 | 0x55000 |
| Guard/counter storage | 0x146000 | 0x56000 |
| Event-ring control / data | 0x147000 / 0x148000 | 0x57000 / 0x58000 (3 pages) |
| Compute register arguments / terminate PDS state | 0x14b000 / 0x14c000 | 0x5b000 / 0x5c000 |
| Always-used trace data / control | 0x154000 / 0x158000 | 0x64000 (4 pages) / 0x68000 |
| SKU debug data / control | 0x160000 / 0x165000 | 0x70000 (5 pages) / 0x75000 |

Initial mapping: VA 0x100000 → scratch, 56 pages. Later mapping: VA 0x140000 →
scratch+0x50000; experiments grow it from 16 to 64 pages. Both use flags 0
(inner noncacheable). GPU page tables and code live in the intervening physical
scratch pages; the ARM mapping is not the GPU mapping.

Work ring descriptor:

- +0x08 = queue pointer; +0x0c = engine type 2.
- +0x10 u16 = target command-pointer-ring head (1 in the probe).
- +0x12 u8 = queue slot/index passed to 0xdac6 (0 in the probe).
- +0x13 u8 = extra flag (0 in the probe; full semantics not recovered).
- Ring 2 indices: scratch+0x11020 consumer, +0x11024 cache index,
  +0x11028 producer.

Queue fields used: +0x00 state pointer; +0x04 command-pointer-ring pointer;
+0x0c scheduling-pool pointer; +0x10 read head; +0x14 cache-synchronized head;
+0x18 target head; +0x44 available-unit mask; +0x88 status pointer.
Queue state +0x50 is capacity (256). Do not create an empty queue and assume
all callbacks will handle it without registration.

Raw compute command:

- +0x00 = 3 (compute).
- +0x14 = context pointer; +0x1e8 = microsequence pointer;
  +0x1ec = microsequence byte size.
- +0x26c starts a 24-byte completion descriptor; its first word is the host
  stamp pointer, +0x274 is the stamp value/tag. The probe uses stamp value 1.

Interpreter: firmware **0x9f04**, opcode dispatch table at **0xa3dc**.

| Opcode | Observed meaning |
|---|---|
| 0 | Wait for IRQ; mask is the header shifted right by 6. Mask **4** now works for compute; 8 and 0x8000 were unsuccessful detours. |
| 2 | End/retire; requires completion metadata populated by an earlier operation. |
| 0xb | StartCompute, 0x48 bytes in the probe; writes CDM registers and kicks RGX+0x478. Stream base is **+0x480**, not +0x498. |
| 0xc | FinalizeCompute, 0x30 bytes; cancellation status 3 skips the normal cache-flush path. |

The real probe has Start at +0x00, Wait at +0x48, Finalize at +0x4c, End at
+0x7c, total 0x80 bytes. Hook 46 completes this full sequence, including normal
cache flushing; no cancellation status is forced. The working cancellation probe instead has Finalize at
+0x00 and End at +0x30, with unit status 3. **Do not equate these tests.**

Important init corrections:

- V+0x45b4 = 1 initializes callback tables (0x1b688 → 0xd980).
- T+0x7dc points to GPU MMU generations; T+0x7e0 points to 256 physical roots.
- X+0x188 points to acknowledged MMU generations.
- X+0x1ec and X+0x1fc are **not ordinary pointer slots** as guessed in the
  original section 13. The compute probe sets both to 0; +0x1fc is incremented
  and decremented as outstanding work is prepared/completed.
- P+0x16c0/+0x16c4/+0x16c8 supply engine masks. Flags copied to shared+0x768
  come from **P+0x16b4**, not P+0x16bc.
- Start/Finalize unit-state arrays use the X+0x13c target (VA 0x11e000).
- X+0xdc/+0xe0: event-ring control/data, 256×36-byte entries.
- X+0xf4/+0xf8: always-used trace control/data, 256×60-byte entries.
- X+0xec/+0xf0: optional SKU debug control/data, 512×36-byte entries.
- U[0] = 3 enables SKU debug flags. Allocate full trace buffers before enabling
  them; the old one-page placeholders are too small.

## GPU MMU and fixed init values: static evidence vs hardware validation

The kext's **AGXGartG3ThruG9** constructor/geometry setup at
`0xfffffff0060365a8..0x6036668` establishes Rogue-like three-level tables:

- PC: 1024 × u32, index shift 30; PA encoded as `(PA >> 12) << 4`, valid bit 0.
- PD: 512 × u64, index shift 21; physical address bits start at bit 5.
  With the 16 KiB page shift, the page-size/valid flags are 3.
- PT: 128 × u64 per 2 MiB span for 16 KiB pages; PA in bits 12..35,
  valid bit 0. The kext's flag method at `0xfffffff0060364d0` agrees with the
  relevant upstream Rogue permission/cache flag positions.

Our root is scratch PA+0x40000, PD +0x44000, PT +0x48000. GPU VA 0x200000
maps one owned 16 KiB page at scratch PA+0x60000. The stream starts there;
the provisional Rogue PDS HALT word is at +0x61000. Other GPU mappings remain
invalid in hook 46 (including GPU VA 0). These tables are now validated for the
terminate-only path and by deliberately unmapped-address fault controls. This is
not proof every page size, permission, cache mode, or address-space feature works.

Corrected StartCompute argument block at VA 0x14b000:

| Argument offset | RGX register | Current value / interpretation |
|---|---|---|
| +0x00/+0x04 | +0x498/+0x49c | 0x202000, context/storage base (not stream) |
| +0x08/+0x0c | +0x4b8/+0x4bc | Terminate PDS code/data offsets; old provisional values retained |
| +0x10/+0x14 | **+0x480/+0x484** | **0x200000, actual stream base** |

For hook 46, GPU VA 0x203000 is the scratch/fence address supplied through
Q[0:8] at scratch+0x6000. Firmware 0x1bb0a..0x1bb1e copies Q[0:8] to local
0x8dd50; 0x597c..0x599c programs it into RGX+0xe240 when nonzero. Missing it
caused the later **write** fault 0xff251 during FinalizeCompute. Mapping VA 0 in
45 was diagnostic only; 46 fixes the supplied address instead.

Hook 37 also adds PC index 12 for the PDS heap at GPU VA 0x300000000:
PD = scratch PA+0x80000, PT = +0x7c000, read-only SLC-bypass code/data page =
+0x84000. PDS candidates use code offset 0, data offset 0x100. Kernel group
counts and local dimensions are both **minus-one encoded**. No successful
non-empty kernel/PDS program or USC shader has been demonstrated.

Kext `0xfffffff006012bd0..0x6012bec` initializes P[0..0x27] to:

| Offset | u64 value |
|---|---|
| +0x00 | 0x600000000 |
| +0x08 | 0xffc00000 |
| +0x10 | 0x300000000 |
| +0x18 | 0x300000000 |
| +0x20 | 0x1ffff8000 |

These are fixed address-window values, **not** our scratch physical-memory range
and **not** the context-0 root. Hook 26 guessed otherwise; hook 31 corrects it.
Their complete hardware semantics are not yet established.

For root readback, temporarily forcing the MMU clock field in RGX+0x0 bits
17:16 from AUTO (2) to ON (1), as the kext does at `0xfffffff006032658`, made
RGX+0xe148 readable: **0x802440**, matching scratch PA+0x40000 >> 12.
The previous zero readback under clock AUTO was not proof that programming
failed. Do not describe clock mode 2 as OFF: mode 0 is OFF. The successful
capture is `out/resume/mmu-clock-on.log`; the preceding decimal signed-value
write attempt was rejected by BusyBox and made no change.

Reloading `apple_gpu_iop` restarts the IOP firmware but does **not** reliably
power-cycle RGX. Hook 32 uses Fender+0x1000 requests 0x10 (state 0) and 0x11
(state 1), with bounded acknowledgement checks. This clears the fault before
submission. Never read RGX while state 0 is acknowledged.

## Fault and trace decoding now grounded in controls

For this GPU, the successful controlled faults support the upstream field layout:
`address = (status >> 28) << 4`, context = bits 20..27, subblock = bits 12..19,
requestor = bits 6..11, level = bits 4..5, read = bit 3, type = bits 1..2,
valid = bit 0. Preserve all **64 bits**: the runner's 32-bit fault print loses
address information; follow it with `devmem 0x20100e150 64`.

| Status | Address | Requestor / access | Observation |
|---|---|---|---|
| 0x119 | 0 | 4 / read | Original null-stream fault |
| 0x0000400000000119 | 0x400000 | 4 / read | Intentional unmapped stream in 41 |
| 0x0300000000003229 | 0x300000000 | 8 / read | Missing PDS heap PC entry in 36 |
| 0xff251 | 0 | 9 / write | Missing flush scratch/fence address in 44 |
| 0x0300400000000299 | 0x300400000 | 10 / read | Intentional unmapped PDS code in 49 |

Debug records are 9 u32s: kind, timestamp-low/high, **r2, r3, stack-arg0,
stack-arg1, event/thread tag, auxiliary**. Do not interchange arguments when
reading traces. For successful 46 the important sequence is:

1. Event 7: StartCompute.
2. Event 0x102: r2=3, r3=0x80000000, stack-arg0=4, stack-arg1=0.
   This is the compute-finished pending status **4**, not a wait mask of 8 or
   0x8000. Firmware 0x21dd4 routes these events through handler class 3.
3. Event 8: FinalizeCompute.
4. Event 0x103: same IRQ source, pending status now 0.
5. Host completion/event activity; queue state 3, IP = 0x144080, both stamps 1,
   event producer at scratch+0x57020 = 1; MMU fault and crashlog both zero.

The runner's stale private-unit dump is not part of that proof. The 46 repeat
capture contains the same ordered Start → hardware IRQ → Finalize sequence.

## Offline validation (device not required)

`tools/gpu_evidence.py` uses only Python's standard library and never opens a
serial port. It decodes complete fault values, decodes the SKU trace arguments,
and checks a paired serial log/debug capture for the recorded terminate-only
milestone. It checks both stamps, retired queue/IP, zero 64-bit fault readback,
zero crashlog, successful exit, and the ordered hardware IRQ/finalize/host trace.
It rejects truncated, gapped, or full/wrapped trace rings rather than inventing
chronology without their producer index. It does not independently authenticate
that a supplied log and trace came from the same run; choose the recorded pair.
It does **not** certify USC shader execution or acceleration.

From the example directory:

```sh
python3 -m unittest discover -s tools -p 'test_*.py' -v
python3 tools/gpu_evidence.py fault 0x0300400000000299
python3 tools/gpu_evidence.py validate \
  out/resume/compute46-real-completed.log out/resume/compute46-debug.bin
python3 tools/gpu_evidence.py validate \
  out/resume/compute46-repeat-after49.log out/resume/compute46-repeat-debug.bin
```

Both recorded 46 pairs pass. The stalled/faulting 44, 47, 48 and 49 pairs are
rejected. Aggregate results are saved locally in
`out/resume/offline-evidence-report.json` (ignored along with the raw captures). There are now **27 passing host tests**: four Mach-O/disassembly tests, ten
fault/evidence tests and thirteen PDS probe/reference tests. Evidence tests cover
cancellation rejection, wrong IRQs, ordering, truncation/wrap, incomplete stamps,
faulted logs and unsuccessful exits. See PDS-OFFLINE.md for the additional C
encoder/disassembler and XML comparisons, candidate hooks and their limitations.

Useful offline source entrypoints for the next PDS investigation:

- `src/imagination/vulkan/pvr_arch_cmd_buffer.c`, compute kernel emission near
  2080–2215: global counts **and** local sizes are minus-one encoded; use actual
  generator behavior, not only XML field descriptions.
- `src/imagination/vulkan/pds/pvr_pds.c`: `pvr_pds_setup_doutu` (USC task control),
  `pvr_pds_generate_doutc` (near 3564), and
  `pvr_pds_generate_compute_barrier_conditional` (near 3816). The normal fence
  program includes predicate/task-type handling missing from the tiny candidates.
  Whether that matters here needs testing, not an assumed fix.
- `src/imagination/pdsc/pdsc_isa_pack.h`: HALT and DOUT packing. The candidates
  match the generic packer numerically, but that alone does not prove G9P ISA or
  feature compatibility. Do not submit these experiments upstream as Mesa work.

## Native G9P code and ground truth from iOS (2026-10-29, after 61)

**Offline native compiler.** Xcode's downloadable Metal toolchain
(`xcodebuild -downloadComponent MetalToolchain`) still ships
`libapplegpuG9G12-nt.dylib`. `metal-tt -arch applegpu_g9p` turns a metallib plus
a `.mtlp-json` pipeline script into a Mach-O GPU executable for A10 (CPU type
0x1000013, subtype 0x51). Each function is a nested Mach-O whose `__text` is USC
code, plus FlatBuffer metadata sections (`__GPU_METADATA`, `__GPU_LD_MD`, ...).
There is no assembly output (`AIRNTEmitAssembly` is not implemented) and no
disassembler.

**The native USC encoding is not Mesa PCO.** The empty kernel is
`00 01 40 01 00 00`, then `00 c0` repeated (padding), then `00 80` (end):
16-bit-granular instructions. 58's PCO NOP `01 80 ee 00` was therefore not
valid A10 code. Mesa's `pco` cannot be assumed to target A10; a G9P encoder is
needed for shaders. A one-store kernel is 0x38 bytes of code (not yet decoded).

**PDS is not in the compiler output.** The compiler library names
`pds_patchup_compute`, `pdsPatchUpOffsets` and `cei_pds_gen_*` (GPU-side PDS
generation for indirect command buffers), but no PDS words appear in the
binary. AGXMetalA10 code has no HALT/DOUT immediates either, so the runtime PDS
format is still unknown offline.

**Ground-truth capture under iOS (done 2026-10-29).** `ios-capture/capture.m`
(`gpu-capture`, ad-hoc `ldid` signed, never the developer certificate) runs one-thread
compute dispatches under stock iPadOS 17.7.11 on the J71b, then saves its own
readable memory regions that contain the needles. All three kernels ran
(`out[0] = 0x1357`, `out[1] = 0x2468`). Raw dumps: `out/ios-capture/` (ignored).

- **Access:** the boot was palera1n rootless (`ios-capture/overlay.py --boot`,
  which also carries the tool). The shell was the device's Procursus OpenSSH on
  Wi-Fi, with a key installed for mobile and root. Without
  `com.apple.security.iokit-user-client-class` = {AGXDeviceUserClient,
  IOGPUDeviceUserClient, IOSurfaceRootUserClient}, the accelerator open returns
  `0xe00002e2` and `MTLCreateSystemDefaultDevice()` is nil. That holds as root and
  in the foreground; GPU-deny policy and the other entitlements tried were not it.
  `overlay.py` now boots with `-T` (root telnetd on 46) for setups without SSH.
- **GPU-shared memory** is the tag-100 (IOAccelerator) mappings. Buffer GPU
  VAs are `0x1000xxxxx`, distinct from the CPU mappings.
- **USC code as loaded matches `metal-tt -arch applegpu_g9p` byte for byte.**
  The offline compiler is a valid A10 code generator.
- **Native compute PDS sits next to its USC code** in the same 64 KiB heap. For the
  empty kernel (USC at heap+0x40): data at +0x100 is `src0 = 0x00000010_00000040`
  (EXE_OFF 0x40 relative to the heap base, temps field 2); code at +0x120 is
  `0xf4000002` (DOUTU, **END=1, CC=0**) then `0xd3000000` (HALT). The store kernels'
  PDS add DOUTW: `0xf0001001 0xf0001409 0xf400001a 0xd3000000`, with a branch
  prologue (`0xc1100001 0xdb000000 0xc1080001`).
- **Root cause candidate for 50–63:** DOUT's CC is bit 27 and END is bit 26.
  58–63 used `0xf8000002` (cc=1, end=0) or `0xfc000002` (cc=1, end=1); 60's
  `0xf4000002` had the broken src0. The native combination was never tested.
  Hooks **64** (native empty kernel) and **65** (the same pointing at unmapped
  USC 0x300004000, a fetch-fault control) test it.

**Second capture (before commit, 2026-10-29 22:31; `out/ios-capture2/`).**
Snapshots were taken right after `endEncoding`, before commit, and again after
completion. **No CDM stream or kernel words exist in user-visible memory before
commit.** The GPU-tagged regions that change hold only completion stamps
(`0x00031602`-style slots) and the output buffer. The rest is the pipeline
binary (shader cache Mach-O) and Metal object state (the MTLBuffer record with
GPU VA 0x100038000, length 0x4000, CPU pointer). Conclusion: on A10 the AGX kext
composes the compute command (CDM words, firmware work item) from what userspace
submits through IOConnect. Getting Apple's kernel words therefore means either
reverse-engineering the kext's compute submission path statically, or capturing
the IOConnect submission and the kernel-built structures (kernel read access).

The capture tool scans the whole address space once per needle per phase. It
ran for minutes and the device then panicked in the Wi-Fi driver ("WiFi Dext
Crash Recovery during Reset"), not the GPU. The likely trigger was memory
pressure plus the SSH-over-Wi-Fi load. Keep future captures to one snapshot, of
GPU regions only.

**Third capture: the CDM stream itself (2026-10-29 22:50; `out/ios-capture6/`).**
On A10, Metal submits through one fast IOKit trap (`iokit_user_client_trap`,
index 0, a 0x38-byte record). `ios-capture/iohook.m` patches that syscall stub's
entry, using a trampoline, and snapshots memory inside the trap, right before
the kernel reads it. Patching IOKit text pages later SIGILLs the completion
thread, so the tool `_exit`s after the trap. The CDM control stream is a
GPU-shared region of 8-word kernel records; the terminate `0x80000000` is
appended at commit. Our store kernel was record 1:

| Item | Value |
|---|---|
| k0..k5 | `0x2103` (fence, usc_target, pds_temp 1, unified 2), data `0x2280`, code `0x2200`, 0, 0, 0 |
| k8, word 7 | `0x40000000`, **`0`** (8 words per record), then terminate `0x80000000` |
| PDS code @0x2200 | `c2c00002 d3000000 f0000a01 fc000002 d3000000` |
| PDS data @0x2280 | `000020c0 00000010 80000000 00000000` (USC offset, temps 2, DOUTW value) |
| USC | store kernel at heap+0x20c0: PDS exec base = USC code base = this heap |

Record 0 (`k0 = 4`, data `0x34200`, code `0x2180`: `f0001000 f4001808 d3000000`)
is a DMA-only DOUTD task before the kernel. It probably loads the buffer
binding into the USC common store; its data lay outside the dumped regions.
Records 2–6 are Metal-internal.

**Fourth capture: the buffer binding (2026-10-29 23:15; `out/ios-capture7/`).**
Two `store_marker` dispatches into different buffers in one command buffer
give two runs of 7 identical records, except record 0's `k1` (`0x30042` vs
`0x30062`). Record 0 is a DMA-only PDS task (`usc_common_shared` set). Its
32-byte data is `{src0 0x1_0006a068, src1 0x1_0006a078, 0x10000002,
0x90004001}`, and its code is `f0001000 f4001808 d3000000`: two DOUTDs. The
sources point into an argument table with one 0x18-byte entry per dispatch,
`{buffer GPU VA, CPU pointer, 0x10001}`. The DMA loads the buffer VA (2 dwords)
and `0x10001` (1 dword) into the USC common store, and the shader reads its
buffer from there. The capture tool is now bounded (GPU regions only, one at a
time). A broad scan inside the trap had driven the iPad into jetsam (lock-screen
respring, 23:13:40). **Hook 68** reproduces record 0, record 1 and
`store_marker` against the owned output page at GPU VA 0x204000.

Probes 50–65 had 7-word records, so the terminate was consumed as word 7 and
the following zero word parsed as another kernel. They also set `k1 = 0x88`,
a data address of 0x80, not 0x800. Hook 66 fixes both, and the shader runs.

## Next checks

0. Done: 66 runs a native shader (67 controls it); 68 writes a buffer (69
   controls the binding). Next: multi-thread dispatch (thread IDs, workgroup
   sizes), then a kernel-side submission path in a real driver. After that, decode the program-descriptor table
   captured at CPU 0x7f4004000 and the store kernels' DOUTW data. The aim is a
   buffer write from a native shader on Linux.

1. Keep hook **46** and its logs as the working real-GPU, terminate-only baseline.
   Do not chain exploratory fault-injection hooks into it or map VA 0 as a fix.
2. Do not repeat 50–52 expecting the offline setup changes alone to fix things:
   all three now fail identically with verified payload bytes. Likewise, 53's
   unchanged marker and 54's missing expected write fault do not prove that PDS
   instructions execute. Investigate actual G9P PDS ISA/task dispatch and required
   unit/feature initialization; distinguish fetch from decode/execution. A known
   native G9P program or instruction-progress diagnostic would be more useful than
   another unobserved HALT. Cache/coherency and startup enable/clock dependencies
   remain possible; forcing clocks only after a stall did not help and does not
   rule out every startup requirement. Generic Mesa's no-USC tasks remain only a
   reference, not proof that A10 must behave identically.
3. Execute a tiny USC shader that writes a known value to owned memory. That is
   the compatibility gate before selecting a compiler or substantial Mesa work.
4. Expand VM, interrupt/fence/recovery tests and only then build a render driver
   and userspace stack. Empty-stream completion is not full acceleration.

## Local source/tool state

- DFU resume reused the existing RAM payload; boot and serial-shell readiness were
  both verified, with no device storage mounted. USB changed to 21301. The module
  was restaged from cached component `f8f3fb3f1d71946f65da8af16c50ae4a9870482857636621e416cce99bc0c19c`,
  SHA-256 `3e9b81e50d390ef3490cee2d7577fe6d96d7495aca594d67eb6c810249472581`.
- In the latest DFU session, the old cached module path no longer existed. The
  module was rebuilt from unchanged `kernel/gpu-iop/` sources against the existing
  matching `.work/apple/output` using the local kernel-toolchain container; no
  kernel or module source was changed. Current staged module is
  `out/resume/module-rebuild-50/apple_gpu_iop.ko`, SHA-256
  `3ec621a995d2c7e69d42a582a4da30bec35ec9432a85956f86d651edd00392cd`.
  Build log: `out/resume/module-rebuild-50.log`. Kernel remains
  `7.3.0-rc1-orchard-apple`; baseline 46 passed before and after the new probes.
- Kernel and experiment module sources were not changed during experiments 16–61.
  The editable kernel source still contains the mailbox/DT changes. Cache-key
  work remains separately uncommitted in `worktrees/cli-kernel-cache`.
- Extracted firmware is already present locally in both expected rootfs paths;
  SHA-256 `104479454ada7f040e3c503d7ccc64a20ea46a60f2bbf906d3d5a3c6f6523c59`.
  It was not patched in this session.
- Offline kernelcache used:
  a locally decompressed iPad7,5 kernelcache (`ipsw download ipsw --device iPad7,5 --latest --kernel`).
  It is FAT Mach-O; `tools/disasm.py` handles the ARM64 slice and segment offsets.
- Local Mesa reference checkout: `out/reference/mesa`, mirror
  `https://github.com/chaotic-cx/mesa-mirror.git`, commit
  `1c3a936490f9f0951188218e136cd03bca497386` (sparse `src/imagination`, `src/asahi`).
  No Mesa code was modified. Relevant files: `src/imagination/csbgen/rogue/cdm.xml`,
  `cr.xml`, PDS HALT definitions, and `src/asahi/genxml/cmdbuf.xml`.
- An additional public register-header comparison was fetched under
  `out/reference/r8a7796-gpu`, `https://github.com/uli/r8a7796-gpu.git`, commit
  `b4b8d1938bafb4889b3c285978de5c14981309bc`. Its kernel-only headers omit the
  user-space CDM stream/base registers; they did not establish those addresses.
  The register correction came from hardware fault controls 40/41, not that repo.
- Host tests: four for `disasm.py`, ten for `gpu_evidence.py`, thirteen for PDS
  probe plans/reference comparisons (**27 passing**). The latter compare with
  unmodified local Mesa C encoders/disassembly and XML, not hardware compatibility.
  Probes 50–54 were subsequently hardware-tested and did not complete. C reference
  checks now also include LIMM 0xd1804d5c, ST 0xd0800000 and WDF 0xd1000000 used
  by the store probes. All shell scripts pass host
  syntax checks. `serial_get.py` has been exercised with SHA-256-verified binary
  transfers, but has no unit tests yet.
- All project changes remain uncommitted. Outputs, Mesa reference source and
  firmware are ignored; the Markdown notes preserve the interpretation when
  those local artifacts are unavailable.

## Grid dispatch (2026-10-30; `out/ios-grid/`, `session.py grid`)

`capture.m --grid` dispatches a kernel that reads its IDs twice in one
encoder: 3 groups of 8×1 threads (A) and 5×2 groups of 4×2 threads (B).

- **CDM kernel record:** `0x2103, data 0x2380, code 0x2300`, then the group
  counts minus one (A `2, 0, 0`; B `4, 1, 0`), then word 6 = `1` and word 7 =
  `0x00700000`. Both dispatches have 8 threads per group, so word 7 reads as
  threads − 1 in bits 20+; the one-thread record has `0x40000000, 0` there.
- **Binding task (record 0):** three DOUTDs into the common store:
  dwords 0–1 = buffer VA, dwords 4–8 = five dwords of the argument-table
  entry, dwords 9–10 = groups per grid (x, y).

| Common store | A | B | Reading |
|---|---|---|---|
| dw4 | `00080008` | `00080008` | threads per group, both halves |
| dw5 | `7fff0002` | `7fff0002` | ? |
| dw6 | `7fff0002` | `7fff0001` | ? (differs with the group shape) |
| dw7, dw8 | 8, 1 | 4, 2 | threads per group x, y |
| dw9, dw10 | 3, 1 | 5, 2 | groups per grid x, y |

The layout is per pipeline (the compiler places what the kernel uses), so it
is a driver–compiler contract that our compiler defines for itself. The
hardware side, from offline-compiled kernels (`probes/grid.metal`):

- r0 holds the thread's index in its group at entry
  (`o[0] = thread_index_in_threadgroup` is a plain store of r0).
- The program prologue `1181 01uu 4100 acb7` compares the uniform thread
  count (u4 = dword 2 low with one buffer, u8 in the grid kernel) with r0 and
  masks the excess lanes; the one-thread binding's `0x10001` is that count.
- The threadgroup ID is read with `2314 0rr0 8100 0200` (x) and
  `… 8101 0200` (y): a load from another space at 0x200.

### Thread and group IDs on Linux (2026-10-30, `pvr-compute-test GRID=… CDM_K6/K7=…`)

- **Thread index works.** With the thread count in common-store dword 2
  (both halves) and kernel record word 7 = (threads − 1) << 20, Apple's
  `o[l] = l` kernel writes every index for groups of 1, 5, 8, 32 and 128
  threads, and the prologue masks the non-power-of-two group.
- **`2314 0rr0 81oo 02hh` is a threadgroup-memory load** at word offset
  `hh:oo` (`probes/tgmem.metal`: `t[1]` → `8102 0200`, `t[1000]` →
  `81e9 0203`; user arrays start one word in). Barriers compile to atomic
  loops on threadgroup memory (`1314 … 2200`). Metal's
  `threadgroup_position_in_grid` is threadgroup word 0 (x) and 1 (y).
- **Kernel record word 6, low bits = threadgroup memory allocation.** With
  them 0, a threadgroup load does not write its destination register at all
  (a preset register keeps its value). With 1 or 2, the load returns
  uninitialized contents (`0x8147f2dc`, …, different per run). Bits 29–31
  change nothing here. iPadOS uses word 6 = 1 for the grid kernel.
- **Open: who writes the group ID into threadgroup word 0.** The PDS kernel
  task is identical to iPadOS's (`c2c00002 d3000000 f0000a01 fc000002
  d3000000`, data `{USC offset, 0x10, 0x80000000, 0}`); its DOUTW
  (`f0000a01`, control `0x80000000`) is the likely writer. On Linux the word
  stays uninitialized. Item mode (`0x4c8` = 0, 2, 3 via the experimental
  `apple_cdm_regs` parameter) changes nothing.
- Pitfall: r0 holds the thread index at entry, so a kernel whose load does
  nothing can look as if it read 0. Earlier "group ID passes" were this.

### Group IDs work (2026-10-30 late; `pvr-compute-test` env options)

Apple's compiled `o[g] = g` (`threadgroup_position_in_grid`) passes for
1×8 up to 1024×1, 1000×7, 256×16, 64×64 and 32×128, with this setup:

- **Kernel record word 6** = `(threads per group mod 32) << 27 |
  threadgroup allocation` (allocation ≥ 1 when the kernel uses threadgroup
  memory, which the group ID lives in). With any other value in bits
  27–31, groups alias each other's threadgroup memory or are lost. iPadOS's
  values (`0x40000000` for one thread, `1` for 8 threads) do not follow this
  rule; they may rely on state we do not set.
- **Word 7** = `(threads − 1) << 20`.
- **PDS program** (our own, Rogue-style; Apple's halts in the coefficient
  task):

  | # | Word | Meaning |
  |---|---|---|
  | 0 | `c2c00004` | BRA to 4 unless IF1 (IF1 = coefficient-sync task, once per group) |
  | 1 | `f4001201` | DOUTW temps q0 (workgroup ID x) with control data dword 4 = `0x90000000` (last, common-store destination, offset 0) → threadgroup word 0; END |
  | 2–3 | `d3000000` | HALT |
  | 4 | `f0000a01` | DOUTW temps q0 (local ID) → r0 (control dword 2 = `0x80000000`) |
  | 5 | `fc000002` | DOUTU (data q0: USC offset, temps) |
  | 6 | `d3000000` | HALT |

  K0's PDS data-size field (bits 2–7) must be ≥ 1 once the data goes past
  dword 3 (`0x2103` → `0x2107`); otherwise the extra words read as garbage.
- **Stream end:** a kernel record followed directly by the terminate loses
  its last groups (1–12, job completes normally). Two to four records
  between kernel and terminate fix it (the test inserts copies of the
  binding record; iPadOS appends four Metal-internal records). Open: the
  proper record.
- **Apple PDS DOUT encoding** (differs from Mesa's Rogue layout): bits 0–2
  type (0 DOUTD, 1 DOUTW, 2 DOUTU), 3–7 64-bit source register, 8–9 source
  space (0 data, 2 temps), 10–15 control word's data dword; bit 26 END,
  bit 27 CC. In normal tasks the even temp pairs hold the local IDs of the
  task's instances (q0 = local, q2 = local + 1, …); workgroup IDs exist only
  in the coefficient task.
- The USC common store holds 16 dwords by default (binding loads past dword
  15 break the job). Uniform operand indices count 16-bit halves.
- **y and z** (2026-10-31): the DOUTW control's low bits are Rogue's BSIZE
  (0 lower 32 bits, 1 upper, 2 all 64), so `0x90000001` copied the upper
  half (y) into word 0. 2D: one DOUTW of temps q0 with `0x90000002` →
  words 0–1. 3D: `c2c00005`, DOUTW q0 ALL64 (control `0x10000002`, not
  last), DOUTW q1 UPPER = workgroup z, temp 3 as in Mesa (`f4001609`,
  control dword 5 `0x90004001`: last, offset 2) → word 2. Apple's `gid2` /
  `gid3` kernels pass on 16×4, 16×16, 16×4×3 and 16×4×8 grids.
- Open: 16 groups × 256 threads fails.

#### Caveats of the group-ID setup (keep until resolved)

- **Trailing records: superseded** by the iPadOS-style fence tail for
  fast kernels (see "How iPadOS ends a compute pass"); slow kernels still
  lose work. Tried and ruled out (2026-10-31):
  the Rogue fence bit on a single trailing record (K0 = 5 or 7: 64×64 still
  loses ~4 groups, same as K0 = 4); block type 3 (`0xc0000003`, as iPadOS
  uses) with our DMA program kills the whole job. The number of plain
  records needed grows with the group size (64×64 needs 2), so they act as
  delay. Our microsequence matches iOS 17's apart from its begin/end
  timestamp ops (opcode 3, `FUN_fffffff006049284`). Rogue's `USC_TARGET` is
  0 = all clusters, 1 = any: our binding K0 = 4 targets all, iPadOS's K0 = 6
  any (an earlier note here had this reversed).
  Before: The test puts copies of the binding
  (DMA-only) record between kernel and terminate. iPadOS appends four
  Metal-internal records instead (`K0=4`, `K0=2`, `0xc0000003`, `K0=3`;
  their PDS code lives in a heap our captures miss). Which of them is the
  real fix, and why the terminate drops the last groups, is unknown.
- **iPadOS breaks our word-6 rule.** It uses `1` (8 threads) and
  `0x40000000` (one thread), which would alias or drop groups on our setup.
  It probably sets state elsewhere (kernel-built compute command, firmware
  init) that we do not, so the rule may be a workaround for that state.
- **Resolved: our PDS program matches Apple's mechanism.** Apple's
  `EncodeComputePDSProgram` writes the workgroup IDs in the coefficient task
  the same way; the program I first took from the grid capture was not that
  kernel's.
- **Not yet verified:** groups of 256 threads (16 × 256 fails), dispatches whose groups use real
  threadgroup arrays next to the ID word.
- **Rare whole-job failures** (about 1 in 300 runs) were a full firmware
  event ring after 255 jobs; fixed, see "the rare hang was a full firmware
  event ring" below.
- **Scaffolding:** the experimental `apple_cdm_regs` module parameter
  (StartCompute register list) is removed; `0x4c8` item mode had no effect
  on group IDs.

### How iPadOS ends a compute pass (2026-10-31, `AGXMetalA10` + device tests)

From the iPadOS Metal driver (`AGXMetalA10`, symbols intact, Ghidra
decompile of `AGX::ComputeContext<G9>::endComputePass` / `encodeBarrier` and
`AGX::DevicePDSStateLoader<G9>::setup`):

- `endComputePass` calls `encodeBarrier`, then writes the terminate
  `0x80000000`. `encodeBarrier` copies precomputed 32-byte CDM records
  built once at device setup: a shader-constants DMA record (K0 = 4,
  `EncodeShaderConstantsPDSProgram`), a one-thread barrier kernel (K0 = 2,
  driver shader token 39), then block-type-3 record, fenced one-thread
  kernel (K0 = 3, token 38), block-type-3 record. The driver shaders are
  generated by the compiler from the token; their code is not in either
  binary. Internal records use word 6 = `0x40000000`, word 7 = 0
  (template at `0x21c877eb0`).
- `PDSEncoderGen1<G9>::EncodeComputePDSProgram` writes workgroup IDs in the
  coefficient task exactly as our program does (DOUTW temps, control
  `0x90000000 | offset << 13 | size`, z from temps q1 upper), switched by a
  flags byte in its arguments. So our PDS program follows Apple's mechanism;
  the program first identified in the grid capture was not that kernel's.
- Apple's PDS fence program is `c2c00002 d3000000 f0000005 d3000000`
  (`f0000005` = DOUTC, Mesa's compute fence; found in the grid capture).
  Rogue's K0 fence bit means "wait for the fence acknowledgement from the
  USC", which a record only gets from a DOUTC.

Device results:

- **The lost last groups are cut, not cached.** Losses are deterministic per
  grid (64×64: 10, 64×32: 7) and grow with per-group run time (64×64: 10 at
  1–30 loop iterations, 25 at 60, 51 at 100). A device-memory flush
  instruction in the kernel (`c330 0100 0900 1000`, from
  `threadgroup_barrier(mem_device)`) changes nothing.
- **iPadOS's tail order fixes fast kernels:** `[0xc0000003 + fence program]
  [K0 = 3 + fence program] [0xc0000003 + fence program]` before the
  terminate: 64×64 and 256×16 lose nothing (`TAIL_FENCE=3 TAIL_FENCE3=1`).
  A single fenced record, a fenced DMA record or an empty kernel do not.
- **Slow kernels still fail, differently:** with 300 loop iterations per
  thread, 64×64 writes nothing at all (not even group 0), small grids pass,
  and the context-state buffer stays zero (no context store). The driver
  sees no timeout: the firmware reports the job complete. It is erratic, not
  a stale latched event: the first job after a fresh module load can lose
  everything while the second identical job passes, or lose only groups
  36–63.
- **Firmware trace (2026-10-31):** `COMPUTE_FINISHED` (event 4) arrives
  ~0x190 ticks after StartCompute for fast and slow jobs alike, with or
  without the fence tail, so it marks the end of CDM issue, not of the work.
  FinalizeCompute follows at once. No other event serves: waiting on bit 0,
  1 or 15 instead never completes (driver timeout).
- **Results only become visible after FinalizeCompute:** with a wait that
  never fires, even fast kernels' output never reaches memory, so Finalize's
  `0x1720 = 0x13` step is likely the GPU cache (SLC) flush. Groups that
  finish after Finalize leave their writes in the cache. A second job (its
  Finalize flushes) sometimes rescues the first job's output; erratic.
- **Faithful iPadOS tail replica** (`TAIL_APPLE`: empty kernel K0 = 2,
  type-3 DOUTC block, fenced empty kernel K0 = 3, type-3 DOUTC block;
  Apple's barrier kernel, driver shader 39, *is* the empty kernel per the
  grid capture) fixes fast kernels, not slow ones; shader 38 (the fenced
  kernel's code at USC `0x28000`) was not in the capture.
- **A fenced record holds the CDM until its own task finishes**
  (`SPIN_USC`: the fenced K0 = 3 tail kernel spins N iterations): the slow
  64×64 kernel loses 47 groups with the empty fenced kernel, 13 with a 100k
  spin, none with a 1M spin. So `COMPUTE_FINISHED` (and Finalize's flush)
  comes after the fenced tail task, and iPadOS's driver shader 38 (the
  fenced kernel) must wait until all earlier work has drained. iOS also
  waits on event 4 (RENDER.md), so the wait mask is not the difference.
- **Open:** what shader 38 does to wait for the drain (one instruction? a
  counter?). Its code (USC `0x28000` of the internal heap) is not in the
  grid capture; a capture of that heap would show it. Fallback without it:
  every kernel increments a device counter per group and the fenced tail
  kernel spins until it reaches the group count.
  Pointing the Start/Finalize flag at the command +0x2c4 like iOS changed
  nothing. Experimental module parameters `apple_cdm_regs` and
  `apple_compute_wait` are scaffolding to remove.
- `FinalizeCompute` (fw op 0xc) stops the CDM (`0x688 = 4`) on its normal
  path unless a flag word (microsequence args [0xe]/[10]; iOS: command
  +0x2c4) is set; pointing ours at the job's command +0x2c4 like iOS changed
  nothing (kept, matches iOS).

### Driver shader 38: `c401` (2026-10-31, `out/ios-grid2`)

The fenced kernel of iPadOS's compute pass ending is a single instruction:
`c401`, then the standard jump to the end word (`0100 013e 0000`, `c000`
padding, `8000` at +0x40). It sits in the internal code heap chunk at GPU
`0x28000` (R7), whose CPU mapping is region `0x799fc8000`, not
`base + 0x28000`: the heap's chunks are mapped non-contiguously, which hid
it. GPU code memory cannot be read back through the data path (a peek kernel
faults on GPU `0x0`, `0x14000`, `0x28000`), but the chunks are CPU-mapped in
the process. `c401` is presumably "wait until all earlier USC work has
completed"; to be confirmed on Linux as the fenced tail kernel.

#### Shader 38 on Linux (2026-10-31)

`TAIL_APPLE=1 SPIN_USC=shader38.bin` runs `c401` as the fenced K0 = 3 tail
kernel. Alone it changes nothing. What makes the fence hold is the K1 low
bits iPadOS sets (`TAIL_APPLE_K1=MASK`, per record):

| Mask (records with iPadOS's K1 bits) | Result (64×64 fast / slow) |
|---|---|
| none | fast pass, slow loses groups |
| 4: fenced `c401` kernel K1 `| 4` (SD type PDS) | **both pass**, no timeouts |
| 2 or 8: a type-3 DOUTC block K1 `| 4` | job never completes (driver timeouts) |
| 1: barrier kernel K1 `| 2` | slow loses groups |

Over a matrix (4 kernels × 64×64 and 256×16 × 3 runs), mask 4 and mask 5
pass most runs, including 300-iteration kernels that never passed before,
but not all: some runs lose one or a few groups, and some lose everything.
Open: whether the rest of iPadOS's tail (the K0 = 4 shader-constants DMA
record, the type-3 blocks' data contents) closes the gap, and how much of
the remainder is the known rare hang.

Matrix with per-run timeout counts (mask 4, 4 kernels × 64×64 / 256×16 ×
3): two failure kinds remain. **Hangs** (all groups lost, driver timeout):
2 of 24 runs, any kernel, probably the known rare hang. **Partial loss**
(1–26 groups, no timeout): only the slow kernels (300 / 3000 loop
iterations), so the `c401` fence still sometimes releases early. Running the
fenced record on all clusters (K0 = 1 instead of 3, `TAIL_FENCE_K0=1`) does
not help and hangs more often.

Tried 2026-10-31, no effect on its own: iPadOS's first tail record (K0 = 4,
K1 `| 0xa`, code `f0000800 f4000012 d3000000`, data `{0x1_00000100,
0x90000004, 0, 0x14280, 0x10}`, built by `EncodeShaderConstantsPDSProgram`)
loads 4 constant dwords into the common store and kicks a cache-flush
kernel at USC `0x14280` (`out/ios-grid2/flush37.bin`: `c310 0100 0100 1000`,
wait, `c310 0100 0100 1000`, `011c b800`, wait, exit; `c310` is a sibling of
the `c330` device-memory fence). A peek on iPadOS shows the 4 constants at
GPU `0x1_00000100` are all zero (`TAIL_APPLE_FLUSH`, `FLUSH_ADDR`
overrides).

### Resolved: `c401` was the hang; the type-3 blocks close the race (2026-10-31)

**Method correction.** pvr-compute-test used to poll only the last output
element (up to 3 s), then check the rest 10 ms later. It never waited for
the job, so slow kernels' "lost groups" were partly groups still running,
and "no timeout" only meant dmesg was read too early. `FENCE_WAIT=1` now
attaches a syncobj signal operation to the job and waits on it (10 s)
before checking. All results below use it, and they replace the matrix
numbers above.

**Firmware traces of failing runs** (SKU ring, one snapshot per job): every
job that lost all groups shows StartCompute and then the firmware's idle
checks (0x112 ×3, 0x101), but no COMPUTE_FINISHED and no FinalizeCompute.
The GPU stays wedged: every later job times out until the module is
reloaded. In the old matrix this looked like "the third job after a module
load fails", because the matrix reloaded after every failure.

**Sequences of 8 jobs after a fresh module load** (`gv_s1`, 64×64):

| Tail | Result |
|---|---|
| none | job 1 loses groups, the GPU wedges at job 2 |
| iPadOS tail, empty fenced kernel | 8/8 |
| iPadOS tail, `c401` as fenced kernel | wedges after 2–7 jobs |
| any K1 mask, `c401` | wedges, at the first job when a type-3 block is flagged |

So driver shader 38 (`c401`) is what hangs the GPU here, not the
type-3 blocks' K1 bits. Whatever `c401` waits for, our jobs don't provide
it. It is left out.

**Working configuration:** `TAIL_APPLE=1 TAIL_APPLE_K1=0xf`. That means the
four records of iPadOS's barrier (empty kernel K0 = 2, type-3 DOUTC block,
fenced empty kernel K0 = 3, type-3 DOUTC block) with iPadOS's K1 flags on
all four (`|2`, `|4`, `|4`, `|4`), an empty kernel in place of shader 38, and
no constants/flush record. Results with `FENCE_WAIT`, 4 kernels (1 to 3000
loop iterations per thread) × 64×64 and 256×16, stopping at the first
failure:

| Tail K1 mask | Jobs | Result |
|---|---|---|
| `0xf` | 200 + 200 | all pass, fence in 1–3 ms |
| `0xf`, barrier `|0xa` as on iPadOS, type-3 data zeroed | 200 | all pass |
| `0xe` (barrier unflagged) | 80 | all pass |
| `0xa` (only the type-3 blocks flagged) | 80 | all pass |
| `4` (only the fenced kernel flagged) | 8 | slowest kernel loses 1–6 groups in some jobs |

The K1 low bits are flags on the 16-byte-aligned PDS data address (iPadOS:
`|0xa` on the constants record and the barrier kernel, `|4` on the type-3
blocks and the fenced kernel, `|2` on the grid kernel's constants DMA
record). The `|4` on the type-3 blocks is what makes the fence wait for all
earlier work. iPadOS's type-3 blocks point at zeroed data; ours point at
the kernel launch data, and both work. The 19 ISA test kernels
(`tools/isa/gen-tests.py`) pass with this tail.

### Resolved: the "rare hang" was a full firmware event ring (2026-10-31)

With the tail fixed, an 800-job run hung at job 256, and 300 fast jobs after
a fresh module load hung at job 256 every time. The firmware posts an event
per completion into its event ring (heap `0x57000`: host consumer index at
+0x00, firmware producer index at +0x20, 256 entries of 0x24 bytes from
`0x58000`), and before posting it spins while `producer + 1 & 0xff ==
consumer` (fw decompile around 0x98d2). The driver never advanced the
consumer, so after 255 events the firmware spun forever and took no further
work. This is the earlier "rare hang (~1 in 300)": it came from the number
of jobs since module load, not chance.

Two driver fixes (in the GPU kernel patch):

- The poll work acknowledges all events (consumer = producer). Completion
  still comes from the stamps.
- Work-ring producer indices and each work entry's command-ring head
  (+0x10) are written modulo 256. The firmware advances its consumer
  `+1 & 0xff` and scans while it differs from the producer (fw `0x1ff88`),
  and the command rings have 256 entries (queue state +0x50), so an
  unwrapped sequence number never matches after the first wrap.

Results: 700 sequential compute jobs pass. 300 renders interleaved with 300
compute jobs pass, both with the fast kernel and with the slowest one
(`gv_e3000`, 256×16), with no timeouts or firmware crashes. The scaffolding
module parameters (`apple_cdm_regs`, `apple_compute_wait`) are removed; the
per-job Start/Finalize flag at command +0x2c4 stays.

### Job construction: `tools/g9p-cdm.h` (2026-10-31)

Compute jobs are now built from decoded fields instead of hex words, by a
header-only encoder that Mesa's compute job construction can reuse:

- **PDS instructions:** `g9p_pds_dout(type, src64, space, ctrl, END|CC)`,
  `g9p_pds_halt()`, `g9p_pds_bra_not_if1(target)`.
- **CDM records:** `g9p_cdm_task()` (one-thread internal records),
  `g9p_cdm_dma_task()` (common-store DMA, word 6 = `0x40000001`),
  `g9p_cdm_kernel()` (workgroups minus one, word 6/7 from the group size).
  K0 fields are `G9P_CDM_FENCE` (bit 0), `G9P_CDM_ANY_CLUSTER` (bit 1),
  `G9P_CDM_DATA_BLOCKS(n)` (bits 2–7), `G9P_CDM_KERNEL_SIZES` (`0x2100`,
  observed only) and the block types (fence block 3, terminate 2).
- **End of a compute pass:** `g9p_cdm_end_pass()` writes the four records
  and the terminate (33 words). It takes the offsets of the device-level
  programs (`g9p_pds_kick_program()`, `g9p_pds_fence_program()`,
  `g9p_pds_kick_data()`, `g9p_usc_empty_kernel()`), which a driver places
  once per device, as iPadOS's `DevicePDSStateLoader` does.

Each field is marked in the header as **decoded + tested**, **observed**
(iPadOS's value, meaning open) or **Rogue** (meaning taken from PowerVR
Rogue, untested here). The encoder reproduces the hand-written words of all
earlier experiments word for word.

`pvr-compute-test` builds every job with it. The end-of-pass records and
the fence wait are now the default (`NO_TAIL`, `NO_FENCE_WAIT` turn them
off). The superseded experiment options `TAIL=N`, `TAIL_K0`, `TAIL_FENCE`,
`TAIL_FENCE3`, `TAIL_KERNEL`, `CDM_ROGUE`, `PDS_Q3`, `PDS_GID_INSN`,
`TAIL_T3_ZERO` and `TAIL_APPLE` (now always on) were removed. They are in the
git history before this change, if an old experiment needs repeating. The
fence blocks read zeroed data, as on iPadOS. The tool's header comment
lists the remaining options.

The `store_marker` shader in the driver's self-test and in the tool is no
longer Apple-compiled output. It is written as annotated instructions from
the decoded encodings (`tools/isa/g9p.py store_kernel(0x1357)` emits the
same words, which are identical to the compiler's).

**Next steps:**

1. Done in the test tool (`tools/g9p-cdm.h`). For Mesa: emit
   `g9p_cdm_end_pass()` at the end of each compute pass and place the
   device-level programs once per device in the PDS/USC heaps.
2. Open: what `c401` (driver shader 38) waits for. It may depend on the
   constants record or on other device state that iPadOS sets up. Not
   needed for correct completion so far.
3. Events are only acknowledged. Using them for completion instead of
   polling the stamps is a later improvement.
4. Hang recovery: a malformed PDS program from userspace (seen with a
   mistyped DOUTU in place of a DOUTW, 2026-10-31) wedges the GPU; every
   later job times out until the module is reloaded. A Mesa bug will do the
   same, so the driver needs to reset the GPU/firmware after a job timeout.

Soak (2026-10-31, `TAIL_APPLE_K1=0xf`, fence wait): 79,860 compute jobs (4
kernels, 64×64 and 256×16) interleaved with 13,310 renders in 23 minutes,
all passed, no timeouts; this crosses the 256 ring wraps many times and the
65,536 mark.

### Register allocation: K0 bits 12-17 (2026-10-31)

Kernels using registers above r8 wrote nothing with iPadOS's K0 `0x2107`.
Bits 12-17 of K0 are the per-thread register allocation: field 2n gives 8n
registers. Tested with kernels whose highest register (pair plus mask
stack) is r8 … r32, `KERNEL_K0` varied (the DOUTU's second data word has
no effect):

| K0 bits 12+ | Highest register that works |
|---|---|
| 1, 2 | r8 |
| 3, 4 | r16 |
| 5, 6 | r24 |
| 8 | r32 |

iPadOS's `0x2100` is field 2 (its kernels stay within r0-r7, using 16-bit
half registers where they can). `tools/g9p-cdm.h` now has
`G9P_CDM_KERNEL_REGS(n)`; compilers pass their register count.
