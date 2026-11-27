# iPad Air 2 (J81): Apple's META firmware boots to its alive event under Linux

Field report, 26 November 2026, updated 27 November 2026 (runs 65 to 85: the firmware is
alive with Orchard's page-table flags; the first host command is consumed once the governor
pins from Orchard's A9 notes are in the image, see "The first command" below). One iPad Air 2 Wi-Fi (`iPad5,3`, J81, A8X/T7001,
PowerVR GXA6850), Linux 7.3.0-rc1 (Hoolock `6831bc7`, Orchard's `apple-4k` pin),
iPadOS 15.8.5 (19H394) as the reference kernelcache. Follow-up to
[DWI-FOLLOWUP.md](DWI-FOLLOWUP.md). It is not a driver and not a procedure for
other devices; J81's `gpu = "missing"` in Orchard's `devices/j81/device.toml`
is unchanged. Measured on the device unless tagged *inferred*. The run log
(runs 12 to 85), the runbook and the module are in
[mattonik/ipad-nixos](https://github.com/mattonik/ipad-nixos):
[`docs/j81-gpu-firmware-boot.md`](https://github.com/mattonik/ipad-nixos/blob/main/docs/j81-gpu-firmware-boot.md),
[`docs/j81-f3a-runbook.md`](https://github.com/mattonik/ipad-nixos/blob/main/docs/j81-f3a-runbook.md),
[`research/2026-11-22-j81-gpu-f1-f2-result.md`](https://github.com/mattonik/ipad-nixos/blob/main/research/2026-11-22-j81-gpu-f1-f2-result.md).
The offline tools are in [`tools/a8x/`](../tools/a8x/README.md).

## Result

On Linux, the firmware core (a META MTP219) runs Apple's own firmware, loaded
from a memory image the host builds: its bootloader runs through GPU page tables
we build, it loads its code into core memory, reads our root and state blocks,
builds its internal context tables, enables thread 0, **posts its type-0 alive
event** (with the PC of its idle loop, `0x80009c14` in core memory) and idles.
There is no META fault and no BIF fault, and the SoC stays up. For most of the
work we did not see the event: our page-table entries for the firmware's memory
are valid-only, so its writes sat in the SLC (a write-back cache) while the host
read uncached DRAM; one SLC flush (RGX `0x3818 <- 1`, then poll `0x3898`) made
the record visible (run 65). Next: map the firmware's pages with SLC bypass and
PM/META protect as Orchard's A8/A9 driver does, then the perf-state table, the
POLICY block and the firmware's hardware objects, before any job. No job was
submitted and no frame was rendered.

## The sequence that works

1. Power and identity as in the earlier reports (`dwi` on, GFX power cycle, GFX
   bridge settings 9 and 10 replayed **after every GFX power-on**, GPC request).
2. **Fender ConfigRAM walk.** In GPC state 0: `+0x10 = 0`, `+0 = 0x40000000`,
   store the stock 31-word list at Fender `+0x10000` word by word (a load-back each:
   three SOFT_RESET asserts, `META_BOOT 0x0bf8 <- 1`, `BIF_CAT_BASE0 0x1200 <-` the
   GPU page catalogue, the SLC pair `0x3800`/`0x3808`, a SOFT_RESET release, terminator
   `0xffff0000`), store the override `+0x20000 = 0`, request state 1 (`+0x1000 = 0x11`).
   Fender applies the list to RGX at the 0 to 1 request: `0x0bf8` then reads 1 (0 with an
   empty list) and `0x3800` reads `0x00300001` instead of `0x00320001`.
3. **The firmware's memory.** One 8 MiB DMA-coherent region (contiguous, uncached);
   a host-built 1 MiB blob (`tools/a8x/j81_f3a_build.py`) holds the firmware heap at GPU
   VA `0xe1c0000000`: the bootloader and text/data buffer from the LDR layout, root
   (`0x1490` bytes), state (`0x2058`), config (`0x318`), list-head blocks, rings, the
   ConfigRAM template. The module builds the three levels of 4 KiB GPU page tables and
   patches the real catalogue address into `BIF_CAT_BASE0`.
4. **Two config details decide whether the firmware runs.** The MMIO window table
   (config `+0x1c0`: Fender five pages, the AIC timer page, the AIC SW-int page, RGX with
   a physical address only), with those pages mapped in a second GPU page table at
   partition-9 VA `0xe1c4200000`; without it the firmware faulted on its first Fender
   access (`TXCATCH1 = 0x1000`). And config `+0x2f0 = 0x8000b3c8_20000000`, thread 1's
   `{sp, pc}` from the LDR record, sp in the high half.

## What we got wrong on the way (corrected)

- **"The Fender override store hangs the bus"** (runs 12 to 39 and 43) was a bug in our
  module: the Fender window was mapped with size `0x11000`, so every access to
  `+0x20000` landed in stray memory. With the full window mapped, the real release works
  in state 0 with Apple's complete list. The related claims that reading `+0x20000`,
  reading PMGR `+0x5004`, or reading RGX after a state-1 release hangs are void.
- **"The machine dies when META runs"** was our own host watchdog biting during a single
  10 s poll step; the machine runs fine with META released. No step should exceed about
  2 s between stage lines.
- **The F1 "hang" of 22 to 24 November** was a 512-byte line buffer in our supervisor.
- A zero read of the AIC timer page made us suspect a stopped timebase; the counter is at
  page offset `0x20` and runs.

## What the firmware has done and is doing

- Within 2 s of the release it wrote 121 words into our image that had left the SLC
  (323 after a flush, including the alive record): its globals, root and state addresses
  copied from our tail word, 16-entry context lists in the list-head blocks, and a core
  memory table of the first nine USC exception-slot register offsets.
- Thread 0 enabled (`T0ENABLE 0x0201c031`), no catch registers. It idles in the scheduler
  (halted snapshot: PC `0x10000358` polling the priority-0 `enqueued_commands`; the alive
  record reports `0x80009c14`). Thread 1 is not started by the firmware and is not needed
  (Orchard's A9 path does not start it either).
- The MTS doorbell (`RGX 0xb00 <- 0x10` after Fender `+0x14 <- 7`) changes nothing with
  empty queues. BIF fault `0x12b0` reads 0 in every run; no USC exception slot is pending.

## The first command (runs 66 to 85, 27 November 2026)

With Orchard's A8/A9 flags (heap `valid | bit 3 | bit 62`, windows `valid | bit 3`) the alive record is
visible at once (run 66, no SLC flush). We then added the perf-state table, the POLICY minimum and the
four hardware objects (run 67), and tried the first host-to-firmware command on the device-control
ring (an empty type 8 `PerfCtrSamplerCommitCounterList`): the ring protocol is Apple's
`submitDeviceControl` write for write (entry, `dmb`, producer index at control `+0x10`, Fender `+0x14 <- 7`,
`RGX 0xb00 <- 0x10`).

**Result (run 85): the command is consumed once the image carries the governor pins that Orchard's A9 host
writes** (OrchardLinux/gpu PR #11, `a8x/ORCHARD-NOTES-20261127.md` sections 3, 4 and 7.3; thank you). With them:
CONTROL `+0x1024` counts up (the firmware's command-8 handler ran), the device-control consumer index moves
(0 to 1), a META slave-port read issued after the kick is answered at once (`MSLVCTRL1` `0x07000040`, thread 0
`T0ENABLE 0x0201c031`), and the MMU fault described below no longer appears (`EVENT_STATUS 0x130 = 0`).
The pins we added (q = 1, N = 4, our perf table's start and highest state): POLICY `+0x0c = 4` (the A9's
`+0x08` u64 `0x4_00000000`), POLICY `+0x688/+0x68c = 400`, `+0x6f0/+0x6f4 = 100`, CONTROL `+0x1028 = 3348` (the
A9's envelope in mW; J81's is unknown), `+0x102c/+0x1040 = 100`, `+0x1030/+0x1038 = 400`. Nothing else changed
(memory-only; the same host sequence). We have **not** yet bisected which of the pins is the necessary one.

**The slot load (command 3), run 87:** consumed as well, once `MMU_ROOT[0]` (slot 0, the firmware's own
context; the 8-byte-per-slot block named by CONTROL `+0x1048`) holds our page catalogue: entry `{3, 1, 0, 0, 0}`
with `MMU_ROOT[1]` = the catalogue and `TAG_HOST[1] = 0x00400000`; the consumer moves 1 to 2 at once, the
firmware's seen-tag for slot 1 reads `0x00400000`, and `EVENT_STATUS` stays 0. With `MMU_ROOT[0]` left 0 (run 86)
the handler copied the tag and then stalled with a new instruction-fetch MMU fault (the firmware's own next
fetch, bank 1, GPU VA `0xe1c0007580`): the handler refreshes the GART from the root table, so slot 0 must hold
the firmware's own catalogue, as in Orchard's driver. No job was submitted: a first compute job is next.

**Before the pins (runs 66 to 84, same device, same host sequence, for the record):** the firmware never
consumed the command. What we measured:

- After the kick `RGX 0xb10` reads `0x10` (the MTS presents the DM0 task) and stays; `0xba8`, `0xb98`, `0xbb0`,
  `0xac8` stay 0; Fender `KICK_STATUS +0x8` stays 0. A non-counted kick (`0xb00 <- 0/1/2`) and an
  interrupt-context kick (`0x30`) leave no trace. `0xbc8` (SCHEDULE_ENABLE) and `0xb08` read 0 and ignore host
  writes; `EVENT_CLEAR 0x138` is writable.
- A META slave-port read request issued after alive (`MSLVCTRL1` goes `0x07000040` to `0x06000040`, READY
  clear) was never serviced in 30 s, with the PMGR clock on and locked (`PS_GFX 0x3ff`, PLL lock, `CLK_STATUS
  0x00600000`).
- `EVENT_STATUS 0x130 = 0x200` (MMU_PAGE_FAULT) from META's release on, with BIF fault bank 1 (our earlier fault
  check read only bank 0) showing one instruction-fetch read by META thread 0 (address `0xe1c000df80`, a mapped
  heap page, tag 3, context 0). Clearing the event, invalidating the MMU caches before the release, a zero page
  at GPU VA 0 and an alias of the heap at `0xc0000000` changed nothing (runs 81 to 84). With the pins the
  fault is gone, so it was a symptom of the firmware's scheduler not running, not its cause.
- Our 31-word Fender ConfigRAM list is, word for word, the one Apple's host builds; `CONTROL +0x20 = 1`
  (iOS's idle-power-off default) changes nothing.
- *Inferred* from the decoded firmware (Orchard's `minim.py` expands it for binutils 2.30 and works on the J81
  text): before the pins, thread 0 never reached its trigger sleep; its scheduler pass runs the governor first,
  and with empty governor inputs that pass did not complete (Orchard's notes raise exactly this in 7.3).

**What we would still like to know from Orchard:** is POLICY `+0x0c` (the A9's `+0x08` u64) or one of the
100·N / 100·q words the one that matters on your A9, and does the A9 firmware also read J81's POLICY
`+0x6fc/+0x7cc` (400, from our kext's reading)? Anything A8X-specific you know for the slot load and a first
compute job (`RGX 0x8238`, the 66 bridge stores, `dwi`, the 8-cluster records)?

## Next

(Superseded by the section above: the page-table flags, perf-state table, POLICY block and hardware objects are done.) Originally, from Orchard's A8/A9 reference driver (request 18 in the notes): page-table flags
(`valid | bit 3 SLC bypass | bit 62 PM/META protect` for the heap, bit 3 for the MMIO
windows), the perf-state table in config `+0x29c..+0x2e3` (our captured ADT leaves it
empty), the POLICY block that Apple fills on its boot path, and four small hardware
objects named in config. Then a first command. The firmware code is MiniM and cannot
be decoded publicly; that is no longer needed for boot. Why a slave-port read of core
memory near the idle PC returned noise is not understood.

## Method and Apple data

Written with AI assistance (Claude) and checked on the device, as the commit trailers say;
statements that came from offline analysis of the kernelcache are tagged as inferred in
the notes linked above. Nothing of Apple's is committed: no firmware, no kernelcache
content, no captures, and not the table of GFX bridge settings the module replays (it lives in
mattonik/ipad-nixos, not here; the tools here read the firmware from your own kernelcache and write only to directories you
name).
