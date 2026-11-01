# A10 (T8010) GPU: the kernel side

Part of the bring-up guide (README.md) for the iPad 6 (J71b) GPU driver. It is
written for two readers: someone writing the A9 (S8000/S8003) GPU driver, and
anyone bringing up a related Apple SoC. You need Linux kernel basics. You do
not need to know Apple hardware: every Apple concept is explained before it is
used.

Ground truth is the code: `kernel/patches/drivers/gpu/0001-drm-imagination-Support-the-Apple-A10-T8010-GPU.patch`
(files `pvr_apple.c`, `pvr_apple_layout.c`, `pvr_apple_queue.c`, plus hooks
in the upstream `drivers/gpu/drm/imagination` files), the mailbox patches
`kernel/patches/drivers/soc-apple/0006`/`0007`, and the device tree patch
`kernel/patches/devices/t8010/0011` (all in orchard). The lab notebooks in `a10/`
(FENDER.md, COMPUTE.md, RENDER.md, MESA.md) hold the evidence. They are
chronological, and later entries correct earlier ones. Where a note and the
code disagree, this guide says what the code does.

Conventions:

- **fw 0x…** is an offset in the GFX firmware image. The image is ARM32
  (Thumb-2) and loads at address 0, so offsets equal addresses.
- **kext 0xfffffff0…** is an address in the iPadOS 17.7.11 kernelcache for
  iPad7,5 (21H461). The AGX kext was decompiled with Ghidra (RENDER.md, "The
  iPadOS kext's microsequence builders").
- **iOS capture** means memory captured from a running iPadOS 17.7 under
  palera1n with `tools/a10/ios-capture/`.
- Every entry ends with an **A9:** line. Most say "unknown". Nobody has
  looked at the A9 GPU firmware yet, so treat everything here as a list of
  checks, not as known A9 facts.

---

## 1. Concepts primer

### 1.1 Coprocessors: IOP, ASC, gfx-kf

Apple SoCs contain many small ARM cores beside the main CPUs. Each one runs
its own firmware and drives one block: storage, audio DMA, always-on sensors,
the GPU. Apple calls the older generation of these cores **IOPs**, and the
kext classes are `AppleA7IOP`, `AppleA7IOPV1` and `AppleA7IOPV2`. The M1-era
generation is called **ASC**. The main CPU is called the **AP** (application
processor). Firmware, memory and messages are the AP's job: it places the
firmware image in RAM, tells the coprocessor where the image is, starts its
CPU, and then talks to it through a mailbox.

The GPU's coprocessor is the ADT node **gfx-kf** (ADT is the Apple device
tree that iBoot passes). On T8010 it is at `0x201d20000`.

- **True:** gfx-kf is an AppleA7IOP V2 block. The V2 register offsets match
  the live values. The V1 offsets (block at `0x1000…`, CPU control at `0x28`)
  read zero. GFX overrides two V2 methods. The CPU run bit is **Fender
  +0x2048 bit 0**, not the generic V2 run bit (`+0x44` bit 4). The firmware
  window is written in two copies, one in Fender and one in the IOP block.
- **Evidence:** the `AppleA7IOPV2GFX` vtable at kext 0xfffffff006fe3ef8: run
  at `0x…415fc`, window at `0x…4155c` (FENDER.md §2, §4.1).
- **Code:** `pvr_apple.c: pvr_apple_power_on()` sets `FENDER_RUN`, and
  `pvr_apple_set_window()` writes both window copies.
- **Verify:** with the GPU power domain on, read the V1 and V2 offsets. The
  live V2 mailbox control words are non-zero (`+0x4008`, `+0x4020`).
- **A9:** likely the same IOP generation. The S8000 SIO patch
  (`soc-apple/0004`) says the A9's SmartIO coprocessor is the same
  AppleA7IOP as on T8010. That is a different coprocessor, though. Check
  the A9 `gfx-kf` (or equivalent) node's `iop-version` and reg entries.
  Where the GFX run bit lives is unknown: look for an `AppleA7IOPV2GFX`
  override in the A9 kernelcache.

### 1.2 The Apple mailbox

A **mailbox** is a pair of hardware FIFOs between the AP and a coprocessor:
the inbox (AP to IOP, "A2I") and the outbox (IOP to AP, "I2A"). Each FIFO
has a control register with full/empty bits and a data register. Each FIFO
also has interrupts, such as "outbox not empty". Linux drives the Apple
mailboxes with `drivers/soc/apple/mailbox.c`, which comes from Asahi Linux.

- **True:** the A7 IOP mailbox moves **one 64-bit word per message**. The
  endpoint number sits in bits 63:56 and the payload in bits 55:0. The M1
  ASC/M3 mailboxes move 64+32 bits through two registers, with the endpoint
  in the second word. The A7 IOP mailbox masks its interrupts through a
  set/clear register pair (ASC uses enable/ack registers), and each FIFO
  must be enabled through bit 0 of its control register. Register offsets
  are relative to the mailbox base, which is IOP base + 0x4000: mask set
  `0x00`, mask clear `0x04`, A2I control `0x08`, send `0x10`, I2A control
  `0x20`, receive `0x38`. Control bit 16 means full and bit 17 means empty.
- **Evidence:** in the kext, `sendMessage` is a single `str x` to `+0x4010`
  and `receiveMessage` a single `ldr x` from `+0x4038`. RTBuddy's receive
  path does `lsr x, #56` at kext `0x…5d80368` (FENDER.md §5). On hardware the
  firmware's first message was `0x00100000000C000C`: endpoint 0, RTKit
  HELLO, version 12.
- **Code:** `soc-apple/0007`, variant `apple_mbox_a7iop_hw` (`packed_endpoint`,
  `needs_enable`, `has_irq_mask`). `apple_mbox_send()` rejects payloads with
  bits 63:56 set. `apple_mbox_start()` re-runs the mask and enable setup on
  every start, because the coprocessor's power domain may have been off in
  between. The DT node is `gpu_mbox: mbox@201d24000`, AIC IRQs 189 to 192
  (`devices/t8010/0011`).
- **Differences from iOS:** iOS also writes mirrors of the mask registers at
  IOP `+0xc00`/`+0xc04`. Our variant does not, and the handshake works
  without them. IOP `+0xc004 = 0x11` / `+0xc024 = 1` is a **doorbell** that
  wakes a sleeping IOP (kext `ringDoorbell` `0x…5d71f4c`). Writing it during
  the handshake made the firmware stop reading its inbox (FENDER.md §6). The
  driver never writes it, because it never lets the IOP sleep.
- **Verify:** boot the coprocessor by hand. Poll I2A control bit 17 until it
  clears, then do a 64-bit read of the receive register. You should get an
  endpoint-0 HELLO.
- **Open:** the mapping of mask bits to the four interrupts, and the order
  of the interrupts in the DT, are not confirmed on hardware. The ADT lists
  190, 189, 192, 191 for gfx-kf (commit e8c1361).
- **A9:** likely the same message format (SIO uses the same block). Check
  the base offset (+0x4000) and the IRQ numbers in the A9 ADT.

### 1.3 RTKit

**RTKit** (also called RTBuddy) is Apple's small RTOS on these
coprocessors. On top of the mailbox it defines **endpoints**: numbered
message channels. Endpoints below 0x20 are system endpoints. Endpoint 0 is
management: HELLO and version negotiation, EPMAP (which endpoints exist),
STARTEP, and IOP/AP power states. Endpoint 1 is the crashlog, which asks the
AP for a buffer and fills it when the firmware crashes. On other coprocessors
there are also syslog and ioreport endpoints. Endpoints from 0x20 up belong
to the application. Linux has a generic implementation in
`drivers/soc/apple/rtkit.c` (Asahi), called `apple-rtkit`.

- **True:** the GFX firmware speaks RTKit protocol **v12** (build
  `RTKit-2419.140.12`). Its EPMAP lists endpoints 0, 1 (crashlog), 0x20 and
  0x21. There is no syslog endpoint. Upstream `apple-rtkit` runs the whole
  handshake unchanged on top of the A7 IOP mailbox variant.
- **Evidence:** hardware: "RTKit: Initializing (protocol version 12)", EPMAP
  read by hand (README.md "Results on J71b").
- **Code:** `pvr_apple_power_init()` calls `devm_apple_rtkit_init()` with
  `pvr_apple_rtkit_ops`. `pvr_apple_shmem_setup()` serves buffers the
  firmware asks for (the crashlog buffer). Firmware-chosen addresses must
  lie inside the window. Otherwise the buffer is carved from the window
  between the end of the image (`0x8f000`) and the init page (`0x98000`),
  because the IOP reaches the window at IOP address = window offset.
  `pvr_apple_crashed()` hex-dumps the crashlog.
- **Verify:** load with `dyndbg=+p`. Every firmware message on an AGX
  endpoint is logged ("firmware ep …").
- **A9:** RTKit itself is likely the same. The protocol version and EPMAP
  are unknown: read the HELLO.

### 1.4 The GFX firmware and its AGX endpoints

Apple does not run Imagination's firmware on this GPU. The `GFX` firmware
(Apple's) runs on gfx-kf and schedules GPU work. It comes from
`AGXFirmwareKextG9PRTBuddy` `__TEXT,__const` (file offset `0xd41edf`,
`0x5b320` bytes, ARM32, load base 0, runtime size `0x8f000`). The driver
loads it as `apple/gfx-t8010.bin`, a raw image with no header.

- **True:** two application endpoints:
  - **0x20, init:** the AP sends `0x81 << 48 | PA`, where PA is the 44-bit
    byte physical address of the init page (not shifted). The firmware
    copies the first 0xa4 bytes (fw 0x179e0, check at 0x17a0c, copy at
    0x17a80).
  - **0x21, doorbell:** `0x83 << 48` makes the firmware scan all its rings.
    It first drains the mapping-update ring, then dispatches work (handler
    near fw 0x1c9e2 to 0x1cbf6). A 0x83 sent on 0x20 is ignored.
- **Evidence:** firmware disassembly (FENDER.md §8.1, §14.1). The kext's
  kick payload is `0x0083… | (ring & 7) << 2` (kext `0x…6022640`). We send
  the bare `0x83 << 48`, and the firmware scans every ring anyway.
- **Code:** `APPLE_EP_AGX_INIT`, `APPLE_EP_AGX_DOORBELL`, `APPLE_MSG_INIT`,
  `APPLE_MSG_KICK` in `pvr_apple.c`.
- **True, no completion message:** the firmware sends no message when a job
  completes in our setup. Completion comes from memory (stamps and events,
  1.8).
- **A9:** unknown. Extract the A9 GFX image (look for an
  `AGXFirmwareKext…RTBuddy` class and its `requestFirmwareBinary`), then
  check the endpoint numbers in the EPMAP and the 0x81 check (search for the
  string "Unable to grab init data from host").

### 1.5 Fender and the Rogue core

The shader cores and fixed-function units are an Imagination **PowerVR
Rogue** core ("RGX", kext name `AGXG9P`) at `0x201000000`. Upstream Linux
supports other Rogue parts in `drivers/gpu/drm/imagination` (the `powervr`
driver). **Fender** is Apple's power and wrapper block in front of the core,
at `0x201d00000`, `0x5000` bytes. On G9P Fender holds the core power state,
the IOP run bit and the firmware window registers.

- **True:** any RGX register access while the core is unpowered faults (a
  Linux panic/SError). The core powers up when **Fender +0x1000** is written
  with `0x10 | state` and its low 5 bits read back `state`. State 0 is off.
  States 1 to 6 are on and are also the GPU's **performance states**
  (clock/voltage steps, lowest to highest). The older AP request bit at
  Fender `+0x10` does not power the core.
- **Evidence:** the firmware's own setter fw 0x16d40 writes `target | 0x10`
  and polls for `& 0x1f == target`. On hardware, a single
  `devmem 0x201d01000 32 0x11` made `RGX_CR_CORE_ID` readable
  (`0x011b0602`, legacy CORE_REVISION `0x000d0a00`) (FENDER.md §18). For
  performance, state 6 against state 1: an ALU-bound render took 3.70 ms
  instead of 8.69 ms (FENDER.md "GPU performance states").
- **Why the AP writes it:** the firmware calls 0x16d40 only when P+0x93c
  and P+0x944 are both non-zero. They are copied to fw globals 0x30438 and
  0x3043c at 0x17ce8. With them zero, as in our layout, the firmware only
  sets a software "powered" flag (`power_state+0x38 = 1`, fw 0x6b12). So the
  driver requests the state itself, and the firmware never changes it
  afterwards (its DVFS step, fw 0x6a98, never runs in our setup).
- **Code:** `pvr_apple_request_power_state()`. In `pvr_apple_power_on()` a
  core left on by an earlier boot is first taken to state 0, then
  `apple_perf_state` (default 6) is requested. `pvr_apple_fw_fini()`
  requests state 0. A module reload restarts the IOP but does not reliably
  reset RGX, which is why the driver goes through state 0 (COMPUTE.md, hook
  32).
- **Verify:** with the power domain on and the firmware running, write
  `0x11` to Fender+0x1000 and wait for readback 1. Only then read CORE_ID.
  Never read RGX while state 0 is acknowledged.
- **A9:** unknown. FENDER.md §15.1 places an A9 Fender at `0x201e00000`
  "in the same family", without a source; treat that as unverified. Check
  for an `AGXFender` class in the A9 kext, and whether the A9 firmware has
  an `agfPollFenderReg`/0x16d40-like setter.

### 1.6 The firmware window and the heap

The firmware sees host memory in two ways:

- **The window:** one physically contiguous block that the IOP sees at
  **IOP address 0**. Its base, IOP address and length are written to Fender
  `+0x200c..+0x2020` and to IOP `+0x08..+0x30` (8-byte stride), and the IOP
  copy is enabled with IOP `+0x38 = 1`. No DART (IOMMU) is involved. The
  window holds the image, the zeroed runtime area up to 0x8f000, the RTKit
  buffers, the init page and the memory descriptors.
- **Its own MMU:** the firmware runs an ARMv7 LPAE MMU and maps physical
  memory itself. The init page is mapped by PA. Further host memory is
  mapped through **memory descriptors** `{fw VA, PFN, 0, u16 pages, u16
  flags}` at fixed firmware VAs (fw 0x17b74 loop, mapper fw 0x18084). We
  call that memory the **heap**.
- **Rules found the hard way:**
  - Fixed mappings must stay in fw VA `0x100000–0x1fffff`. That range sits
    inside a level-3 table the firmware already has. New VAs elsewhere fail
    with `0x8000000B`, because the mapper has no spare tables (FENDER.md
    §10.1).
  - Descriptor flags 0 give attr 0x41b, which is MAIR index 2, inner
    non-cacheable. Flags bit 1 gives 0x11b (write-back), and with it the
    firmware did not see later host writes to producer indices (FENDER.md
    §19.3).
- **Code:** `pvr_apple_layout.h`: `PVR_APPLE_WINDOW_SIZE` 1 MiB,
  `PVR_APPLE_FW_RUNTIME` 0x8f000, `PVR_APPLE_HEAP_SIZE` 4 MiB. Both buffers
  come from `dmam_alloc_coherent()` with a 40-bit DMA mask, and the window
  must be 16 KiB aligned (`pvr_apple_power_init()`). `pvr_apple_layout.c:
  build_init_page()` writes two descriptors: heap+0 at fw VA 0x100000 (56
  pages) and heap+0x50000 at fw VA 0x140000 (64 pages), both with flags 0.
  `fw_va()` converts heap offsets to firmware VAs.
- **Verify:** an all-zero init page gives the firmware string "Unable to
  register init mem desc at PA_0 …, status:0x80000002" (0x80000002 means
  invalid argument). A wrong VA gives `0x8000000B`.
- **A9:** unknown. Check the A9 kext's `_mapFirmware`/window registers and
  the firmware's runtime size (`getRuntimeBinSize`).

### 1.7 Init data

**Init data** is the set of structures the AP builds in memory before it
sends 0x81. The firmware reads them to find its rings, its GPU page tables,
the registers it may touch and its configuration. There is no
documentation. The layout was recovered crash by crash: each reload is a
fresh firmware, and each crashlog names the next missing pointer. The kext
was then decompiled to get real values. The names below are ours (the
firmware has no symbols for them) and are used in `pvr_apple_layout.c`:

| Name | Reached through | What it is |
|---|---|---|
| init page | 0x81 message (PA) | 0xa4 bytes: pointers to X, T, U, V, the descriptor list, the init-sequence program |
| X | init+0x18 | main context: pointers to P, Q, Z, the 13 ring descriptors, event/trace rings, unit-state pages, the power-state struct |
| P | X+0x0 | device context: GPU address windows, I/O mapping table, engine unit masks, power and DVFS configuration |
| Q | X+0x4 | flush scratch/fence GPU address, programmed into RGX+0xe240 |
| Z | X+0x8 | a flag struct; zero takes a fallback path |
| T | init+0x1c | MMU context table: generations (T+0x7dc), physical page-table roots (T+0x7e0), root mask (T+0x7e4) |
| U | init+0x98 | debug flags (U+0) and the **ready** flag (U+0x14) |
| V | init+0x9c | mapping-update ring (V+0x455c/+0x4560), scheduler init (V+0x45b4) |
| A0 | init+0xa0 | a page the power path reads and writes (+0x1b8) |

Section 3 lists each field.

### 1.8 Rings, stamps and events

- **Rings** are circular arrays in the heap with a producer index (written
  by whoever adds entries) and a consumer index (advanced by whoever takes
  them). Indices wrap at the ring size (256). The firmware has 13 host
  rings: 12 work rings (4 priorities × 3 engines: geometry, fragment,
  compute) and one control ring. Each work ring entry points at a **queue**,
  which has its own **command ring**: a ring of pointers to commands.
- A **command** names a **microsequence**: a small program in firmware
  opcodes such as "start compute", "wait for GPU event", "finalize", "end".
  The firmware interprets it (fw 0x9f04, table at 0xa3dc). It is Apple's
  equivalent of IMG's firmware command.
- A **stamp** is a word in host memory that the finalize step writes with
  the job's sequence number. The host polls it.
- An **event** is a 0x24-byte record the firmware posts into its **event
  ring** when work finishes. The host must consume events, or the firmware
  stalls (section 5).

---

## 2. Boot sequence, step by step

The upstream `powervr` driver is reused. The Apple variant is selected by
`compatible = "apple,t8010-gpu"` and plugs in through `pwr_ops` (power) and
`pvr_device_is_apple()` checks (firmware, queues, VM).

1. **Probe, power domain.** The DT node `gpu@201000000` has reg names
   `rgx`, `fender` and `iop`, plus `mboxes = <&gpu_mbox>` and
   `power-domains = <&ps_gfx>`. Both the GPU and the mailbox nodes reference
   `ps_gfx`, so the PMGR power state (pmgr+0x80328) is on before anything
   is touched. There is no core clock (`devm_clk_get_optional`) and no AP
   RGX interrupt: the interrupt goes to the firmware (`pvr_device.c`).
2. **Allocate and load:** `pvr_apple_power_init()`. It maps Fender and the
   IOP block, allocates the window and heap, copies the image to window
   offset 0 (the rest of the window is zero), creates the RTKit instance and
   calls `pm_runtime_forbid()`. Suspend is not implemented, and the firmware
   loses its state when powered off.
3. **Window and run:** `pvr_apple_power_on()` → `pvr_apple_set_window()`
   (both copies, length 1 MiB, IOP address 0), then sets Fender `+0x2048`
   bit 0.
4. **RTKit handshake:** `apple_rtkit_boot()`. The firmware sends HELLO on
   its own as soon as it runs. It needs nothing but the image, the window,
   the mailbox and the run bit. Fender and RGX do not need to be up for
   this. Then `apple_rtkit_start_ep(0x20)` and `(0x21)`.
5. **Core power and performance state:** first state 0 if the core is left
   on, then `apple_perf_state` (1.5). From here on RGX registers are safe.
   powervr reads CORE_ID next. The driver maps it to BVNC 13.10.6.2, which
   is marked experimental (`pvr_device.c`), so `exp_hw_support=1` is needed.
6. **Static device info:** `pvr_apple_device_info_init()`. The Apple image
   has no IMG header, so the features are hard-coded: 6 clusters, 40-bit
   physical/virtual, 32×32 tiles, compute stream format 1, and so on.
   `pvr_device_gpu_init_apple()` then creates the kernel VM context.
7. **Build init data:** `pvr_apple_fw_init()`:
   - `pvr_apple_gpu_pages_init()` maps the driver's GPU pages in the kernel
     VM: data page at GPU VA 0x200000, PDS and USC code at the code heap
     bases, and a zero page.
   - `pvr_apple_layout_build()` writes the init page, X, P, T, U, V, the
     compute queue and the MMU root (the kernel VM's page-table root).
   - `pvr_apple_layout_build_ta()` / `_build_3d()` add the geometry and
     fragment queues on work rings 0 and 1.
   - `wmb()`.
8. **Init message:** `apple_rtkit_send_message(0x20, 0x81 << 48 | PA(init))`.
   The firmware copies the init page, maps the descriptors, the I/O table
   and its shared page, and starts its tasks (agx_background,
   agx_recovery, interrupt, sampler, power).
9. **Ready:** poll **U+0x14 == 1** (`HEAP_U_READY`, up to 3 s). The
   firmware sends no "ready" message (the kext's `waitForFWAlive` also
   polls).
10. **First kick:** on the first doorbell the firmware drains the mapping
    ring, runs its fixed RGX initialization (fw 0x57c0 onward: RGX+0x600,
    +0xe200 and +0xe208 change; it polls +0x11f00, +0xcd8 and +0xcb8), runs
    the empty init-sequence program and loads MMU context 0 from T (fw
    0x18352). On hardware this happened before any real job (FENDER.md
    §19.1).
11. **Self-tests (removed):** during bring-up `apple_selftest` ran compute
    jobs (including in a second VM) and the captured triangle. They were
    dropped when the driver went to main (b5e3769); the commits before it
    on dev/gpu-a10 have them.

Teardown, `pvr_apple_fw_fini()`: switch GPU context 0 back to the kernel
VM, cancel fences, request Fender state 0, `apple_rtkit_shutdown()`, clear
the run bit. Reload then works (DRIVER.md, boot 9).

**Memory bandwidth (separate driver).** The A10 boots with its SoC and
memory performance states low, which halves memory bandwidth for both the
CPU and the GPU. PMGR `+0x68000` low 4 bits select both: `0xc` for high,
`0xd` for low, and bit 31 is set while a change is pending. The source is
iOS 10's unstripped `AppleT8010PMGR::setPerfState`. `apple-pmgr-misc`
(`soc-apple/0011`/`0012`, DT `devices/t8010/0012`) sets them high at probe
and low on suspend. Measured: an empty full-screen GPU render went from
2.24 to 1.32 ms. **A9:** unknown, look for `AppleS8000PMGR::setPerfState`.

---

## 3. Init data layout

Offsets are relative to each structure, and "fw VA" values are what our
layout uses. Only fields that the firmware is known to read, or that the
code writes, are listed. "Zero OK" means the firmware accepts 0 there.

### 3.1 Init page (window + 0x98000; `build_init_page()`)

| Offset | Value in our code | Notes / evidence |
|---|---|---|
| +0x08/+0x0c | PA of the init-sequence program (heap+0x38000, an empty page) | Required: if 0, "Unable to register init sequence memory … status:0x80000002". The program is 20-byte entries `{val lo, val hi, reg, shift, type}`. Type 0 ends it; 1, 2 and 3 are 32-bit, 64-bit and shifted writes. There are no polls or delays. Interpreter at fw 0x5828 (FENDER.md §17). Empty works on hardware. iOS's program writes RGX+0xe140/+0xe148 (MMU context select) and +0xe160 (time) (kext `0xfffffff006021d10`). Ours writes nothing, and the MMU root reaches the GPU through T instead. |
| +0x18 | fw VA of X | Required: null → data abort at fw 0x15486 |
| +0x1c | fw VA of T | Required (read at fw 0x2760) |
| +0x8c/+0x90 | PA of the descriptor list (window + 0x9c000) | Required, 4 KiB-aligned; the firmware always maps 16 KiB of it |
| +0x94 | 2 (number of descriptors) | |
| +0x98 | fw VA of U | Required: null → abort at fw 0x278c |
| +0x9c | fw VA of V | Required |
| +0xa0 | fw VA of A0 (heap+0x10000) | Required by the power path (`+0x1b8` u64, fw 0x1b2a2) |

Found by crash iteration (FENDER.md §8 to §11, §17). **A9:** unknown. Check
whether the A9 firmware's 0x81 handler copies a similarly sized block, and
which offsets it maps by PA.

### 3.2 X, the main context (heap+0x0; `build_main_context()`)

- `+0x0 = P`, `+0x4 = Q`, `+0x8 = Z` (fw 0x1bb0a reads Q).
- **Ring i (0..12)** occupies `+0xc + 0x10*i`. It holds pointers to the
  consumer index (+0xc), the cache-synchronized index (+0x10) and the
  producer index (+0x14), followed by the entries pointer (+0x18). All index
  words live on one page (heap+0x11000, 0x10 per ring). Ring scan fw
  0x502c. Rings 0 to 11 are work rings, ring 3p + {0, 1, 2} =
  geometry/fragment/compute at priority p, and ring 12 is the control ring
  (32-byte entries, opcodes 3..31; opcode 0 is consumed and ignored, fw
  0x20904). The code uses ring 0 (X+0x18, geometry), ring 1 (X+0x28,
  fragment) and ring 2 (X+0x38, compute).
- `+0xdc/+0xe0`: event ring control and entries (heap+0x57000/+0x58000).
- `+0xe4/+0xe8`: zero pages. `+0xec/+0xf0`: SKU debug trace control and
  records. `+0xf4/+0xf8`: firmware trace control and records.
- `+0x134/+0x138/+0x13c/+0x140`: unit-state pages: geometry, fragment,
  shared (compute Start/Finalize use +0x13c), and a page whose first word
  the power-up condition checks.
- `+0x188`: the acknowledged MMU generations.
- `+0x1ec`, `+0x1fc`: **values, not pointers**, despite FENDER.md §13. The
  firmware counts outstanding work in +0x1fc (COMPUTE.md). We leave both 0.
- `+0x301` (unaligned u32): pointer to the **power-state struct** (heap+
  0x69000, at least 0x4314 bytes). The firmware writes it (fw 0x6a98, 0x7de0,
  0x838a). It needs pages of its own: at an earlier VA it overlapped the
  geometry queue (code comment).
- Evidence: a static scan of every `[[0x8e54c]] + off` load (FENDER.md §13.2)
  plus crash iteration.
- **A9:** unknown. The 13-ring scan loop is easy to find by pattern: a
  loop of 13 with stride 0x10 comparing two dereferenced words.

### 3.3 P, the device context (heap+0x2000; `build_device_context()`)

- `+0x00..+0x27`: GPU address windows, five u64 values, copied from the kext
  (`0xfffffff006012bd0`): `0x600000000`, `0xffc00000`, **PDS exec base**,
  **USC code base**, `0x1ffff8000`. iOS uses 0x300000000 for both code
  bases. We pass powervr's PDS and USC heap bases (`0x2a00000000`,
  `0x2c00000000`). Shader and PDS code offsets are relative to these. The
  meaning of the other three values is open.
- `+0x640`: **I/O mapping table**, 0x18-byte entries `{PA lo, PA hi, fw VA
  (written back by the firmware), size, flags, rw}` (fw 0x1a198). Entry 0 is
  Fender (`0x201d00000`, 0x5000) and entry 3 is RGX (`0x201000000`,
  0x20000). The other entries (1, 2, 4, 5, 6) are backed by 128 KiB of heap
  RAM each (`HEAP_IO_RAM`). Whether the firmware needs them is untested;
  FENDER.md §15.4 says entries with PA 0 are skipped. `+0x14` must be
  non-zero: 0 selects attr 0x209, a **read-only** device mapping, and the
  first Fender write then takes a permission fault (FENDER.md §16; the DFSR
  is in LPAE long-descriptor format). Size 0 maps one page only. The order
  of the entries follows the kext's IO-mapping names (FenderRegs,
  AICTimerRegs, AICSWIntRegs, RGXRegs, …), medium confidence.
- `+0x16c0/+0x16c4/+0x16c8 = 1`: one hardware unit each for geometry,
  fragment and compute.
- `+0x93c/+0x944`: left 0 on purpose, so the firmware does not run its own
  Fender power and DVFS path (1.5).
- `+0xa5c`, `+0xa60…`, `+0xea0…`: per-state frequency tables that the kext
  fills and the firmware reads at init. They are left 0. DVFS is not used.
- **A9:** the window values and I/O PAs are per chip. Read them from the A9
  kext (`configureDevice`, the P[0..0x27] initializer) and the ADT; do not
  copy ours.

### 3.4 T, U, V and the GPU MMU

- **T+0x7e0** points to 256 u64 physical page-table roots (heap+0x26000).
  Root 0 is context 0. **T+0x7dc** points to per-context generation words
  (heap+0x52000). When a generation differs from the acknowledged copy
  (X+0x188), the firmware invalidates that context (fw 0x18530; RGX+0xe138).
  The init routine fw 0x18352 loads root 0 plus the roots flagged in the
  masks at T+0x7e4. A generation bump of 0x400000 forces a full
  invalidation.
- The page tables are standard Rogue PC/PD/PT, as upstream `pvr_mmu.c`
  builds them (kext `0xfffffff0060365a8` confirms the geometry). The driver
  passes `pvr_vm_get_page_table_root_addr(kernel_vm_ctx)`.
- **U+0 = 3** enables the SKU debug trace. **U+0x14** is the ready flag.
- **V+0x455c/+0x4560**: mapping-update ring control and entries. The
  firmware drains this ring at every doorbell (fw 0x181ee). Its entries map
  more of host memory into the firmware's own MMU at runtime; they do not
  touch GPU page tables. The driver does not use it beyond setting it up.
- **V+0x45b4 = 1** is required: it initializes the engine scheduler's
  callback tables (fw 0x1b688 → 0xd980). Without it the first compute
  command branches through a null callback.
- **Q** (heap+0x6000) = GPU VA 0x203000, a page the GPU writes during
  FinalizeCompute's cache flush (RGX+0xe240). If it is missing, FinalizeCompute
  takes a write fault (MMU status 0xff251) at VA 0.
- **A9:** unknown. If the A9 firmware is a sibling build, expect the same
  T+0x7dc/0x7e0 pair. Check with the "context root" load near the init
  routine.

### 3.5 Queues and commands (`build_compute_queue()`, `build_ta()`, `build_3d()`)

- **Work-ring entry, 20 bytes:** +0x08 queue fw VA; +0x0c engine (0
  geometry, 1 fragment, 2 compute); +0x10 u16 command-ring head *after* this
  job, modulo 256; +0x12 u8 scheduling slot (compute 0, geometry 1,
  fragment 2); +0x13 a flag (0).
- **Queue:** +0x00 state (state+0x50 = 256 capacity), +0x04 command ring,
  +0x0c scheduling pool (128 × 44-byte entries), +0x44 unit mask, +0x88
  status object.
- **Commands:**
  - Compute: type 3, 0x2c8 bytes. Microsequence at +0x1e8/+0x1ec. The
    completion descriptor starts at +0x26c: stamp address, then the value at
    +0x274.
  - Geometry: type 0. Microsequence at +0x464/+0x468. Free-list descriptor
    at +0x20 and PM slot at +0x24. Scheduling descriptor: +0x550 stamp,
    +0x558 token, +0x55c slot.
  - Fragment: type 1. Microsequence at +0x14/+0x18, context at +0x1c, the
    *geometry job's* free list and PM slot at +0x20/+0x24 (read at
    retirement, fw 0x12b98), and the register blocks in the command itself
    (+0x68 and +0x3b0). Scheduling descriptor at +0x89c/+0x8a4/+0x8a8.
  - The token's bits 8 to 14 pick the scheduling entry. **The slot byte in
    the command must equal the work entry's +0x12.** Otherwise the firmware
    dereferences another slot's engine and crashes (fw 0xf01a).
- **Microsequences** (opcodes from the kext builders):
  - Compute: StartCompute 0xb, Wait 0 (mask << 6; COMPUTE_FINISHED = 4),
    FinalizeCompute 0xc, End 2.
  - Geometry: StartTA 5, Wait `0xe0 << 6` (TA_FINISHED | TA_TERMINATE |
    PM_OUT_OF_MEMORY), FinalizeTA 6, End.
  - Fragment: Start3D 7, Wait `0x8 << 6` (PIXELBE_END_RENDER), Finalize3D 8,
    End.
  - The wait bits are RGX `EVENT_STATUS` bits. The register slot lists are in
    RENDER.md.
- **Evidence:** firmware disassembly, kext builders (`FUN_fffffff006035960`,
  `…35fa4`, `…33898`), and iOS captures of the command buffers.
- **A9:** unknown. Opcode numbers may shift between firmware builds. Find
  the interpreter's table branch (a `TBH` with about 15 entries) and the
  kext builders.

---

## 4. Job submission in the kernel

### 4.1 Path through powervr

Userspace (Mesa's `pvr` winsys) uses the unchanged powervr UAPI. Geometry
and fragment commands carry an Apple **stream extension**
(`PVR_STREAM_EXTHDR_TYPE_GEOM_APPLE`/`FRAG_APPLE`). It holds the StartTA and
Start3D register values that the Rogue command does not have
(`struct pvr_apple_geom_regs`, `pvr_apple_frag_regs`). It is mandatory on
Apple (`pvr_stream_create_musthave_masks()`). Contexts, free lists and HWRT
datasets get no IMG firmware objects (`pvr_context.c`, `pvr_free_list.c`,
`pvr_hwrt.c`).

Each queue is a plain `drm_sched` instance (`pvr_apple_queue.c`).
`pvr_apple_run_job()` calls `pvr_apple_submit_compute_job()` or
`pvr_apple_submit_render_job()`, which call
`pvr_apple_geom_job_init()`/`pvr_apple_frag_job_init()` and then
`pvr_apple_queue_render()`. Each of these returns a hardware fence.

Submission under `submit_lock`:

1. Wait as the ordering rules require (4.3).
2. `pvr_apple_switch_vm()` if the job's VM differs from the one GPU context
   0 runs on.
3. Write the command, microsequence and work-ring entry
   (`pvr_apple_layout_write_*_job()`). `wmb()`.
4. Write the ring's producer index (`seq % 256`). `wmb()`.
5. Send `0x83 << 48` on endpoint 0x21.

### 4.2 Completion and fences

- One dma-fence context per engine (`fence_context + engine`), with seqno =
  the engine's job sequence number. Pending fences sit on per-engine lists
  in order.
- `pvr_apple_poll_work()` acknowledges events, reads each engine's stamp
  (`pvr_apple_engine_done()`: compute heap+0x55004, geometry +0x55010,
  fragment +0x55020) and signals every fence at or below it. While fences
  are pending, an **hrtimer** re-arms it every `apple_poll_us` (default 100
  µs, minimum 10). Any firmware message and any new job also trigger it.
- **Why an hrtimer:** with a jiffy-based delayed work (1 to 2 ms per check)
  every render cost about 4 ms whatever its size, because a render waits
  twice (geometry, then fragment). With 100 µs, an empty render went from
  4.3 to 0.65 ms and a full-screen one from 4.2 to 2.2 ms (commit ace2a81).
- **Why polling:** the firmware posts no completion message, and the RGX
  interrupt goes to the firmware. Using the event ring as a completion
  source instead of stamps is a later improvement.
- **The fragment fence also waits for the fragment-done event.** The
  firmware writes a fragment job's stamp *before* it retires the job. A
  reader outside the GPU, the display above all (the compositor flips on
  the implicit fence), could otherwise see the target before it is complete
  in memory. Retirement is followed by an event of type `(1, 4)`; the poll
  work counts these in `frag_events` and caps the fragment `done` value at
  that count (commit 40bae56). Geometry events are type `(1, 2)`.

### 4.3 Ordering rules and their reasons

**Rule 1: one command area per engine.** Geometry and fragment commands,
their microsequences and their PM state live at fixed heap offsets
(`HEAP_TA_CMD`, `HEAP_3D_CMD`, …). So `pvr_apple_queue_render()` waits for
the engine's previous job (its stamp) before it writes the next one. Compute
has 16 per-job slots (`APPLE_JOB_SLOTS`) and waits for job `seq − 15`.
*Code:* `pvr_apple_wait_engine()`, `pvr_apple_submit_compute()`.
*A9:* this is a choice of our layout, not a firmware rule.

**Rule 2: a geometry job waits for the previous fragment job (any
context).** The firmware takes a geometry job's parameter-manager (PM) state
(one slot, one free-list descriptor, both shared in our layout) and keeps
the scene there until the fragment job on the same slot has run. Scenes are
therefore serialized. *Code:* `pvr_apple_job_add_deps()` adds `last_frag`
as a `drm_sched` dependency, and `pvr_apple_job_armed()` records it.

**Rule 3: a fragment job waits for the last geometry job.** Inside one
`SUBMIT_JOBS`, powervr orders a geometry/fragment pair through the HWRT
reservation, but a job's fence is added only after all jobs have collected
their dependencies. IMG's firmware orders the pair itself; Apple's does
not. With a compute job between two renders, a fragment job overtook its
geometry job, and the next Start3D loaded a null free-list entry and
crashed the firmware (fw 0x1703c → 0x16634). This was seen in the SKU trace
ring: only the fragment dispatch was logged (RENDER.md "Render jobs through
the powervr UAPI"). *Code:* `pvr_apple_job_add_deps()` (`last_geom`).

**Rule 4: before dispatching a geometry job, wait for the previous fragment
job's retirement AND its fragment-done event.** Firmware sequence for a
fragment job: Finalize3D writes the stamp, then the fragment ring's consumer
index advances, then the firmware **retires** the job, which unregisters
free list 0 (code comment: fw 0x13144, `table[id] = 0`, current ids −1;
RENDER.md cites the same retirement as fw 0x130a6), then it posts the
`(1, 4)` event. The next geometry job registers the free list again when it
is dispatched (`table[cmd+0x18] = cmd+0x20`, fw global 0x8dd60). A geometry
job dispatched between the index advance and the retirement had its fresh
registration cleared. The following Start3D then loaded a null entry and
crashed the firmware (fw 0x16634, current id at fw 0x8df60). Hyprland hit
this every few thousand renders. *Code:* `pvr_apple_queue_render()` polls
`pvr_apple_frag_retired()` (ring 1's consumer word, low 8 bits == frag_seq)
and then `pvr_apple_frag_events() >= frag_seq` (20 µs steps, 1 s; a timeout
is logged and the job proceeds anyway). *Result:* 3 × about 3170 renders of
a busy Hyprland session without a hang, where it used to hang within 30 to
130 s (commit a48a98a). *Inferred:* since rule 2's dependency is the
fragment job's fence, and that fence now also waits for the event (4.2),
the poll here is a second guard. The code keeps both.

**Rule 5: the fragment fence signals after the fragment-done event** (4.2).

**Rule 6: one GPU VM at a time.** Only GPU context 0 is used.
`pvr_apple_switch_vm()` writes the new root into T's root array and into
`ROGUE_CR_MMU_CBASE_MAPPING`, then bumps the generation. It first waits
until all engines are idle (`pvr_apple_wait_idle()`). powervr's MMU flushes
only bump the generation (`pvr_apple_mmu_flush()`). This runs without a
lock, because it can be called in atomic context and a mutex there once
wedged the device. When a VM is freed, context 0 goes back to the kernel VM
first (`pvr_apple_vm_fini()`).

**Rule 7: retire a file's jobs before its VM is unmapped.** On file close,
`pvr_destroy_contexts_for_file()` unmaps the client's VM. If the firmware
is still running that client's fragment job, it faults and stops for good:
no later job runs. `pvr_apple_wait_file_jobs()` waits for idle first
(commit f35abc2; `vk-tri TRI_EXIT_NOW`: the first run hung before the fix,
40 of 40 runs clean after).

**Rule 8: drain the event ring.** The firmware spins before posting while
`(producer + 1) & 0xff == consumer` (decompile near fw 0x98d2).
`pvr_apple_ack_events()` sets consumer = producer on every poll.

**Rule 9: indices wrap at 256.** Producer indices and each work entry's
command-ring head are written modulo 256. The firmware advances its
consumer `+1 & 0xff` and scans while it differs from the producer (fw
0x1ff88), so an index that never wraps never matches again.

**Every VM needs GPU VA 0 and the data page.** Fragment jobs write, without
data, to GPU VA 0 at the end of a render. iPadOS has its code heap there,
so the write is harmless. Unmapped, it is a write fault and the job never
signals PIXELBE_END_RENDER. Compute jobs name the driver's terminate and
context-store PDS programs at GPU VA 0x200000. `pvr_apple_vm_init()` maps
both pages into each userspace VM. GPU data addresses must stay below 2^38:
a render with its buffers at 0x40_xxxx_xxxx stalls. So the Apple heaps are
moved below that limit (`pvr_apple_heaps[]`).

### 4.4 Teardown and timeouts

- `pvr_apple_timedout_job()` (5 s) logs a hang report, marks the context
  faulty and returns `DRM_GPU_SCHED_STAT_NO_HANG`. There is **no firmware or
  GPU reset**. A hung firmware stays hung until reboot, and waiters can sit
  in state D.
- `pvr_apple_quiesce()` runs before `pvr_remove()`: wait for idle, signal
  fences, flush `sched_wq` twice (free_job, then the context releases it
  queued).
- `pvr_context_release()` defers queue teardown to `sched_wq`. The last job
  reference can drop inside drm_sched's own free_job work, and
  `drm_sched_fini()` would then wait for itself. `rmmod` hung on this. The
  upstream IMG path has the same structure (DRIVER.md, boot 8).

---

## 5. Races and crashes: what was found and how

| # | Symptom | Cause | How it was diagnosed | Fix |
|---|---|---|---|---|
| 1 | RGX register read panics | Core unpowered | Fender +0x1000 readback 0 | Request state ≥ 1 first (1.5) |
| 2 | Firmware ignores later producer updates | Descriptor flags 2 = write-back mapping | Indices did not move after the initial kick | Flags 0, inner non-cacheable (1.6) |
| 3 | Permission fault at the first Fender write | I/O entry +0x14 = 0 → read-only | CrgA DFSR 0xa0e/0xa0f (LPAE permission fault) | +0x14 = 1 (3.3) |
| 4 | FinalizeCompute write fault 0xff251 at VA 0 | Q (flush scratch) missing | MMU fault register RGX+0xe150 (64-bit decode) | Q = 0x203000 |
| 5 | Crash at fw 0xf01a | Command slot ≠ work-entry slot | Crashlog pc | Matching slot bytes (3.5) |
| 6 | Fragment never ends, write fault at VA 0 | End-of-render write to VA 0 | Fault requester 9/25; a 0xaa-filled page stays unchanged | Zero page at VA 0 |
| 7 | Hang always at job 256 | Event ring full, firmware spinning | "1 in 300" turned out to count jobs since load | Ack events (rule 8) |
| 8 | No progress after the first ring wrap | Unwrapped indices | Same experiment; firmware compare at fw 0x1ff88 | Modulo 256 (rule 9) |
| 9 | Start3D crash after a compute job between renders | Fragment overtook geometry | SKU trace ring: only the fragment dispatch logged | Rule 3 |
| 10 | Firmware stuck after a client exits mid-frame | VM unmapped under a running job | Hang report: geometry done, fragment never | Rule 7 |
| 11 | Hyprland hang every few thousand renders | Free-list registration race (fw 0x16634) | `dyndbg=+p` showed it was a firmware *crash*, and the crashlog's pc and registers pointed at Start3D | Rule 4 |
| 12 | Display may read an incomplete target | Stamp before retirement | Code reading of the firmware sequence | Rule 5 |
| 13 | Geometry hang on very heavy scenes | PM out of memory: the microsequence finalizes an unfinished scene | `apple_pm_trace`: the light scene posts `(1,2)` with 0x445 pages, the heavy one posts nothing | **Open** (partial renders). Stopgap: Mesa's shared free list grown to 32 MiB |
| 14 | `rmmod` hangs / `WARN_ON(!xa_empty)` | drm_sched self-deadlock; jobs outliving remove | sysrq `w`, `/proc/kmsg` over USB SSH | Deferred release, quiesce |
| 15 | GPU slow, 2× | Performance state 1 | Power struct fields read 0; DVFS step never runs | `apple_perf_state=6` |

Notes on #11 and #13: MESA.md first attributed the Hyprland hang to a
parameter-memory leak ("The hang is a parameter-memory leak"). A later
entry ("Two hangs, not one", "The hang fixed") splits it into #11 and #13.
Prefer the later reading.

### 5.1 Tools

- **Firmware messages:** `modprobe powervr dyndbg=+p` (they are `dev_dbg`
  in `pvr_apple_recv_message()`). This is how #11 was found to be a crash
  and not a stall.
- **Crashlog:** `apple-rtkit` hands it to `pvr_apple_crashed()`, which
  hex-dumps all of it. Section tags are stored byte-reversed (`AgrC` =
  CrgA). The CrgA payload holds a type word (4 = data abort, 0x10020 =
  software panic), then r0–r12, sp, lr, pc, cpsr, then DFSR/DFAR-like words
  in LPAE format (FENDER.md §9.1, §16.1). Map the pc into the disassembled
  image.
- **`apple_pm_trace=N` (removed from the driver on main, b5e3769; in the
  dev/gpu-a10 history):** logged every event before acknowledging it,
  dumped the free-list descriptor, PM state and PM slot every Nth geometry
  job, and checked the free list's page stack for changed, foreign and
  repeated entries. Re-add it from that history when a parameter-memory
  problem needs it.
- **Hang report:** `pvr_apple_report_hang()` prints stamps, submission
  counters, the fragment-retired word, ring producers and event indices. A
  stamp below the job means the firmware never finished it. A stamp at or
  past it means the completion was missed.
- **Firmware trace rings:** with U+0 = 3, the SKU debug ring (heap
  0x70000, 36-byte records) logs ring dispatch (0x111), StartTA/FinalizeTA
  (0/1), Start3D/Finalize3D (4/5), compute (7/8) and event handling
  (0x102/0x103). The heap can be read with `dd if=/dev/mem` at its physical
  address (`dev_info` prints it at init).
- **GPU MMU faults:** read RGX+0xe150 as 64 bits. The address is
  `(status >> 28) << 4`, the requester bits 6..11, read bit 3, valid bit 0
  (COMPUTE.md "Fault and trace decoding").

**A9:** all of these tools carry over as methods. Every address in this
section must be found again in the A9 firmware.

---

## Open questions

1. Hang recovery: no firmware or GPU reset after a timeout. A malformed PDS
   program from userspace wedges the GPU until reboot.
2. Partial renders on PM out-of-memory (#13). iPadOS presumably uses the
   kext's `encodePartialRenderSetup`. Fragment partial-render jobs return
   `-EOPNOTSUPP`.
3. Runtime power management and DVFS: what schedules the firmware's DVFS
   step (fw 0x6a98), and what P and the power struct must hold for it.
   Suspend and resume of the firmware are not implemented.
4. The mailbox interrupt bit mapping and DT order (1.2).
5. The meaning of P+0x00..+0x27 other than the code bases, of P+0x928, and
   of the shared page at R+0x110000 when entry 0 is real Fender. FENDER.md
   §19.4 says it is not the live shared page, so ready is read from U+0x14.
6. Whether the RAM-backed I/O entries 1, 2, 4, 5, 6 are needed.
7. Events as the completion source instead of polling stamps.
8. More than one GPU context: only context 0 is used, so VM switches
   serialize all engines.
9. The A9: firmware image location, endpoint numbers, Fender presence and
   its power register, the init-page offsets and the ring layout. All
   unknown. Start with the HELLO, the EPMAP and the 0x81 handler's strings.

---
