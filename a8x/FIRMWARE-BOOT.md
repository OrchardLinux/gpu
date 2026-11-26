# iPad Air 2 (J81): Apple's META firmware boots to its alive event under Linux

Field report, 26 November 2026. One iPad Air 2 Wi-Fi (`iPad5,3`, J81, A8X/T7001,
PowerVR GXA6850), Linux 7.3.0-rc1 (Hoolock `6831bc7`, Orchard's `apple-4k` pin),
iPadOS 15.8.5 (19H394) as the reference kernelcache. Follow-up to
[DWI-FOLLOWUP.md](DWI-FOLLOWUP.md). It is not a driver and not a procedure for
other devices; J81's `gpu = "missing"` in Orchard's `devices/j81/device.toml`
is unchanged. Measured on the device unless tagged *inferred*. The run log
(runs 12 to 64), the runbook and the module are in
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

## Next

From Orchard's A8/A9 reference driver (request 18 in the notes): page-table flags
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
