# A8 GPU bring-up on the iPod touch 6: power-up to first triangle

From a cold SoC to jobs running on the GPU under Linux, in the order the driver does it. The A8's GPU
firmware and interface are the A9's (G5P) family; what follows is mostly what is *different*, and the
traps we hit. Evidence tags as in [README.md](README.md#evidence-levels): **[HW]** measured on Linux on the
device, **[iOS]** measured under iOS on the device, **[KC]** read in the iOS 12.4 kernelcache or firmware
image (Apple functions by unslid address), **[INF]** inferred.

## 1. The device

- **[iOS]** iPod7,1 (N102), T7000, ~1 GB RAM, iOS 12.4. GPU: PowerVR GX6450 class, BVNC 3.10.4.5, four
  clusters. Apple's kext is `AGXG4P` (class `AGXAcceleratorG4P_B0`), the Metal driver `AGXMetalA8`.
- **[iOS]** The kernel page size is 4 KiB (`vm.pagesize`), so Linux runs the 4 KiB-page kernel and the GPU
  MMU uses 4 KiB pages (the A9 uses 16 KiB).
- **[iOS]** Device tree: `gpu,t7000`. R0 (the Rogue registers) at `0x201000000` and R1 (Apple's power
  block, "Fender") at `0x201e00000`, 1 MiB each, IRQs 134-138, PMGR device 0x7c for both clock and power
  gating. The firmware interrupt is IRQ 138.
- **[iOS]** Three performance states, 365, 450 and 500 MHz, plus a second set at half those clocks whose use
  is unknown. The per-device voltages are fused and differ between units; they are not listed here.
- **[KC]** `readChipInfo` (`0xfffffff008479d14`) accepts core revision major 3 with minor 8 or 10.

## 2. PMGR: what must be on before the GPU's PLL locks

Every Rogue register access (R0) hangs the **whole SoC** if the GPU PLL is not running. On the A8 that PLL
never locked under Linux until two global PMGR bits were set that iOS sets in `ApplePMGR::start`.

- **[KC]** On iOS 12.4 the PMGR writer is `AppleT7000PMGR` (`0xfffffff0084a9814`, base init
  `0xfffffff00849b508`). `AppleT7000PerformanceController` has no live instance on the iPod, so its
  bring-up function is not what runs. In order, iOS:
  1. sets PLL1/PLL4 `+8` bits 31:30 to 01;
  2. sets bit 31 in a list of power-gate block words from `P+0x22000` (`0xfffffff0084a9db8`);
  3. initialises devices and performance tables;
  4. sets **MISC_ACG** `P+0x32000` bit 0, global automatic clock gating (`0xfffffff00849d1bc`);
  5. enables the voltage manager (`0xfffffff0084a9e58`);
  6. for the device-tree feature `soc-tvm`, sets **SOC_TVM** `P+0x2d000` bit 0 (`0xfffffff00849d340`);
  7. adjusts the CPU complex's voltage and control bits.

  (`P` = PMGR base `0x20e000000`.) LLB and iBoot clear `P+0x22000` bit 31 on every boot **[KC]**; on a
  Linux boot through the bootloader chain MISC_ACG, SOC_TVM and that word all read 0 **[HW]**.
- **[HW]** **MISC_ACG is what makes the GPU PLL lock on the A8.** With it set, the first lock came 174 µs
  after the GPU power request, with the same lock sequence as iOS; two earlier boots without it never
  locked. The store was first found on the A8X (J81), where it made the PLL lock on Linux
  ([../../a8x/MISCACG-PAGE5.md](../../a8x/MISCACG-PAGE5.md)); there it was stored after the GFX power cycle and the
  bridges, and the core-ID read still hung. On the A8 we set it in Apple's order, **before** PS_GFX is switched on,
  together with SOC_TVM, and the core-ID read returns.
- **[HW]** Setting SOC_TVM immediately raises the SRAM rail code: the SOC_TVM block drives it. The driver sets
  both bits. Removed one at a time, these were **not** needed for the core-ID read: the PLL1/PLL4 bits,
  `P+0x22000` bit 31 and the rest of that block, and fabric minimum states. Whether MISC_ACG alone (without
  SOC_TVM) is enough on a fresh boot was not tested **[INF]**.
- **[HW][iOS]** The GPU PLL is PMGR page 5 (`P+0x5000`). Lock is `+4` bit 30 together with `+0x18`
  reaching its final value; `+0` bit 31 is not a lock bit (it stays clear while locked under iOS). Software
  never enables this PLL: the GPU DVFS sequencer drives it. The request word `P+0x1c200` has bit 31 (table
  enable), bit 30 (busy; its clearing is the only "done" signal) and the requested state in bits 11:8.
- **[iOS]** Under iOS, request to lock takes a median 142 µs and request to done 263 µs; a request with the
  PLL still unlocked is a normal transient state. iOS never reports done without lock.
- **[HW]** Before MISC_ACG the symptom was clean but confusing: the request lands, the GPU rail moves, the
  sequencer reports done, and the PLL never locks.
- **[KC][iOS]** Closed as non-causes: the DVFS table contents and its enable bit (identical in iOS and Linux),
  various PLL status bits that toggle in iOS, the PS registers of unrelated blocks next to GFX. The boot
  firmware never touches `0x201xxxxxx`.

### PMGR PS register layout [KC]

Bits 3:0 target state (0 off, 4 clock-gated, 0xf on), 7:4 actual state, 8/9 history (was power/clock
gated), 10 device disable, 19:16 minimum state, 27:24 current auto-PM state, 28 auto-PM enable (must be
clear before a manual change), 31 reset. GFX is bank 3 index 4, `P+0x20320`; it has no parent in the device
tree and owns bridges 10 and 11, the only bridges on the CPU-to-GPU path.

## 3. The power-up sequence

As flown in the probe module first and then ported into the driver **[HW]**:

1. check that the GPU performance table records are valid;
2. MISC_ACG |= 1; check that the voltage manager is on; SOC_TVM |= 1; settle;
3. PS_GFX: clear auto-PM (bit 28) if set, clear the history bits, target 0xf, poll actual (7:4) = 0xf;
4. the 33 bridge stores for bridges 10 and 11, as Apple's pre-ID path does **[KC]**;
5. Fender wake: `R1+0x10000` = stream end, `R1+0` = `0x40000000`, `R1+0x1000` = `0x11` (state 1), poll bit 4
   clear;
6. the R0 gate (below), then the core-ID read.

- **[HW]** The core-ID read is a 32-bit pair: `R0+0x20` (revision, `0x00030a00`) and `R0+0x18` (ID,
  `0x011b0405`). The 64-bit PBVNC read is not used.
- **[HW]** The R0 gate (`t7000_r0_gate`): Fender in state 1 **and** PLL `+4` bit 30 set, checked before any R0
  access. It is a check-then-access, not a lock against firmware DVFS **[INF risk]**.
- **[HW]** Never read the bridges or any `0x201xxxxxx` word with the GPU gated.
- **[INF]** The first driver probe froze the SoC (the module had worked). The driver ran the module's steps
  with none of its time gaps (about 100 µs where the module had about 100 ms). The driver now settles after
  the first rail enable, leaves gaps between steps and waits for sequencer done, a stable rail and PLL lock
  before R0; later probes pass **[HW]**. The fix was never isolated with a negative control.
- **[KC]** Apple's pre-ID path also does `PS` target 0xf, the bridge stores, three Fender writes and an
  unbounded bit-4 poll before `R0+0x20`/`+0x18`. A "Fender bit 29 ready" check that looks like a power-on guard
  is Apple's power-*off* quiescence check.

## 4. Firmware boot

- **[KC]** The firmware is a META LDR image (labelled `g4p_b0`) using the A9's loader, VA windows, rings,
  event format, channel headers and microsequence opcodes. Differences are sizes, register choices, counts and
  the parameter-manager layout. The image is 0x24000 bytes; the handover word is at `+0xff8`. The A8 image has
  **no META core-memory section** (its stacks live in normal data); the A8X image does, like the A9's.
- **[KC]** Object sizes: INIT 0x1118, POLICY 0x1058, PLATFORM 0x4dc, CONTROL 0x1528, ring control 0x30 (the A9's
  is 0x20). PLATFORM carries 16-entry MHz/mV arrays and `+0x280` = 24000 (the timer period in 24 MHz ticks).
  The kernel copies a chip-info record `{2, 4, 0, 4}` into PLATFORM `+0x300..+0x308`.
- **[KC]** MMU: classic Rogue BIF, `BIF_CAT_BASE0` (`0x1200`) + 8 × context = page catalogue (the A9 uses its
  XE MMU registers at `0xe140`/`0xe148`). Cache: `SLC_CTRL_MISC` (`0x3800`) = `0x200001` and `0x3808` = 1, nothing
  else: no SLC3, no scramble, no spare page.
- **[KC][HW]** Hardware objects the firmware needs: a YUV CSC table, the BRN44455 workaround, the border-colour
  table and a fence buffer, at `0x8_00000000` + {0, 0x4000, 0x8000, 0x10000}, named in PLATFORM. They need plain
  mapping flags; the PM/META-protect flags stop the alive event **[HW]**. The border-colour table (0x800 bytes)
  is kext data; the firmware recipes ship it as a second file next to the LDR image
  (`apple/gfx-t7000.bin`, `apple/gfx-t7000-border.bin`), extracted on the user's machine from Apple's IPSW.
- **[KC]** The border-colour table's address >> 2 goes to `R0+0x1790`/`0x17a0`/`0x17a8`; the fence buffer to
  `R0+0x1740` (`MCU_FENCE`).
- **[HW]** Boot to the alive event, the device-control ring and the slot load worked from the first module stage.
- **[KC]** CONTROL `+0xcd0..+0xcd8` are performance-controller inputs, zero in Apple's live CONTROL; leave them 0.

## 5. Rings, doorbell and the job path

- **[KC]** Kick values for the MTS register `R0+0xb00`: TA 0x10, 3D 0x11, compute 0x12 (DM2; the A9 kicks compute
  on DM0), device control 0x10.
- **[KC]** Apple's kick (TA `0xfffffff00846f220`, 3D `0xfffffff00846f408`, compute `0xfffffff00846f5f0`, DC
  `0xfffffff00846f9a0`): write the work ring, barrier, Fender wake (`R1+0x14` = 7), read the Fender state without
  waiting, then write the MTS **unconditionally**. It restarts the firmware first only from state 0 with the
  firmware stopped. It never looks at the GPU PLL.
- **[HW]** An earlier driver gated the doorbell on PLL lock. After about 92 000 jobs a doorbell found the PLL
  relocking and was refused with `-EIO` *after* the ring entry was written; the firmware ran the job anyway after
  its fence had failed, and the 3D faulted on a freed buffer. Fix: check every refusal before any ring or VM
  state moves (a failed submit changes nothing), and ring in state 1 with the PLL relocking, as Apple does.
  Flown: 514 000 jobs, no fault.
- **[HW]** The firmware self-parks the core between jobs (Fender state 0 on 1.4-22 % of doorbells depending on
  load); an idle doorbell from state 0 works and the PLL relocks within 1 ms.
- **[KC]** Context slots: 8 BIF slots, users from slot 1, one slot per VM, so at most 7 user VMs (an 8th gets
  `-EBUSY`). The A9 has 256 slots, users from 7, a pair per VM.
- **[KC]** Job records follow the A9's with a zero u64 inserted early (TA at `W+0x20`, compute at `W+0x10`),
  so later fields move by 8. Sizes: TA 0x568, 3D 0x8b0, compute 0x298 (A9: 0x560, 0x8c0, 0x290). The 3D start
  opcode takes 23 arguments (A9: 20). The TA `TE_PSG` word is `0x22000` (A9 `0x20000`); the compute terminate
  word is `0x00900004` (A9 `0x00a00004`).
- **[KC]** The 3D job waits for its TA inside the firmware: a barrier command (TA finish stamp, value, job
  number) is queued before the 3D record.
- **[HW]** Completion is the finish stamp, IRQ-driven with a 250 µs poll and a 20 µs recheck. Root memory is
  CPU write-combined; stamps go through META's uncached window.
- **[HW]** On a job deadline (5 s) the driver does **one** gated read of `EVENT_STATUS` (`R0+0x130`) and, if
  bit 9 (MMU fault) is set, one read of the BIF fault banks (`0x12b0`..`0x12c8`). Polling those registers during
  a live job froze the SoC. A fault in the job's context can leave the firmware silent for 1.5 s, so the host
  must read the banks itself.
- **[KC]** The type-4 event is the firmware's lockup recovery (a watchdog arm and an MMU-fault arm), not a record
  validation; an early "every TA is rejected after 0.46 ms" was this event reporting our own faults.
- **[HW]** Region state was a 4-entry round-robin per VM; with more than four render-target datasets in flight
  one was evicted and its jobs refused, which also inflated fps. It now lives as long as its dataset.
- **[HW][INF]** The firmware keeps reading a 3D record for about 80 µs after the host can see its finish stamp.
  Rewriting the single 3D record that early (with TA/3D joint submission on) froze the SoC; two alternating 3D
  records fixed it. **[KC]** Apple never reuses a record right away: it keeps pools of about 110 records per
  engine and reuses a slot only after its stamps retire.

## 6. Compute

- **[HW]** Compute works: Apple's single-store kernel and Mesa's kernels, 32/32 values.
- **[HW][KC]** The single-store kernel first landed once in nine runs: its prologue compares the lane ID with a
  thread count in common-store dword 2 × (buffer count), and our loader never wrote that word. Mesa's binding DMA
  already did.
- **[HW][KC]** Mesa kernels at first locked up after about 520 ms (a silent firmware timeout). Against all 25 of
  Apple's compute records ours differed in a fence bit on the kernel record (Apple sets it only on the fence
  task), a 64-bit IF1 write where Apple writes 32 bits or none, and the PDS data unit count. The fence bit was
  the leading candidate **[INF]**; which change settled it is not recorded.

## 7. First triangle: the parameter manager and the fence buffer

The first TA job faulted at once and the first fixed one went silent. Two causes **[HW]**:

1. **The parameter manager's free-list page stack did not exist.** The PM control block pointed it into a Mesa
   buffer, the PM popped page 0 and the tiler wrote near VA 0. Fix: a real 0x18000-byte page stack, filled by
   the host.
2. **The fence buffer was mapped only in context 0.** The MCU writes the fence through the *running job's*
   page catalogue, so it faulted at `0x8_00010000` in the job's context and the firmware went silent. Fix: map the
   hardware-object window in every VM.

The rule that came out of it: **every address the firmware hands to hardware must translate in the running
job's context.** The A9 never hit this because its driver never names a fence buffer; it is the same class
of bug as the A9's missing TPC page. The first triangle then matched 3 of 3 (twiddled target), with TA and 3D
times of about 350 µs each.

## 8. Parameter manager (PM) and parameter buffer

The A8's PM scheme is the A9's with different counts, plus one big difference: on the A8 the **host** fills
the free list, and there is one PM set per VM rather than one per scene.

- **[KC]** PM control block (0x2000 bytes, uncached): `+0x08` PM id (firmware-written), `+0x14` newest slice,
  `+0x18/+0x1c` the page stack's GPU VA, `+0x20` stack size 0x18000, `+0x24` pages, `+0x28` top index, `+0x38` page
  size 0x1000, `+0x44` list address; then 36 scene (S) records from `+0x80`, stride 0xc0.
- **[KC]** The page stack holds u32 page numbers (physical >> 12), written by the kext on the CPU from index 0
  up, in the app's VM. Apple sends no command for it. The list is made of 0x84-byte slices (a link and 32 page
  numbers, i.e. 128 KiB blocks of 4 KiB pages; the A9 has 8 page dwords of 16 KiB pages).
- **[KC]** The firmware loads the TA side through `R0+0x210`/`0x220`/`0x390` (strobe `0x208`) and the 3D side
  through `0x218`/`0x230`/`0x398` (strobe `0x200`); the 3D word is pages | top << 22.
- **[KC]** Each S record holds the saved PM bank registers and its aux addresses; a fresh TA reads only the
  three aux addresses, so S records need no clearing on reuse. The kext rotates S across scenes from S[1] and
  guards reuse with per-S stamps (`addSceneDeps`, `0xfffffff008480d0c`).
- **[HW]** Our list page holds at most 61 blocks (`(0x2000 - 0x80) / 0x84`); the default pool is 32 blocks,
  clamped to 2..61 (module parameter `a8_pm_blocks`). Apple's pools grow to 0x300 blocks (96 MiB). PM grow is
  not implemented.
- **[KC]** Region headers: one buffer mapped twice (VA and VA + R, R a power of two of at least 16 slices), used
  as a 16-slice ring with a per-dataset cursor that advances one slice per frame and is never cleared. The tail
  pointer cache is 8·P² bytes. The kext writes no initial contents to either (zero is the valid start state).

### PM id per VM

- **[KC]** Apple gives **each live PM its own PM id** (`assignPMId`, `0xfffffff008486614`): 127 ids, a LIFO free
  stack, and an LRU steal of an id whose stamps have retired. Release (`0xfffffff0084804f0`) needs no firmware
  message.
- **[KC]** The firmware keeps 127 control pointers and a separate current id for the TA and 3D sides. On a switch
  to the same id it does nothing; otherwise it saves the evicted set and loads the new one.
- **[HW]** Our first driver submitted every VM under PM id 0, each with its own control block. Since the firmware
  skips the load when the id is already current, a second VM's TA could run on the first VM's free list: device
  loss or a PM hang with two GPU clients. Fix: PM id = the VM's context slot minus the first user slot (0..6).
  Flown with headless vkmark beside the compositor (551 fps, no faults), but only one VM was submitting in that
  run, so the two-VM save and load path is not load-tested yet.

## 9. A8 vs A9, in one list

| | A8 (T7000) | A9 (S8000/S8003) |
|---|---|---|
| GPU PLL | locks only with MISC_ACG (and SOC_TVM) set | locks without MISC_ACG |
| Power-on | the driver does PS_GFX, 33 bridge stores and Fender itself; every R0 access gated on PLL lock | power domain plus Fender |
| Firmware | 0x24000 image, no META core memory, ring control 0x30 | 0x30000 image, core memory, ring control 0x20 |
| MMU | classic BIF, `BIF_CAT_BASE0` | XE MMU (`0xe140`/`0xe148`) |
| SLC | `SLC_CTRL_MISC` only | SLC3, scramble, spare page |
| Context slots | 8, users from 1, one per VM | 256, users from 7, a pair per VM |
| GPU page | 4 KiB | 16 KiB |
| Compute kick | DM2 (0x12) | DM0 |
| Records | one extra u64 early (+8), 3D start 23 args | 3D start 20 args |
| PM | one set per VM, 36 S records, host-filled free list, id per VM | one set per scene, firmware rebuilds the free list |
| Hardware objects | `0x8_` window mapped in every VM | no fence buffer named |
| Region headers | 16-slice mirrored ring | one buffer per render target |
