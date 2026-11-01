# T8010 GPU: Fender, RGX and gfx-kf (AKF) from the iPadOS 17.7.11 kernelcache

**Current handoff (2026-10-29): [COMPUTE.md](COMPUTE.md), experiments 16–54.**
This file preserves chronological RE notes, including superseded predictions.
Section 22 and COMPUTE.md take precedence over earlier "next run" advice.
Real GPU terminate-only completion works (46, repeated); PDS/USC instruction
execution and full acceleration are not proven. The offline findings and failed
hardware follow-up are in [PDS-OFFLINE.md](PDS-OFFLINE.md).

Offline reverse engineering of `kernelcache.release.iPad7,5_6` (21H461), no
device access. Addresses are kernel VAs in that kernelcache (`__PLK_TEXT_EXEC`
unless noted). "fw+0x…" is an offset into the GFX firmware image.
Confidence: **high** = read directly from code; **medium** = code plus live
values agree; **low** = inference.

## Bottom line

- The normal iOS path lets GFX firmware request core power through Fender.
  **The AP can mirror that request:** section 18 confirmed
  `Fender+0x1000 = 0x11` powers RGX and permits identity reads. The earlier
  hypothesis that only firmware could do this was too strong.
- Reading `RGX_CR_*` before power is acknowledged faults. The old AP request
  at Fender+0x10 was insufficient; do not confuse it with the working +0x1000
  state request. The original MMU fault is now resolved; real terminate-only
  completion works. Current blocker: non-empty PDS/USC dispatch, documented in
  section 21 and COMPUTE.md.

## 1. Fender and RGX

### 1.1 Which window is which (high)

`0xfffffff00600eb08..ed14` switches on the provider's
`getDeviceMemoryCount()` (vtable +0x3c0, jump table at `0xfffffff0054e8f87`)
and maps reg indices with `getDeviceMemoryWithIndex()` (vtable +0x3c8). The J71b
`sgx` node has **2** reg entries, which selects case `0xfffffff00600eb74`:

| Global | Reg index | Physical (J71b) | Meaning |
|---|---|---|---|
| `0xfffffff007b36870` | 0 | `0x201000000` | RGX |
| `0xfffffff007b36878` | 1 (`…b36865` = 1) | `0x201d00000` | **Fender** |
| `0xfffffff007b36880` | `…b36866` (none here) | — | UVD |

### 1.2 IO-mapping table handed to the firmware (high)

`AGXAccelerator::configureDevice` (`0xfffffff005ff2818..3d6c`) fills
0x98-byte entries starting at `this+0x5e0`: `+0` valid, `+4` flag, `+8`
physical base, `+0x88` size, `+0x90` name. These are the same names as Asahi's
M1 initdata IO mappings.

| Entry | Base | Size | Evidence |
|---|---|---|---|
| FenderRegs | vtable+0x7c8 getter → Fender (reg 1) = `0x201d00000` | **0x5000** | `…3364..337c` |
| AICTimerRegs | `0x20e101000` (masked) | page | `…33a8..33c0` |
| AICSWIntRegs | `this+0x4490` | page | `…33c4..33e4` |
| RGXRegs | `[0xfffffff007b36870]` = `0x201000000` | **0x20000** | `…33e8..340c` |
| UVDRegs / Unused | vtable+0x7d0 getter | — | `…3410..3440` |
| DisplayUnderrunWA (G9P) | `0x200800000` | 0x1000 | `0xfffffff006034d3c..d60` |
| TempSensorRegs (G9P) | `0x20e0c0020` | 0x1000 | `0xfffffff006034d7c..d9c` |
| remaining (PMPDoorbell, PMGRScratch, Metrology…) | marked unused on G9P | | `…3448..3514` |

Live data fits: Fender is 20 KB (`+0x0000..+0x4fff`). The coordinator's
faults at `+0x4000`/`+0x5000` are the fifth Fender page and past the end.
`+0x0000..+0x3fff` are readable with GFX on.

### 1.3 AGXFender on G9P (high)

- The constructor `0xfffffff0060326d8` installs the **base** vtable
  `0xfffffff006e1c310` directly, and no derived vtable exists. Every ConfigRAM
  and power-gating method (`initConfigRAMOffset`, `incrementConfigRAMOffset`,
  `terminateConfigRAMSequence`, `writeConfigRAMCommand32/64`,
  `didGPUWakeUp`, `isPoweredOffWaitingForKicks`, `…TimerSleepControl`,
  `…DynamicFenderGating`, slots 11–27) is a **panic stub**
  (`0xfffffff006032bb8 + 0x34·n`).
- So **the kext never writes ConfigRAM on A10**. The coordinator's latched
  24-bit register at `0x201d00000` (write `0x12345678`, read back
  `0x00345678` on the next write) is not touched by any AP code. It is
  probably a firmware-side ConfigRAM/sequencer address port; the command format
  is not recoverable from the kext. (low)
- Base-class methods that do touch Fender MMIO (`this+0x10` is the Fender
  mapping; slot 0 `0x…2a94` stores it):

| Slot | Code | Access | Reading |
|---|---|---|---|
| 3 | `0x…2ae0` | `rd +0x1000`, returns `& 0xf` | state nibble (live `+0x1000` = 0) |
| 4 | `0x…2b00` | `+0x10 |= bit(arg)` for arg 0/1/2, otherwise 0; then read back | request register |
| 5 | `0x…2b38` | `+0x14`: if non-zero, write back `& 7` | W1C status, bits 0–2 |
| 8 | `0x…2b78` | dummy reads of `+0x10 +0x14 +0x1000 +0x200c +0x2010 +0x2014 +0x2018 +0x201c +0x2020` | touch/dump |
| 10 | `0x…2ba8` | `rd +0x10 & 1` | request bit 0 active |

  Slot names are unknown (no strings). Callers weren't found in the time
  available. Live non-zero Fender words (`+0x1004`=8, `+0x2000`=7,
  `+0x2040`=6, `+0x2050`=0xF, `+0x2054`=0x2F) are not read by any AP code
  found. The kext's float accesses at struct offsets `0x2040/0x2050/0x2054`
  are an in-memory struct, not MMIO.

### 1.4 Who powers RGX: the firmware (high)

The GFX firmware (section 3) contains `agfPowerHandlePowerUp`,
`agfPollFenderReg`, `"GPU is not powered on after power kick!"`
(fw+0x2f74b, reached from the branch at fw+0x1b4e8), `"GPU is Powered On
while we are about to Power down Fender"`, `AGFHALExecuteResetSequence`,
`AGFAInitSequence`, and `"Unable to register init sequence memory"`. The
power-up path (fw+0x1b3be) signals a task with `fw+0x1c4d4(1)` and then checks
a software flag, so the actual Fender writes go through the firmware's own
IO-mapping VAs, which aren't decoded yet. **Init sequences come from the
host's init data**, the same model as Asahi.

### 1.5 Proposed AP-side Fender experiment (low; may still fault)

Only if we want to try before booting the firmware:

```sh
devmem 0x20e080328 32 0x0F0001FF                  # ps_gfx f/f (known safe)
for o in 0x10 0x14 0x1000 0x200c 0x2010 0x2014 0x2018 0x201c 0x2020; do
  devmem $((0x201d00000 + o)) 32; done             # the set slot 8 reads (all inside safe pages)
devmem 0x201d00010 32 0x1                          # slot 4 with arg 0: request bit 0
devmem 0x201d00010 32; devmem 0x201d00014 32; devmem 0x201d01000 32
# Only if +0x1000 & 0xf changed: try RGX_CR_CORE_ID 0x201000018
```

Expect this to be insufficient. On A10 the firmware runs the init sequence.

## 2. gfx-kf: AppleA7IOPV2 register map (high unless marked)

Base = gfx-kf reg 0 = `0x201d20000`. Accessors: `readReg32(off)` is vtable
+0x640 = `0xfffffff006c412b0` (`ldr w0, [base + off]`). V1 (`0x1000…`, CPU at
`0x28`) reads zero live. V2 offsets match the live non-zero values.

| Offset | Name / use | Code | Live |
|---|---|---|---|
| `+0x44` | generic V2 run bit 4. **Not used for GFX:** V2GFX overrides the run setter with `0x201d02048` bit 0 (section 4) | `0x…410c4` | 0 |
| `+0x48` | ? (status) | — | 0x79 |
| `+0x80c` | timebase sync: clear bit 1, write time, set bit 1 | `0x…4114c` | 0x2 |
| `+0xc030/+0xc038` | 64-bit timebase lo/hi | `0x…41198..41a8` | `+0xc030`=0x1A2713B0 |
| `+0xc004`=0x11, `+0xc024`=1 | IRQ config written together | `0x…4112c` | — |
| `+0xb88` | bit 0 read by a status getter (meaning unknown; not AKF_RUNNING, low) | `0x…40db4` | 0x00020001 |
| `+0x4000` | MAILBOX_SET (irq mask set): inbox = 0x1, outbox = 0x1000; init writes 0x1111 | `0x…40e2c/44/a4` | 0 |
| `+0x4004` | MAILBOX_CLR (irq mask clear), same bits | same | 0 |
| `+0xc00/+0xc04` | mirrors of SET/CLR (written alongside) | same | 0x1111 / 0x1111 |
| `+0x4008` | INBOX_CTRL: bit 17 empty (`_getInboxEmpty`), bit 16 full; bits 18–19 error → panic path | `0x…40dd8/e08` | 0x00081001 (bit 19 set!) |
| `+0x4010` | **send** (64-bit write) | `0x…40da4` | — |
| `+0x4020` | OUTBOX_CTRL: bit 17 empty; bit 0 = enable (rmw) | `0x…40e74/ed4` | 0x00081001 (bit 19 set!) |
| `+0x4038` | **receive** (64-bit read) | `0x…40d94` | — |
| `+0x4040` | IDLE_STATUS (V2 dump label) | `0x…40f20` | 0x59 |

Minimal start sequence (medium; the order is inferred from the individual
accessors, not from one traced boot function):

1. ps_gfx on (f/f).
2. Firmware placed and mapped for the core (not recovered here; see section 3
   for the image).
3. Mask setup: `+0x4000 = 0x1111` and `+0xc00 = 0x1111`, then unmask inbox
   and outbox with `+0x4004 = 0x1` and `+0x4004 = 0x1000` (mirrored at `+0xc04`).
4. `+0xc004 = 0x11`, `+0xc024 = 1`.
5. Timebase: `+0x80c &= ~2`; `+0xc030 = lo`, `+0xc038 = hi`; `+0x80c |= 2`.
6. Enable outbox: `+0x4020 |= 1`.
7. Start: for GFX this is `0x201d02048 |= 1`, not `+0x44` (section 4).
8. Wait until `+0x4020` bit 17 clears, then read 64 bits at `+0x4038`. That
   should be the RTKit hello (the RTKit protocol is the same as mainline
   `apple-rtkit`).

Open: bit 19 set in both INBOX_CTRL and OUTBOX_CTRL live sends the kext's
empty-check down the error path. Either the mailbox isn't initialized or
clocked until steps 3–5, or bit 19 means something else on this IP revision.
`AppleA7IOPV2GFX::initialize` (`AppleA7IOPV2GFX.cpp`; class strings near
`0x…4130c/413dc/41718`) wasn't decoded, so GFX-specific extra steps may exist.

## 3. Firmware image (addresses only; extraction is handled elsewhere)

- `AGXFirmwareKextG9PRTBuddy::requestFirmwareBinary` = `0xfffffff0065e4078`.
  For core config type 3 it returns ptr `0xfffffff005655edf` (file offset
  `0xd41edf`) and size `0x5b320`.
- Neighbouring getters at `0xfffffff0065e4140` (returns 0 for type 3) and
  `0xfffffff0065e4190` (returns string `0xfffffff005655ed6`). Which of
  getBootConfigOffset/getRuntimeBinSize/getBuild each one is wasn't resolved.
- The image is **32-bit ARM** (A32 vector table, then Thumb-2), load base 0:
  absolute `movw/movt` pairs equal file offsets, e.g. fw+0x2f4a5
  `agfPollFenderReg`.

## Open questions

1. Fender register semantics: the `+0x10` request bits, the `+0x1000` state,
   and the latched 24-bit register at `+0x0`, plus the ConfigRAM data port.
   These need the firmware's Fender accesses, i.e. its IO-mapping VAs.
2. Where AGX places the firmware and how gfx-kf sees it (the IOP address
   window): `_mapFirmware` for V1 and V2 are panic stubs, so V2GFX or AGX
   does this.
3. The meaning of bit 19 in the mailbox control registers and of `+0xb88`.

## 4. Booting the GFX firmware

### 4.1 Class layout (high)

`AppleA7IOPV2GFX` vtable `0xfffffff006fe3ef8`, against `AppleA7IOPV2`
`0xfffffff006fe3768`. GFX overrides:

| Slot | V2 | V2GFX | Role |
|---|---|---|---|
| 0x610 | `0x…5d71630` (returns 1) | `0x…414f4` | **initialize**: `provider->mapDeviceMemoryWithIndex(1)` → `this+0x178/0x180`, then V2::initialize. Reg 1 of `gfx-kf` = **`0x201d00000`** (the window shared with `sgx`, i.e. Fender). Call this mapping **W**. Reg 0 = `0x201d20000` = `this+0x100` (**A**). |
| 0x640 | readReg32 on A | same body on A | — |
| 0x6a0 | `_mapFirmware` (`0x…41028`) | `0x…4155c`: writes W, then tail-calls V2's | firmware window |
| 0x6b0 | run: `A+0x44` bit 4 (`0x…410c4`) | `0x…415fc`: **`W+0x2048` bit 0**, no chain to V2 | **CPU run** |

The generic boot routine `AppleA7IOP` `0x…5d716fc` calls `_mapFirmware`
with **IOP address 0** (`mov x1, #0` at `0x…5d717e0`).

### 4.2 Firmware window registers (high: offsets and fields; medium: semantics)

`_mapFirmware(iopAddr, md, opts)` writes both copies:

| Field | V2GFX copy in W (`0x201d00000+`) | V2 copy in A (`0x201d20000+`) |
|---|---|---|
| physical base lo / hi (`md` physical address) | `+0x200c` / `+0x2010` | `+0x08` / `+0x10` |
| IOP address lo / hi (= 0) | `+0x2014` / `+0x2018` | `+0x18` / `+0x20` |
| length `& ~0xfff` | `+0x201c` | `+0x28` |
| 0 | `+0x2020` | `+0x30` |
| enable | — | `+0x38 = 1` (live already 1) |

The V2 copy runs only if a descriptor check passes (`bl 0x…41e38`, bit 0).
Otherwise it takes a panic stub, which is probably a contiguity check (low).
These `W+0x200c..0x2020` registers are exactly what `AGXFender` slot 8
dummy-reads. No DART is involved: the core sees **physical memory through
this remap**.

### 4.3 Memory requirements (high: values; medium: alignment)

- Image: 0x5b320 bytes (ARM32/Thumb-2, load base 0), copied to offset 0.
- Region: **getRuntimeBinSize = 0x8f000** (`0x…4250`). Zero everything after
  the image (BSS and heap).
- One **physically contiguous** block (a single base register pair). The
  length field is masked to 4 KiB, so use a page-multiple length (0x8f000
  already is) and at least 4 KiB alignment. Use 16 KiB or more to be safe;
  the alignment requirement is inferred.
- getBootConfigOffset = 0, getFWResumeFlagOffset = 0 and
  getFWPdumpBinPatchDataOffset = 0 for G9P. Offset 0 holds the vector table,
  so 0 most likely means **unused on this core** (medium). No boot config is
  patched into the image for a cold boot.
- Requirement for the core's view: it addresses physical memory via the remap
  only. Caches: copy the image, then clean the D-cache or use an uncached
  mapping before the run bit.

### 4.4 Minimal boot sequence (medium; order from `0x…5d716fc`)

1. `ps_gfx` → f/f (`0x20e080328`). iOS's prepare step is
   `provider` power/clock (`vt+0x568/0x570` with 1), plus a `"setActive"`
   platform function (slot 0x6c8). Our ps_gfx write covers this. (medium)
2. Allocate 0x8f000 contiguous bytes at P (≥16 KiB aligned), copy the image,
   zero the rest, flush.
3. Window (both copies, as `_mapFirmware` does):
   ```sh
   devmem 0x201d0200c 32 $((P & 0xffffffff)); devmem 0x201d02010 32 $((P >> 32))
   devmem 0x201d02014 32 0; devmem 0x201d02018 32 0
   devmem 0x201d0201c 32 0x8f000; devmem 0x201d02020 32 0
   devmem 0x201d20008 32 $((P & 0xffffffff)); devmem 0x201d20010 32 $((P >> 32))
   devmem 0x201d20018 32 0; devmem 0x201d20020 32 0
   devmem 0x201d20028 32 0x8f000; devmem 0x201d20030 32 0
   devmem 0x201d20038 32 1
   ```
4. Mailbox (slots 0x660/0x698/0x670/0x678, already verified live):
   `A+0x4000 = 0x1111` and `A+0xc00 = 0x1111`; then `A+0x4004 = 1` and
   `A+0xc04 = 1`; `A+0x4004 = 0x1000` and `A+0xc04 = 0x1000`; `A+0x4020 |= 1`.
5. Timebase (slot 0x6c0, only if the `force-timebase-sync` property is
   present, which gfx-kf has): `A+0x80c &= ~2`; `A+0xc030` = CNTVCT lo;
   `A+0xc038` = hi; `A+0x80c |= 2`.
6. **Run:** `devmem 0x201d02048 32 $(( $(devmem 0x201d02048) | 1 ))`.
7. Poll `A+0x4020` until bit 17 (empty) clears, then read 64 bits at
   `A+0x4038`. Expect an RTKit management HELLO (endpoint 0). Reply via
   `A+0x4010`.

### 4.5 What the firmware needs before HELLO (medium)

- Nothing but the image, the zeroed runtime area, the window, the mailbox and
  run. RTKit sends HELLO on its own.
- AGX init data comes **after** HELLO, over an RTKit endpoint: firmware
  strings `"Unable to grab init data from host"` and `"Unable to register
  init data at PA_%llX"`. Those mean the IO-mapping table (FenderRegs,
  RGXRegs…), init-sequence memory and so on, all sent after RTKit is up.
  Fender and RGX don't need to be up for HELLO; the firmware powers them
  later using that init data.
- RTKit build is `RTKit-2419.140.12`. Version compatibility with mainline
  `apple-rtkit` (HELLO min/max) is unverified. (low)

### 4.6 AGXSecureGart

Not involved in firmware boot. The only string is `AGXSecureGart::unmap`;
the firmware is reached through the IOP remap in 4.2. It's probably the GPU
address space or protected-buffer GART used after init. Not decoded. (low)

### 4.7 Open

- The descriptor check at `0x…41e38` before V2's window write: if it's a
  contiguity or alignment check, our P must satisfy it.
- Whether both window copies are required, or only W (GFX) or only A (V2).
  iOS writes both.
- `W+0x2048` other bits. The live block `W+0x2000=7, +0x2040=6, +0x2050=0xF,
  +0x2054=0x2F` and A's `+0xb80..+0xbbc` / `+0x800..+0x81c` aren't written by
  any V2/V2GFX code found. They're probably iBoot or hardware defaults.

## 5. RTKit framing on the A7IOP mailbox (high)

**One 64-bit word per message; endpoint = bits 63:56, payload = bits 55:0.**
There is no second register (no msg1).

- **Hardware layer (AppleA7IOP/V2):** `sendMessage` (vtable 0x590,
  `0x…5d723b0`) → slot 0x638 `0x…40da4`: one `str x` to `A+0x4010`.
  `receiveMessage` (vtable 0x598, `0x…5d721a0`) → slot 0x630 `0x…40d94`: one
  `ldr x` from `A+0x4038`. Queue entries are 8 bytes (`0x…5d7421c`,
  `0x…5d7229c` steps `x20 += 8`). Use **single 64-bit accesses**
  (`readq`/`writeq`); the code never splits them. (medium on whether a
  32-bit split also works.)
- **RTBuddy receive** `0x…5d8032c`: `msg = IOP.receiveMessage()`;
  `ep = msg >> 56` (`lsr x20, x8, #56` at `0x…5d80368`);
  `payload = msg & 0x00ffffffffffffff` (`0x…5d8036c`); then the endpoint
  lookup `0x…5d89ba4(ep)` and dispatch. An unknown endpoint goes to
  "message %llx for unknown endpoint %d" (`0x…5da0e9c`).
- **RTBuddy send** `0x…5d803c0(ep, &msg)`: needs `this+0x140 >= 4` (else
  error 0xe00002d7|0x15) and `ep < this+0x2200`. The payload's top byte must
  be 0 or already equal `ep`. Then
  `word = (msg & 0x00ffffffffffffff) | (ep << 56)` (`0x…5d803f4..0x…5d8040c`)
  → `0x…5d89940` → IOP send.
- **Live check:** HELLO `0x00100000000C000C` → ep 0 (management), payload
  `0x0010000000_0C000C` = type 1 (bit 52) HELLO, min = max = 12. That's
  consistent.
- **Mainline `apple-rtkit` fit:** management/crashlog/syslog type fields
  (bits 59:52) only use values below 0x10, so they fit in bits 55:52, and
  EPMAP (51:32), STARTEP (39:32) and buffer IOVA (43:0) all sit below bit 56.
  A mailbox backend that maps `{msg0, msg1 = ep}` ↔
  `(ep << 56) | (msg0 & GENMASK_ULL(55, 0))` should drive the existing RTKit
  core unchanged. Reject any `msg0` with bits 63:56 set.
- Paul's `apple-sio-core.c` endpoint in bits 7:0 belongs to the SIO firmware's
  own payload protocol, not this transport.

**`A+0x4040` is IDLE_STATUS, not a receive word (high).** The V2 register dump
`0x…40f20` reads `+0x4040, +0x4000, +0x4004, +0x4008, +0x4020` into the
format `"IDLE_STATUS / MAILBOX_SET / MAILBOX_CLR / INBOX_CTRL / OUTBOX_CTRL"`
(string `0xfffffff0059c5bfe`). `+0x4040` is first, so it's IDLE_STATUS. The
only receive path is `+0x4038`.

## 6. Doorbell, wake and IDLE_STATUS

> **Hardware correction (2026-10-29):** the clean RTKit handshake needs **no**
> doorbell. Writing `+0xc004/+0xc024` during the handshake made the firmware
> stop reading its inbox. The doorbell belongs only to RTBuddy's
> power-transition path (6.1), so don't use it in the normal send path.

### 6.1 ringDoorbell (high)

- `AppleA7IOP::ringDoorbell(int)` = `0x…5d71f4c`, at vtable slot **0x558**
  (V2GFX `0xfffffff006fe4450`). Only an argument of 1 is valid; any other
  value prints "spurious ringDoorbell call". It requires the started flag
  (`this+0x108`), then calls slot **0x6b8** → V2 `0x…4112c` (V2GFX does not
  override it):

  ```sh
  devmem 0x201d2c004 32 0x11     # A+0xc004
  devmem 0x201d2c024 32 0x1      # A+0xc024
  ```

  So the writes I earlier labelled "IRQ config" (section 2) **are the
  doorbell**. The boot routine never writes them.
- **`sendMessage` does not ring it.** RTBuddy send `0x…5d89940` → provider
  vt 0x590 `0x…5d723b0` → `A+0x4010`, retrying for up to 1 s on "full". No
  doorbell anywhere on that path.
- **RTBuddy rings it in its power-transition routine** `0x…5d89da0`: for
  target state 0 it sets `this+0x140 = 0x8001` (`0x…5d89eac`) and calls
  `provider->ringDoorbell(1)` (`0x…5d89eb8..ec8`). For other targets it
  sends a power-state message instead (`0x…5d88f34`). The wake protocol is
  therefore: **when the IOP has gone to sleep, ring the doorbell, then send.**
  (medium on the exact trigger condition; high on the mechanism)
- Other callers of slot 0x558 to check if needed: `0x…5d76974`,
  `0x…5d84e6c` (an endpoint buffer path that calls it with w1=0, which is a
  different object type), `0x…5d904b4`, `0x…5d93234`.

### 6.2 Timebase and +0xc004/+0xc024 (high)

- Timebase sync (`+0x80c`, `+0xc030/+0xc038`, slot 0x6c0 `0x…4114c`) runs
  once at boot if `force-timebase-sync` is set (`this+0x15d`). It isn't part
  of wake. The firmware uses it for timestamps; skipping it shouldn't block
  the mailbox. (medium)
- `+0xc004 = 0x11` / `+0xc024 = 1` are not boot configuration. They are the
  doorbell (6.1). Use them to wake the sleeping IOP.

### 6.3 IDLE_STATUS `A+0x4040` (low)

The GFX idle check (vt 0x6d8) is a generic stub that always reports idle
(`0x…5d71e94`), and V2 only prints `+0x4040` in its dump (`0x…40f20`). **No AP
code interprets its bits.** Observed: 0x79 before boot, 0x61, 0x6F, 0x4F. Bit 0
was always 1; 0x4F (asleep after the RTKit sleep counters) differs from 0x6F
only in bit 5. Treating bit 5 as "awake/active" is a guess to check against
the doorbell.

### 6.4 GPU command kick, for later (medium)

`AGXArmFirmware::kickFirmware` (`0x…6022640`, `0x…60225d4`) is an RTKit
message, not MMIO: payload `0x0083000000000000 | ((ring & 7) << 2)` (and a
`| 2` variant), sent through the AGX endpoint object (`this+0x1070`,
vt +0x568). It's the Asahi-style type-0x83 kick on a firmware endpoint.

### 6.5 Suggested next step (superseded: see the correction above)

After STARTEP and IOP_PWR_STATE ON, when INBOX_CTRL shows an unread message
(bit 17 clear) and the firmware's sleep counters move: write the doorbell
(`A+0xc004 = 0x11`, `A+0xc024 = 1`), then poll OUTBOX_CTRL bit 17. If replies
resume, ring before each send whenever the IOP may be asleep (as RTBuddy does
on its power transitions).

## 7. AGX init on endpoint 0x20 (scoping)

Class: the AGX firmware object with vtables `0xfffffff006e19ae0` /
`0xfffffff006e1afc8` (two variants). `this+0x1f0` is the AGXAccelerator.
Per-endpoint state is in 0x30-byte slots starting at `this+0x1070`:
`+0x1070` RTBuddy endpoint object, `+0x1078` init buffer, `+0x1090` flag,
`+0x1098` timestamp.

### 7.1 Messages on the AGX endpoint (high: encoding; medium: meaning)

All are RTKit payloads, so bits 55:0 under section 5's framing (the endpoint
goes in 63:56). The type is in bits 55:48.

| Type | Payload | Sender | Meaning |
|---|---|---|---|
| **0x81** | `0x0081 << 48 | (PA & 0xfffffffffff)` | `0x…602cb48` (vt slot 0x890), sent via endpoint vt+0x558 | **init**: physical address of the init buffer (`getPhysicalAddress()` = `0xfffffff007806f54` → `getPhysicalSegment(0,0,0)`) |
| 0x83 | `0x0083 << 48 | ((ring & 7) << 2) [| 2]` | `0x…6022640`, `0x…60225d4` | kick |
| 0x84 | `0x0084 << 48` (no payload) | `0x…602312c`, `0x…602dd70` | sync: afterwards the kext waits until ring `this+0x10c8` has read == write (`+0x10` vs `+0`) |
| 0x85 | `0x0085 << 48 | (acc+0x538 & 0xfffffffffff)` | `0x…6021ba8` | power-related request with a counter or value; waits `acc+0x23c`·1000 |

So the first EP 0x20 message after RTKit boot should be **0x81 with the init
buffer's physical address**. EP 0x21 is probably the second slot
(`this+0x10a0`); unverified.

### 7.2 Address space (medium)

- The 0x81 payload is a **physical address**, matching firmware strings
  `"Unable to register init data at PA_%llX size:%u"` and `"... init mem desc
  at PA_%llX"` / `"init sequence memory at addr %llX"`. So the firmware maps
  physical memory itself (its own MMU/translation); the kext does **not**
  program extra IOP remap windows for this. (medium)
- After init, the firmware works with **GPU virtual addresses**:
  `AGXArmFirmware::notifyNewMapping(GPUVirtualAddress, IOPhysicalAddress,
  bool)` (string `0x…6023028`, code around `0x…6023040..6023124`) pushes
  (VA, PA, flags) records into a shared ring (`this+0x10e8`) and triggers the
  0x84 sync. The firmware likely builds the Rogue MMU tables from these. Not
  decoded.

### 7.3 Host memory set up before init (high: allocation; low: content)

`0x…601ed6c` (vt slot 0x98) runs before the 0x81 message:

| Field | Size | Notes |
|---|---|---|
| `this+0x1078` | 1 page (16 KiB; `1<<12` from vt+0x288 rounded to the page) | **init buffer**, PA sent in 0x81 |
| `this+0x10a0` | 1 page | second slot / EP 0x21? |
| `this+0x1080` | 1 page (16 KiB rounding) | — |
| `this+0x10b8..0x10e0` | — | descriptor for **two rings** (type 7), created through vt+0x160 |
| `this+0x10e8` | — | object from `0x…5294c`; mapping/notify ring |
| `this+0x1108` | `acc+0x1850` base, `acc+0x18d0` size | an extra physical region mapped for the firmware (cache mode 3 or 1 depending on `acc+0x1848`) |
| `this+0x10b0` | `acc+0xc6c` entries from `acc+0xc70[]` | physical-range list → IOMemoryDescriptor (direction 3), mapped with options 0x101 |
| `this+0xc40` | 8 × 0x40 | `AGFICmdQueueSchedState` queue |

The routine also requires all 31 IO-mapping entries (`acc+0x5e0`, stride
0x98, flag at +4) to have flag ≤ 1 (section 1.2). These entries are the
FenderRegs/RGXRegs/AICTimer/… table the firmware gets.

### 7.4 Init data content (not decoded)

- The 16 KiB init page's **field layout hasn't been read yet**. Users of
  `this+0x1078` to decode next: `0x…601f550`, `0x…601fa2c`,
  `0x…601fb04/1fb18`, `0x…6021758`.
- Inputs known to feed it: the IO-mapping table (section 1.2), the `sgx`
  ADT power properties read in `configureDevice` (`gpu-pwr-*`, `gpu-perf-*`,
  `perf-states`, `perf-states-sram`, `gpu-keepalive-*`, `gpu-idleoff-*`,
  `meta-sw-interrupt`, `interrupts`), the queue/ring descriptors (7.3), and
  the firmware's init-sequence memory (Fender power sequence;
  `AGFAInitSequence`).
- Firmware side: "Unable to grab init data from host" and
  `AGFAInitSequence unknown seq type %u` (fw+0x2f3b4 / fw+0x2f5c3) give the
  consumer for cross-checking.

### 7.5 Remaining RE (estimate)

| Item | Effort | Notes |
|---|---|---|
| Init page layout (fields written via `this+0x1078` users) | 1–2 days | AP side; mostly copying table values |
| Ring formats (two rings, mapping/notify ring, event/stat/trace rings from section 1.4 strings) | 2–3 days | AP and firmware |
| Init-sequence (Fender) format | 1–2 days | firmware `AGFAInitSequence`; needed for GPU power-up |
| GPU VA / MMU model (`notifyNewMapping`, Rogue MMU) | 2–4 days | needed before any command |
| Command submission (TA/3D channel commands, 0x83 kick) | weeks | Asahi-shaped; userspace (Mesa pvr) is a separate track |

The first two are enough to get the firmware to accept init and power the
Rogue core, i.e. to read `RGX_CR_CORE_ID` via the firmware path.

## 8. Firmware side of init (GFX firmware, fw offsets, load base 0)

Disassembled as Thumb-2. The init handler is **fw 0x179e0** (task
`agx_background`).

### 8.1 Message 0x81 (high)

```
0x179f4  r = rtk_recv(ep = 0x20, &msg, timeout = -1)        ; bl 0x279e0
0x17a0c  hi = msg >> 32;  require (hi & 0x00bf0000) == 0x00810000   ; type 0x81 (or 0xc1)
         else "Unable to grab init data from host" (0x17a18)
0x17a24  pa = (hi & 0xfff) << 32 | lo32(msg)                 ; 44-bit PA, NO shift
0x17a3a  map(pa, size = 0x1000, &va, &desc)                  ; bl 0x2a038
         fail → "Unable to register init data at PA_%llX size:%u" (0x18052, size 4096)
         (cache maintenance over the mapping)
0x17a80  memcpy(fw_global 0x8e550, va, 0xa4)                 ; ONLY the first 0xa4 bytes are used
         unmap(desc)                                          ; bl 0x29e38
```

Message format: `(0x20 << 56) | (0x81 << 48) | PA[43:0]`. Our
`0x0081000802198000` was parsed correctly: "init data" mapped fine.

### 8.2 Why it failed: "init mem desc" PA comes from the init page (high)

```
0x17b30  pa2 = *(u32 *)(init + 0x8c) | (u64)*(u32 *)(init + 0x90) << 32
0x17b3a  map(pa2, size = 0x4000, &va2, &desc2)                ; constant 16 KiB
         fail → "Unable to register init mem desc at PA_%llX size:%u" (0x18066)
```

`map` (fw 0x2a038) is RTKit's **map physical memory into the coprocessor's own
ARM MMU**. It allocates a firmware VA (`0x29634`) and writes page tables
(`0x24474(va>>12, pa>>12, npages, attr)`). No A7IOP or host-window registers
are involved; it can reach any PA.

**status 0x80000002 = invalid argument.** The error base is a literal at
fw 0x2a138 (`0x80000001`), and the routine returns base+1 when
`PA == 0`, `PA & 0xfff != 0` or `size & 0xfff != 0` (fw 0x2a058–0x2a078).
With init+0x8c/0x90 = 0 you got PA_0. Writing the first u64 has no effect
because only offsets 0x8c/0x90 are read.

### 8.3 Init page layout (first 0xa4 bytes, copied to fw 0x8e550)

| Offset | Type | Use | Confidence |
|---|---|---|---|
| 0x18 | u32 fw VA | → fw global `0x8e54c`, the main "AGX context" pointer, dereferenced right away (`[[ctx]] + 0x688/0x68c/0x694` at 0x17c7a; `[ctx]+0x9c0..0x1714` copied at 0x17ec2–0x18038; also used by power code, section 1.4) | high |
| 0x1c | u32 | → fw global `0x8e4c4` | high (meaning unknown) |
| 0x28, 0x2c | u32 | ring index/modulus used by a work loop (`0x1793a..0x17956`) | low |
| **0x8c / 0x90** | u32 lo / hi | **PA of the 16 KiB "mem desc" page**, 4 KiB-aligned | high |
| **0x94** | u32 | number of 16-byte mapping entries in the mem desc page (0 = none) | high |
| 0x98 | u32 | → fw global `0x8e4f8` | high (meaning unknown) |
| 0x9c | u32 | → fw global `0x8e800`. Used elsewhere as a **pointer** (`[0x8e800] + 0x45b4`, power code fw 0x1b41a) | medium |
| 0xa0 | u32 | → fw global `0x8e4f4` | high (meaning unknown) |

Mem desc entry (16 bytes, loop at fw 0x17b74):

| Offset | Type | Use |
|---|---|---|
| +0x0 | u32 | firmware VA to map at |
| +0x4 | u32 | **PFN**: PA = `pfn << 12` (lo = pfn<<12, hi = pfn>>20) |
| +0x8 | u32 | unused here |
| +0xc | u16 | number of 4 KiB pages |
| +0xe | u16 | bit 1: attribute select (set → 0x11b, clear → 0x41b; probably cached vs device/uncached) |

→ `fw 0x18084(va, npages, pa_lo, pa_hi, flag)`. The VA must lie in one of
two reserved windows in the table at fw global `0x8ebe0` (`+0x14` start VPN /
`+0x18` count, `+0x2c` / `+0x30`); otherwise it errors. Those window values
are runtime state, not decoded yet.

### 8.4 Minimal content to get past the current check

- Init page (any 4 KiB-aligned PA, sent in 0x81): set
  `+0x8c = lo32(PA2)`, `+0x90 = hi32(PA2)`, `+0x94 = 0`.
- PA2 = a second zeroed, 4 KiB-aligned (use 16 KiB-aligned) 16 KiB region.
- **Expected next failure:** a data abort at fw **0x17c7a** (`ldr r2, [r5]`
  with r5 = init+0x18 = 0). That confirms the mem-desc step passed. The
  following step needs `init+0x18` (and probably `+0x9c`) to be **firmware
  VAs** backed by mem-desc entries pointing at host pages that hold the AGX
  context structure (the kext's job, section 7.3).

### 8.5 Not done

- Crashlog `crash/crashlog1.bin` (Cstk/rtsC) not decoded here. The failure
  message itself pins the site (fw 0x18066).
- The firmware-VA windows at fw `0x8ebe0` and the AGX context layout
  (`[ctx]+0x688..`, `+0x9c0..0x1714`) are the next RE items. The kext side
  that writes them: users of `this+0x1078` (section 7.4).

## 9. Crashlog, firmware VA space, and the AGX context

### 9.1 Crashlog sections (high)

Section tags are stored byte-reversed (`AgrC` = **CrgA**). Each section header
is `fourcc, 0xefefefef, version, size`.

| Tag | Read as | Content |
|---|---|---|
| `revC` | Cver | RTKit version string |
| `mitC` | Ctim | time |
| **`AgrC`** | **CrgA** | **ARM32 exception registers** (the ARM32 counterpart of mainline's ARM64 `Crg8`) |
| `tscC` | Cstc | stack/counters |
| `xbmC` | Cmbx | mailbox state |
| `ktrC` | Ctrk | task list (`rtk_ep_work`, `power`, `agx_background`…) |
| `pdcC` | Ccdp | ? |
| `atsC` | Csta | ? |

CrgA payload (section +0x10): `u32 type` (4 = data abort; crashlog1 had
0x10020 = software panic), `u32 size (0x160)`, then **r0–r12, sp, lr, pc,
cpsr**, then further words (DFSR/DFAR candidates) not decoded.

crashlog2: r5 = 0, r11 = 0x8e550, sp = 0x31f60, lr = 0x641, **pc = 0x15486**,
cpsr = 0x2000007f (SYS mode, Thumb). fw 0x15486 is `ldr r0, [r0]` with
`r0 = *(0x8e550 + 0x18)` = **init+0x18 = 0**, inside fw 0x153b0 (called at
0x17c76). That's the predicted null context, one call before 0x17c7a.

### 9.2 Firmware VA space (high)

The coprocessor runs an ARMv7 **LPAE** MMU (fw 0x240b0: TTBR0/TTBR1 via
`mcrr p15`, TTBCR via `c2,c0,2`). The table at fw 0x8ebe0 holds:

- **Window A** (+0xc..+0x18, TTBR0): start VPN 0, count
  `1 << (va_bits - 12)` with `va_bits = *(u32 *)fw 0x35108 = 31`. So **VA
  0x00000000–0x7fffffff**.
- **Window B** (+0x24..+0x30, TTBR1): on cold boot start = 0xffffffff, count = 0,
  so **disabled**.

Mem-desc entries must therefore use **VA < 0x80000000**, 4 KiB-aligned, and
not collide with existing mappings: the image identity map (code
0x0–0x2fc38, attr 0x12d; data 0x31000–0x8ecc4, attr 0x11b), the init-data
and mem-desc mappings, and the dynamic pools of fw 0x29634 (range not
decoded). **0x40000000 and up** is far from all of them.

### 9.3 AGX context (high: offsets; low: meaning)

`init+0x18` = VA **X** (stored in fw global 0x8e54c). `*X` = VA **P**, the
context struct (`ctx`); the code always goes through `[[0x8e54c]]`. Fields
read in order:

| P offset | Type | Use |
|---|---|---|
| **0x640 / 0x644** | u32 lo/hi **PA R** | fw 0x15488: maps `R + 0x110000` (1 page) and copies fw 0x30000..0x30d70 (0xd70 bytes) into it. R is the base of a ≥ 0x111000-byte host region |
| 0x688 / 0x68c | u32 lo/hi | fw 0x17c84 → `0x29500(lo, hi, P[0x694], 1, attr 0x21b)`. Likely PA + size of another region (next crash) |
| 0x694 | u32 | size for the above |
| 0x9c0–0xa4c, 0x16b4–0x1714 | u32 | copied into a firmware global at fw 0x17ec2–0x18038 (config) |

P is at least 0x1718 bytes, so 2 pages.

Other init fields: `+0x1c` → fw 0x8e4c4; `+0x98` → 0x8e4f8; `+0x9c` →
0x8e800, used later as a **pointer** (`[0x8e800] + 0x45b4`, power code
0x1b41a); `+0xa0` → 0x8e4f4. Leave them 0 for the next step.

### 9.4 Next experiment (values; W = window PA base 0x802100000)

Pages: init `I = W+0x98000` and mem-desc `M = W+0x9c000` (unchanged); new
context pages at `W+0xa0000..W+0xa7fff`; scratch page `W+0xc0000`.

1. **Mem-desc page M**, entry 0 (16 bytes at M+0):
   `+0x0 u32 va = 0x40000000`, `+0x4 u32 pfn = 0x008021a0`,
   `+0x8 u32 = 0`, `+0xc u16 npages = 8`, `+0xe u16 flags = 0x0002`
   (bit 1 → attr 0x11b, the same as firmware data).
2. **Init page I:** `+0x18 = 0x40000000`, `+0x8c = 0x0219c000`,
   `+0x90 = 0x8`, `+0x94 = 1`; everything else 0.
3. **X page** (PA `0x8021a0000`, VA 0x40000000): `+0x0 u32 = 0x40004000`.
4. **P struct** (PA `0x8021a4000`, VA 0x40004000, 16 KiB zeroed):
   `+0x640 = 0x020b0000`, `+0x644 = 0x8`, so R = 0x8020b0000 and
   `R + 0x110000 = 0x8021c0000` = W+0xc0000, our scratch page.
   **Caveat:** R itself points into memory below the window. Only R+0x110000
   is touched in this step, but give the region a real carve-out before
   going further.
5. Flush/clean all pages, send `0x0081000802198000` on EP 0x20.

Expected: fw 0x153b0 completes. The scratch page W+0xc0000 receives the 0xd70
bytes of fw 0x30000. The next fault/error comes from `P+0x688/0x68c/0x694`
being 0 (fw 0x17c84 → 0x29500), probably invalid-argument 0x80000002 or a
data abort there. That identifies the next region (PA + size) to provide.

## 10. Mapping limits, the shared page, and the next pointers

### 10.1 0x8000000B and the 0x10000000 limit (medium)

- In the mem-desc entry handler (fw 0x18084), `r8 = 0x8000000B` is preloaded
  (fw 0x180d6) and returned when the VA range isn't inside window A/B. It is
  also returned when the page-table map (fw 0x248d0) fails. The window check
  (fw 0x180e2..0x18106) uses window A = VPN 0, count `1 << (31-12)` (2 GiB):
  `va_bits` at fw 0x35108 is static 31 and nothing writes it. So the
  0x10000000 limit comes from **fw 0x248d0**, not the window bounds.
- Hypothesis (matches all observations): 0x248d0 needs a **last-level (L3)
  table to already exist**. The next-level table allocator (fw 0x24640,
  pool from fw 0x8ebe0+0x3c) has no spare tables. Accepted VAs: 0x00100000
  (the L3 table for 0–2 MiB that maps the image) and 0x01000000 (an L3 table
  the dynamic mapper fw 0x29634 already created there). Rejected: 0x10000000,
  0x40000000 and 0x7f000000, which would need new tables.
- **Practical rule:** keep fixed mappings in **VA 0x00100000–0x001fffff**
  (inside the image's L3 table, unused since the image ends at 0x8f000).
  Avoid 0x01000000: that L3 belongs to the dynamic mapper, and a fixed
  mapping there can overwrite its entries.

### 10.2 crashlog3: pc 0x278c (high)

- fw 0x153b0 (finished this time) **remaps firmware page VA 0x30000 onto host
  memory**: it maps `R + 0x110000` at VA 0x30000 (`0x248d0` call at
  fw 0x15464) and copies the old 0xd70 bytes there. The "1 at R+0x110000+0x48"
  you saw is the firmware's own global `0x30048` (a flag), now visible to the
  host. **That page is shared AP↔firmware state** (worth watching).
- fw 0x2760 (called at 0x1803c, lr 0x18041): if `[0x30048] != 0`:
  `r2 = *(0x8e4f8)` = **init+0x98**; `r1 = *(0x8e4c4)` = **init+0x1c**;
  `ldr r2, [r2]` at **0x278c** with init+0x98 = 0 → data abort. It isn't a
  permission or attribute problem.
- Remaining reads in 0x2760 (all copied into the shared page `0x30000 +
  0x4c..0x138`, then `[0x30048] = 0`):
  - `*(u32 *)init[0x98]` → shared +0x4c.
  - `init[0x1c]` = struct **≥ 0xe1c bytes**: offsets 0x0–0x62 (some u16 at
    0x50/0x52/0x54, unaligned u32 at 0x56/0x5e/0x62), 0x7d4, 0x7d8,
    0x9a0–0x9dc, 0xe08–0xe18.
  - `init[0x9c]` = struct **≥ 0x65c0 bytes**: `+0x8`, `+0x65b8`, `+0x65bc`.
  - Zeros are accepted by this code. Only the pointers must be mapped.

### 10.3 Next exact layout (S = 0x802400000; R = S+0x200000 = 0x802600000 unchanged)

One mem-desc entry maps 64 KiB of S at fw VA 0x00100000:

| What | fw VA | PA | Content |
|---|---|---|---|
| mem-desc entry 0 (M = W+0x9c000) | — | 0x80219c000 | `+0x0 = 0x00100000`, `+0x4 = 0x00802400`, `+0x8 = 0`, `+0xc u16 = 16`, `+0xe u16 = 0x0002` |
| X | 0x00100000 | S+0x0000 | `+0x0 u32 = 0x00102000` |
| P (2 pages) | 0x00102000 | S+0x2000 | `+0x640 = 0x02600000`, `+0x644 = 0x8`, rest 0 |
| T = init+0x1c target | 0x00104000 | S+0x4000 | zero page |
| U = init+0x98 target | 0x00105000 | S+0x5000 | zero page |
| V = init+0x9c target (8 pages) | 0x00108000 | S+0x8000..S+0xffff | zero |
| init page (I = W+0x98000) | — | 0x802198000 | `+0x18 = 0x00100000`, `+0x1c = 0x00104000`, `+0x8c = 0x0219c000`, `+0x90 = 0x8`, `+0x94 = 1`, `+0x98 = 0x00105000`, `+0x9c = 0x00108000`, `+0xa0 = 0`, rest 0 |

Then send `0x0081000802198000` on EP 0x20.

Expected: fw 0x2760 completes (the shared page R+0x110000 gets fields at +0x4c..+0x138
and +0x48 goes back to 0). Back in the init path, fw 0x17c7a..0x17c94 reads
`P+0x688/+0x68c` (PA lo/hi) and `P+0x694` (size) → fw 0x29500 with attr
0x21b. With zeros, expect invalid-argument 0x80000002 or an abort there. That's the
next region to supply (decode 0x29500 next).

## 11. agx_background main loop: X is an array of pointers

### 11.1 crashlog4: pc 0x1bb18 (high)

The init routine fw 0x179e0 **returned**, so the `P+0x688/0x68c/0x694` step
passed with zeros. The crash is in agx_background's body (fw 0x1ba5c):

```
0x1baa2  bl 0x179e0                      ; init (done)
0x1bac6  U[0x14] = 0                     ; U = init+0x98 target
0x1bad2  P[0x16e4], P[0x16e8] → fw 0x307f8/0x307fc
0x1bae4..0x1bb06  bl 0x1b82c, 0x1b03e, 0x1a198, 0x1af92, 0x5792, 0x16cb0   ; passed
0x1bb0a  r0 = X;  r0 = X[1]  (=0)
0x1bb18  ldr r1, [r0]                    ; ← abort: X[1] must point to 8 bytes Q
         Q[0], Q[1] → fw 0x8dd50/0x8dd54
```

So **X = {P, Q, Z}**: an array of firmware-VA pointers. Your crash registers
match: r11 = 0x8e54c, r2 = 0x8dd50, r0 = 0.

Note: shared-page values `0xc1001000` (+0x144) and `0xc1111000` (+0xd5c) are
firmware VAs ≥ 0x80000000. So **window B (TTBR1) is live at runtime** and the
dynamic mapper (fw 0x29634) allocates there. This corrects 9.2's
"disabled". Keep fixed mappings in VA 0x100000–0x1fffff anyway.

### 11.2 What comes next (predicted from code; medium)

| Step (fw) | Reads | Requirement |
|---|---|---|
| 0x1bb16 | `X[1]` → Q, 8 bytes | mapped; zeros OK |
| 0x1b2a2 (power-up path) | `P[0x16e4/0x16e8]`, `V[0x45b4]`, `V[0x4030]`, and **`init+0xa0` → struct `[+0x1b8/+0x1bc]` (u64, read and written)** | V already ≥ 32 KiB; **init+0xa0 must be mapped (≥ 0x1c0 bytes)** |
| 0x28da, 0x1c4a0 | — | no init pointers |
| 0x1c626 | `X[2]` → Z: if `Z[0] != 0` copy `Z+4..+0x64` and `Z+0x64..+0x84`, else fallback | mapped; zero = fallback path |
| 0x1bb38..0x1bb3c | `[0x30000] = 1`, `U[0x14] = 1` | "firmware ready" flags. Watch shared page R+0x110000+0x0 and U+0x14 |
| 0x1bb66.. | creates further tasks (`0x25f8c`) | — |
| 0x1a198 (already ran) | PA pairs at `P+0x680, 0x6c8, 0x6f8, 0x710, 0x740, 0x770, 0x788, 0x7a0, 0x7b8, 0x7d0, 0x800, 0x830` (lo/hi) | zeros passed. These are probably ring/region PAs for later steps |

After that, the power-up path (agfPowerHandlePowerUp, sections 1.4 and 4.5)
kicks Fender. With no init sequence, the likely next outcome is the string
**"GPU is not powered on after power kick!"** (fw 0x1b7d6), which would mean
init is complete and power is the next topic.

### 11.3 Next exact layout (one run, covers 11.2)

Mem-desc entry 0 now maps **24 pages** (S..S+0x17fff) at VA 0x00100000:
`+0x0 = 0x00100000, +0x4 = 0x00802400, +0x8 = 0, +0xc u16 = 24, +0xe u16 = 0x0002`.

| What | fw VA | PA | Content |
|---|---|---|---|
| X | 0x00100000 | S+0x0000 | `+0x0 = 0x00102000` (P), **`+0x4 = 0x00106000` (Q)**, **`+0x8 = 0x00107000` (Z)** |
| P (2 pages) | 0x00102000 | S+0x2000 | `+0x640 = 0x02600000`, `+0x644 = 0x8`, rest 0 |
| T (init+0x1c) | 0x00104000 | S+0x4000 | 0 |
| U (init+0x98) | 0x00105000 | S+0x5000 | 0 |
| **Q** | 0x00106000 | S+0x6000 | 0 |
| **Z** | 0x00107000 | S+0x7000 | 0 |
| V (init+0x9c, 8 pages) | 0x00108000 | S+0x8000..S+0xffff | 0 |
| **A0 (init+0xa0)** | 0x00110000 | S+0x10000 | 0 |
| init page | — | 0x802198000 | `+0x18 = 0x00100000`, `+0x1c = 0x00104000`, `+0x8c = 0x0219c000`, `+0x90 = 0x8`, `+0x94 = 1`, `+0x98 = 0x00105000`, `+0x9c = 0x00108000`, **`+0xa0 = 0x00110000`**, rest 0 |

Then send `0x0081000802198000` on EP 0x20. What to check afterwards:
- `R+0x110000+0x0` (fw 0x30000) == 1 and `S+0x5000+0x14` (U+0x14) == 1 mean
  agx_background reached "ready".
- `S+0x10000+0x1b8` (A0, u64) changing means the power path ran (0x1b67a).
- Any new crash: CrgA pc. A string "GPU is not powered on after power kick!"
  means the init chain is complete and the GPU power sequence comes next.

## 12. READY, then the ring scan (12 host rings)

### 12.1 crashlog5: pc 0x5038 (high)

fw 0x502c ("any ring has pending work?", called from 0x50f0, lr 0x50fd):

```
r0 = X (0x100000)
for i in 0..11:
    w = *(u32 *)X[0x0c + 0x10*i]      ; 0x5036/0x5038 ← abort at i = 0: X+0xc = 0
    r = *(u32 *)X[0x14 + 0x10*i]
    if w != r: return 1
return 0
```

So X holds **12 ring descriptors of 0x10 bytes from X+0x8**:
`{+0x0 ?, +0x4 → u32 index A (write?), +0x8 ?, +0xc → u32 index B (read?)}`
(pointer pairs at X+0xc/0x14 … X+0xcc/0xd4). Twelve matches the 12 PA pairs
in P (+0x680…+0x830) that fw 0x1a198 reads: probably the ring buffers. X+0x8
(Z, section 11) is the first slot's `+0x0`. The task isn't recorded in CrgA;
the code is the scheduler's idle check, so with READY and five new tasks
(agx_recovery/interrupt/sampler/power) this is likely agx_background's or
agx_power's loop.

### 12.2 Other tables found (for later)

- **T+0x988** (T = init+0x1c): count of register patches at **T+0x808**, 0x18
  bytes each: `{u32 mask_lo, u32 mask_hi, u32 val_lo, u32 val_hi, u32 offset, …}`.
  Applied as `[base+off] = ([base+off] & ~mask) | (val & mask)` (fw 0x60b4..
  0x61bc). Count 0 skips them. This is where the kext's tunables would go.
- "Unable to register init sequence memory at addr %llX size:%u" (fw 0x6162):
  the PA comes from a descriptor's `+0x8/+0xc`, size 0x1000. Its source
  isn't traced yet (code around fw 0x5a98–0x6160). That's the Fender
  power program, next to decode.

### 12.3 Next exact layout

Unchanged from 11.3 (24 pages S..S+0x17fff at VA 0x00100000), plus **ring
index pointers** into the already-mapped page S+0x11000 (VA 0x00111000, zero):

| X offset | Value (fw VA) |
|---|---|
| `+0x0c + 0x10*i` (i = 0..11) | `0x00111000 + 0x10*i` |
| `+0x14 + 0x10*i` (i = 0..11) | `0x00111008 + 0x10*i` |

That is X+0x0c = 0x111000, X+0x14 = 0x111008, X+0x1c = 0x111010, X+0x24 =
0x111018, …, X+0xcc = 0x1110b0, X+0xd4 = 0x1110b8. Leave X+0x10/0x18/… (the
slots' other fields) at 0 and X+0x8 = Z as before.

### 12.4 Expected and next steps (medium)

- With all indices equal (0 = 0) the scan returns "idle". The firmware should
  then **sit idle with no crash** (watch for new crashlogs or `Unable` strings
  for about 1 s).
- The firmware doesn't announce READY by message. The kext's
  `waitForFWAlive` polls; on our side the READY signals are the shared page
  `[R+0x110000] == 1` and `U+0x14 == 1` (already seen).
- To make the firmware act (and run the power path), the host must
  **put work on a ring and kick**: set ring i's index A ≠ index B, then send
  `0x0083 << 48 | ((i & 7) << 2)` on EP 0x20 (section 7.1). The firmware will
  then read that ring's buffer, probably via P's PA pair for ring i and/or the
  slot's `+0x0/+0x8` fields. Expect the next abort there. The crash pc tells
  which field. That also reaches agfPowerHandlePowerUp → Fender kick → the
  init-sequence descriptor (12.2), the next RE target.

## 13. X is the full AGX context (≥ 0xe70 bytes): every pointer field

### 13.1 crashlog6: pc 0x50dc (high)

`ldr r1, [r1]` with `r1 = X[0xcc]`: the ring scan covers **13 rings**
(pairs X+0x0c/0x14 … X+0xcc/0xd4, i = 0..12), not 12. Section 12 set only
i = 0..11.

Caller fw 0x50f0: `0x502c` (ring scan) → if idle, `0x10de8(0)` → then
firmware-global state only (0x8e4f0, 0x66db0..); no further X access. The next
idle function fw 0x51ee reads `X+0x1f4` (val), `X+0x1f8` (val) and `X+0x1fc`
(ptr).

### 13.2 All X fields the firmware loads (scan of every `[[0x8e54c]] + off`)

PTR = the loaded value is dereferenced; val = used as a value. Tool:
scratchpad `tools/xfields.py` over the Thumb disassembly.

| Offset | Kind | Notes |
|---|---|---|
| 0x000 | PTR | P (context 2, PA pairs at +0x640…) |
| 0x008 | PTR | Z (slot 0 +0x0; 0x1c626 flag struct) |
| 0x00c…0x0d4 (every 8, odd positions) | PTR | 13 rings × {index A, index B} |
| 0x010, 0x020, 0x028, 0x038, 0x050 | val | ring slot fields (sizes/flags?) |
| 0x098, 0x0dc, 0x0e0, 0x0f4, 0x0fc, 0x118, 0x130 | val | |
| **0x0e4, 0x0e8, 0x0ec, 0x0f0** | PTR | 0xe4: indexed `+ i*16` (0x1ba3a) |
| **0x134, 0x138, 0x13c, 0x140** | PTR | queue/channel arrays (strides 0x18/0x28, ≤ 32 entries), 16–41 sites each |
| **0x188** | PTR | |
| 0x1dc…0x1e8 | val | |
| **0x1ec** | PTR | |
| 0x1f4, 0x1f8 | val | idle function 0x51ee |
| **0x1fc** | PTR | |
| 0x200, 0x204, 0x218, 0x21c, 0x230, 0x234, 0x288 | val | |
| **0x301 (unaligned u32)** | PTR | **power state struct**: `[+0x38] != 0` means "GPU powered" (0x16d5a, 0x1b4d6 → "GPU is not powered on after power kick!") |
| 0x598, 0xa54, 0xa5c, 0xe6c | val | |

### 13.3 Next exact layout (fixes all of 13.2 at once)

**Mem-desc entry 0: 36 pages** (S..S+0x23fff) at VA 0x00100000:
`+0x0 = 0x00100000, +0x4 = 0x00802400, +0x8 = 0, +0xc u16 = 36, +0xe u16 = 0x0002`.

Everything from 11.3 stays (P, T, U, Q, Z, V, A0, init page). Changes in X
(PA S+0x0, VA 0x100000):

| X offset | Value | Backing |
|---|---|---|
| 0x0c + 0x10*i, i = 0..**12** | 0x00111000 + 0x10*i | ring index page S+0x11000 (zero) |
| 0x14 + 0x10*i, i = 0..**12** | 0x00111008 + 0x10*i | same |
| 0x0e4 | 0x00118000 | S+0x18000 zero page |
| 0x0e8 | 0x00119000 | S+0x19000 |
| 0x0ec | 0x0011a000 | S+0x1a000 |
| 0x0f0 | 0x0011b000 | S+0x1b000 |
| 0x134 | 0x0011c000 | S+0x1c000 |
| 0x138 | 0x0011d000 | S+0x1d000 |
| 0x13c | 0x0011e000 | S+0x1e000 |
| 0x140 | 0x0011f000 | S+0x1f000 |
| 0x188 | 0x00120000 | S+0x20000 |
| 0x1ec | 0x00121000 | S+0x21000 |
| 0x1fc | 0x00122000 | S+0x22000 |
| **0x301..0x304 (bytes, little-endian)** | 0x00123000 → bytes `00 30 12 00` at X+0x301..0x304 | S+0x23000 (power state; +0x38 = 0) |

All value fields stay 0.

### 13.4 Expected next

- Idle loop runs without aborts (ring scan, 0x10de8, 0x51ee).
- Kicking a ring (12.4) or a power request then goes into
  agfPowerHandlePowerUp. With the power-state page at 0 it should log
  **"GPU is not powered on after power kick!"** (0x1b7d6), because
  `[X+0x301]+0x38` is only set once Fender has really powered RGX. Write
  test (low): a nonzero `[S+0x23000+0x38]` makes the firmware believe the
  GPU is on. That's useful to walk further down the path, but RGX
  access would then fault, as in section 1.

## 14. EP 0x21 doorbell: mapping ring, event dispatch, power conditions

### 14.1 crashlog8: pc 0x1820e (high)

EP 0x21 is the work/doorbell endpoint (EP 0x20 is init/control; 0x83 on
0x20 is ignored). The doorbell handler loop (around fw 0x1c9e2–0x1cbf6)
**first drains the mapping-update ring** (fw 0x181ee, called at 0x1caae):

```
ctl  = *(u32 *)(V + 0x455c)        ; 0x18206 → 0 → ldr [ctl] aborts at 0x1820e
ents = *(u32 *)(V + 0x4560)
n    = (u8)(ctl[0x10] - ctl[0x0])  ; write idx at +0x10, read idx at +0x0
for each entry (16 bytes): {u32 va, u32 pfn, u32 -, u16 npages, u16 flags}
    flags bit0 = 1 → map  (fw 0x18084, bit1 = attr 0x11b/0x41b)
    flags bit0 = 0 → unmap (fw 0x248d0 with PA = -1)
```

This is the firmware side of the kext's `notifyNewMapping` + 0x84 sync
(section 7). **It also gives us runtime mappings**, without reloading.
r9 = 0x5f000000 and the other registers are leftovers from the caller's event
word and aren't relevant.

### 14.2 Event dispatch after the mapping ring (high: table; low: meaning)

The doorbell's 64-bit pending-event word is dispatched through a table at
fw 0x2e7e8 (10 × `{mask_lo, mask_hi, fn, arg0, arg1}`):

| Bit | Handler(arg) | Guess |
|---|---|---|
| 0x1, 0x2, 0x4 | 0x1ff85(0 / 1 / 2) | three work channels (TA/3D/CL?) |
| 0x01000000, 0x02000000 | 0x1d107(bit) | |
| 0x04000000…0x20000000 | 0x1d6d9(bit) | |
| 0x40000000 | 0x1dc41 | |

How a kick message sets these bits isn't decoded yet (the 0x83 payload
`(ring & 7) << 2` probably selects a bit).

### 14.3 Power-up conditions in the same loop (fw 0x1cb38…, medium)

The loop calls the power transition `0x54ec(1, 5)` (→ agx_power →
agfPowerHandlePowerUp → Fender kick) only when all of these hold:
- `*(u32 *)X[0x140] != 2`
- shared page words `fw 0x30438` and `0x3043c` (= R+0x110000+0x438/0x43c) both nonzero
- `[0x8e550 + 0x11c]` bit 1 set and (bits 5|6) set. This is a firmware-global
  copy; its source isn't traced.
- `*(u32 *)(X[0x134] + 0xc)` ∈ {0, 5}

So the power path is requested by **work arriving** (event bits) plus these
state words. It's not a separate host "power on" message.

### 14.4 Next exact layout (high)

Extend mem-desc entry 0 to **38 pages** (S..S+0x25fff, `+0xc u16 = 38`).
Everything from 13.3 stays. Add:

| Where | fw VA / PA | Value |
|---|---|---|
| `V + 0x455c` (PA S+0xc55c) | — | `0x00124000` (ctl) |
| `V + 0x4560` (PA S+0xc560) | — | `0x00125000` (entries) |
| ctl page | VA 0x124000 / S+0x24000 | zero (read idx +0x0 = write idx +0x10 = 0 → no entries) |
| entries page | VA 0x125000 / S+0x25000 | zero |

Repeat the EP 0x21 kick. Expect the mapping ring to pass and the event dispatch
or power-condition code to run. The next abort pc tells which handler or
field is next.

**Runtime mapping test** (optional, same run or later): write entry 0 at
S+0x25000 = `{va 0x00126000, pfn 0x00802426, 0, npages 1, flags 0x0003}`,
then set ctl+0x10 = 1 and kick EP 0x21. The firmware should map VA 0x126000 →
S+0x26000 and advance ctl+0x0 to 1. That confirms the mechanism the kext uses.

### 14.5 Fender power-up program: status

Not derived yet. What's known:
- The host does **not** program Fender on G9P (section 1.3).
- The firmware runs init sequences (`AGFAInitSequence`, "init sequence memory at
  addr %llX size:4096", fw 0x6162) from a host-provided descriptor whose
  `+0x8/+0xc` PA source hasn't been traced. It sits in the power/initialisation
  code around fw 0x5a98–0x6160.
- Register tunables live at T+0x808 (count T+0x988, section 12.2).

Next RE: trace the descriptor at fw 0x6162 back to an X/P/V field. Then
decode `AGFAInitSequence`'s sequence types ("unknown seq type %u",
fw 0x61c0) to get the command format: probably {type, reg offset, value,
mask/poll} entries for Fender/PMGR writes. In parallel, the kext side that
fills it is reached from `AGXFirmware::setupConfig` (`0xfffffff00601102c`).
Rough effort: 1–2 days.

## 15. The reset sequence starts: region R is the GPU control window

### 15.1 crashlog9: pc 0x6b54 (high)

```
fw 0x6b3e  r0 = [0x30144]        ; shared+0x144 = R_VA = 0xc1001000
           r3 = 0x2f350          ; trace tag "AGFHALExecuteResetSequence"
fw 0x6b54  str 1, [R_VA + 0x2058]          ← abort (page R_VA+0x2000 unmapped)
fw 0x6b5e  0x6750(0x2058, 1, 0xfa)         ; poll R+0x2058 == 1, ~250 tries ("agfPollFenderReg")
```

Just before (fw 0x6b12): if shared `+0x438`/`+0x43c` (fw 0x30438/0x3043c) are
both 0 → `[power_state + 0x38] = 1` (r10 = our page from X+0x301) and
`shared+0x804 = shared+0x4c8`; else `0x16d40(..., 2, 1000)`.

**Where R_VA comes from** (fw 0x1a198, ran at init; corrects section 9.3):

```
R_PA   = P[0x640] | P[0x644] << 32
size   = P[0x64c]               ; we had 0 → only 1 page mapped
attr   = P[0x654] ? 0x21b : 0x209
R_VA   = map(R_PA, size, attr)  ; fw 0x29500 → 0xc1001000 (high window)
shared+0x13c/0x140 = R_PA, +0x144 = R_VA, +0x148 = size, +0x14c = P[0x650], +0x150 = P[0x654]
shared+0xd5c = R_VA + 0x110000  (unless X→P[0x928] != 0)
```

So **R is the GPU control window**: registers at R+0x2000…, plus a RAM/SRAM
page at R+0x110000 that becomes the firmware's shared page. The live Fender
block at 0x201d00000 (+0x2000 = 7, +0x2040/+0x2048 run bit/+0x2050/+0x2054;
section 4) has the same register layout, so on iOS **R_PA is most likely
0x201d00000** (the A9's Fender at 0x201e00000 = +0x100000 is in the same family).
Unverified, and R+0x110000 then would be GPU-side SRAM.

### 15.2 Next step: back R with RAM to trace the reset sequence (recommended)

Keep R = S+0x200000 (RAM) but map it fully:
- `P+0x64c = 0x00200000` (2 MiB: covers R+0x2058 and R+0x110000).
- `P+0x654 = 0` → attr 0x209 (keep it uncached; good for host readback).
- Everything else as in section 14.

Effect: plain RAM echoes writes, so `R+0x2058 = 1` then polling it succeeds,
and the firmware continues through AGFHALExecuteResetSequence. **Every register
write of the sequence lands in our RAM at S+0x200000+offset.** After the run,
diff R+0x0..+0x10ffff against zero to get the sequence's write trace (offsets
and values). Expected stop: a poll for a bit that only real hardware sets
(e.g. a "powered/ack" bit). That times out (expect a log string or a
`GPU is not powered on after power kick!`), and the timing-out offset
tells which status register the real hardware must answer.

Then the real attempt: point R at the hardware window,
`P+0x640 = 0x01d00000, P+0x644 = 0x2` (R_PA = 0x201d00000), size per the
trace (the RAM shared page at R+0x110000 is a problem there: either iOS
really has SRAM at 0x201e10000, or P+0x928 overrides the shared-page address,
shared+0xd5c). Do this only after the trace, with ps_gfx on.

### 15.3 What's still open

- The init-sequence descriptor (fw 0x6162 "init sequence memory", `+0x8/+0xc`
  PA): not traced yet. The RAM-backed run should reveal whether the reset
  sequence above *is* that program (AGFHALExecuteResetSequence), with the
  init-sequence memory as a separate later table.
- `P+0x650`, `P+0x928`, and the meaning of shared +0x438/+0x43c (they choose
  between the direct "power_state+0x38 = 1" path and `0x16d40(..., 2, 1000)`).

### 15.4 The IO-mapping table is P+0x640 (high: format; medium: entry order)

fw 0x1a198 (runs at init) maps **0x18-byte entries starting at P+0x640**:

| Entry offset | Field |
|---|---|
| +0x00 / +0x04 | PA lo / hi (entries ≥ 1 are skipped when PA == 0) |
| +0x08 | firmware VA, **written back by the firmware** |
| +0x0c | size (0 → one page; that's why R+0x2058 faulted) |
| +0x10 | flags/extra (copied to the shared page) |
| +0x14 | 0 → attr 0x209 (device/uncached), ≠ 0 → 0x21b |

Entry k is mirrored to `shared + 0x13c + 0x18*k` (PA, VA, size, …). Seen:
k = 0 (P+0x640) → shared+0x13c..0x150; k = 6 (P+0x6d0) → shared+0x1cc..0x1e0;
k = 7 (P+0x6e8) → shared+0x1e4..0x1f8; more at P+0x700, 0x730, … (about 20
entries up to ~P+0x848). The "12 PA pairs" of section 11.2 are entries of
this table.

This is the firmware-side copy of the kext's IO-mapping table (section 1.2;
the kext's 0x98-byte entries are condensed to 0x18). Assuming the same order
(medium):

| k | P offset | Kext name | iOS PA / size | Safe first? |
|---|---|---|---|---|
| 0 | 0x640 | FenderRegs | 0x201d00000 / 0x5000 | **trace with RAM first** (15.2); real HW: only +0x0..+0x3fff readable with GFX on, +0x4000 faulted |
| 1 | 0x658 | AICTimerRegs | 0x20e101000 / page | yes (AIC timer, always on) |
| 2 | 0x670 | AICSWIntRegs | (kext `this+0x4490`, AIC SW-IRQ page) | yes once the PA is known |
| 3 | 0x688 | RGXRegs | 0x201000000 / 0x20000 | **no**: SError until Fender powers RGX. Leave PA = 0 (skipped) for now |
| 4 | 0x6a0 | UVDRegs / Unused | — | leave 0 |
| 5 | 0x6b8 | DisplayUnderrunWA | 0x200800000 / 0x1000 | optional |
| 6 | 0x6d0 | TempSensorRegs | 0x20e0c0020 / 0x1000 | optional |
| 7+ | 0x6e8… | PMPDoorbell, PMGRScratch, Metrology… (unused on G9P) | — | 0 |

Note: with entry 0 = Fender, the firmware's **shared page = R+0x110000**
(fw 0x153b0) would land in MMIO at 0x201e10000, unless `P+0x928 != 0`
selects another address (fw 0x1a20c; source not traced). So on iOS either
that's GPU SRAM, or P+0x928 is set. For our experiments keep entry 0 in RAM
(15.2) until P+0x928 is understood.

### 15.5 Layout for the next run (combines 15.2 + 15.4)

As now (incl. the power-state struct at VA 0x130000), plus:
- P+0x640/0x644 = R = 0x802600000 (unchanged), **P+0x64c = 0x00200000**,
  P+0x650 = 0, P+0x654 = 0.
- P+0x658 (AICTimer) = `0x0e101000`, P+0x65c = `0x2`, P+0x664 = `0x1000`,
  P+0x66c = 0. Optional; it's always-on hardware, safe.
- Everything else in the table stays 0, **especially entry 3 (RGX)**.

Read back after the run: R (S+0x200000..+0x10ffff) for the reset sequence's
write trace, and the shared page R+0x110000 (+0x13c.. table mirror, +0x438/+0x43c).

## 16. Why entry 0 was read-only (and the fix)

### 16.1 DFSR is long-descriptor format (high)

The coprocessor MMU runs **LPAE** (TTBCR.EAE set at fw 0x24148), so
CrgA's DFSR uses the long-descriptor layout: bit 9 = 1 (LPAE format), bit 11 = WnR,
STATUS = bits[5:0].

| DFSR | STATUS | Meaning |
|---|---|---|
| 0xa0e | 0x0e | **permission fault, level 2** (2 MiB block), write |
| 0xa0f | 0x0f | **permission fault, level 3** (4 KiB page), write |
| 0xa07 | 0x07 | translation fault, level 3 (unmapped page) |

So (a) was not an external abort on a table walk: the size-0x200000 entry was
mapped as a **2 MiB level-2 block**, no new table needed, and was read-only.
**No page-table pool is involved**; the IO-table mapper uses blocks for
2 MiB-aligned sizes and the existing L3 tables otherwise.

### 16.2 Where AP/XN come from (high)

IO-table mapper fw 0x1a198: `attr = P[entry+0x14] ? 0x21b : 0x209`. RTKit
maps attr → PTE in fw 0x247c0:
- `attr & 0xff00` selects the memory type (0x200 = device, same for both values).
- `attr & 0x3f` selects permissions (tbb table at fw 0x2484a):

| attr & 0x3f | AP[2:1] | XN | Use |
|---|---|---|---|
| 0x1b | 01 (**RW**) | yes | data (0x11b, 0x21b) |
| 0x2d | 11 (RO) | no | code (0x12d) |
| **0x09** | 11 (**RO**) | yes | **0x209 = read-only device** |
| 0x01, 0x03, 0x05, 0x0b | various | — | — |

So `entry+0x14 == 0` (what we used, on my wrong "uncached" advice in
15.2) gives **read-only**. Entry +0x10 (P+0x650) doesn't affect permissions,
which matches your sweep. iOS sets entry+0x14 ≠ 0 for registers that must be
written (Fender).

### 16.3 Next exact layout

Entry 0 (P+0x640):

| Field | Value |
|---|---|
| +0x00 / +0x04 (P+0x640/0x644) | R = `0x02600000` / `0x8` (RAM, unchanged) |
| +0x0c (P+0x64c) | `0x00200000` (2 MiB block; covers R+0x2058 and R+0x110000) |
| +0x10 (P+0x650) | 0 |
| **+0x14 (P+0x654)** | **1** → attr 0x21b = device RW |

Everything else unchanged; keep entry 3 (RGX) PA = 0.

Expected: the write at R+0x2058 now lands in our RAM (S+0x202058 = 1). The
poll reads it back and the reset sequence continues. Afterwards, diff
S+0x200000..S+0x30ffff for the write trace (offset → value) and send me the
first offsets and values plus the next crash or string. Device-type
mapping of RAM is fine (uncached, so the host sees writes without cache
maintenance).

## 17. Init-sequence program (the Fender power-up program)

### 17.1 Where the descriptor is (high)

**init page +0x08 / +0x0c** = PA lo / hi of the program page. These words
are part of the 0xa4 bytes the firmware copies from the init page to
fw 0x8e550 at 0x81 time (section 8.1), so they live in the init page itself,
not in X/P/T/U/V.

- It's a **physical address**, mapped by the firmware with the same RTKit map
  routine as the init-data and mem-desc pages (fw 0x2a038, at fw 0x57e6).
- **Size is fixed at 0x1000** (one page). PA must be non-zero and 4 KiB-
  aligned, otherwise you get "Unable to register init sequence memory at addr
  %llX size:4096, status:0x80000002". That's the current error, because +0x8/
  +0xc are 0.

### 17.2 Program format (high)

Interpreter at fw 0x5828: 20-byte entries from page offset 0, executed in
order until a type-0 entry. At most 204 entries per page.

| Offset | Field |
|---|---|
| +0x00 | u32 value lo |
| +0x04 | u32 value hi |
| +0x08 | u32 register offset (from the base, see 17.3) |
| +0x0c | u32 shift |
| +0x10 | u32 type |

| Type | Action |
|---|---|
| **0** | **end of program** (unmaps the page, initialisation continues) |
| 1 | 32-bit write: `[base + off] = val_lo` |
| 2 | 64-bit write: `[base + off] = val_lo`, `[base + off + 4] = val_hi` |
| 3 | 64-bit write of `value >> shift` (lo, hi) |
| > 3 | panic "AGFAInitSequence unknown seq type %u" |

There are **no poll or delay commands**. Waits are in fixed firmware code
(e.g. the reset step's poll on +0x2058, section 15/16). So the program is a
plain list of register writes.

Correction to my previous message: type 0 is the terminator, not a cache
op, and there is no read-modify-write type. Ignore that version.

### 17.3 Register base: confirm on hardware (open)

The commands write relative to a firmware base pointer set during init.
Which IO-table entry it is hasn't been confirmed. Determine it safely while
entry 0 is RAM-backed (17.5, run B) before switching anything to real hardware.

### 17.4 iOS program for T8010 (not decoded yet)

On G9P the kext's own Fender ConfigRAM methods are panic stubs (section
1.3), so iOS most likely builds this write list in host memory and passes
its PA in init+0x8/+0xc. The kext code that fills it hasn't been traced. The
candidates are the users of the init buffer (section 7.4: `0x…601f550`,
`0x…601fa2c`, `0x…601fb04`, `0x…6021758`), with values probably from the
`sgx` ADT power properties and the IO-table setup. Next RE item.

### 17.5 Next runs

Free page used below: **S+0x38000** (PA 0x802438000), just past the
56-page mem-desc mapping (S..S+0x37fff). It needs no firmware VA; the
firmware maps it itself by PA.

**Run A — empty program (does init proceed?):**
- PA 0x802438000: one zeroed 4 KiB page. Entry 0 has type 0, so the program
  ends immediately.
- init page `+0x08 = 0x02438000`, `+0x0c = 0x00000008`. Everything else
  unchanged (§1–16).
- Same kick as before (EP 0x21, emulate the +0x2058 clear).
- Expected: the "init sequence memory" error is gone and the power path
  continues. Watch for the next crash/string, the power-state flag
  `[power_state + 0x38]` (VA 0x130038 → S+0x30038), and the shared-page words.

**Run B — find the base (only after A passes):**
- Program page = two type-1 markers, then the terminator:
  - entry 0: `{val_lo 0xA5A50010, 0, off 0x10, 0, type 1}`
  - entry 1: `{val_lo 0xA5A50020, 0, off 0x20, 0, type 1}`
  - entry 2: all zero (end)
- After the run, search entry 0's RAM (R = S+0x200000 .. +0x3fffff) for the
  markers. **Found at R+0x10/+0x20 → base = IO-table entry 0 (Fender).**
- Not found → the writes went to another mapping. If that faults, the
  CrgA DFAR = base+0x10. Match base against the shared-page mirror VAs
  (`shared + 0x13c + 0x18*k + 0x8`) to get entry k. Keep entry 3 (RGX)
  at PA 0 throughout, so nothing here can touch real GPU registers.

Once the base is known and the real iOS program is decoded (17.4), entry 0
can move from RAM to the real Fender window 0x201d00000 for the actual
power-up.

## 18. Real core power-up (2026-10-29)

**Confirmed on the still-running J71b USB shell.** This supersedes the power
blocker in sections 1 and 17 and the original REFERENCE.md.

### 18.1 The omitted state request (high)

Firmware `0x6b12..0x6b3e` checks shared+0x438 and +0x43c. With either zero,
it sets `power_state+0x38 = 1` **without requesting hardware power**. Otherwise
it calls `0x16d40(target, 2, 1000)` before the +0x2058 reset step.

These shared fields are copied from P+0x93c and P+0x944 at `0x17ce8..0x17cf8`.
The kext writes P+0x93c from global `0xfffffff007b3686a` bit 1
(`0xfffffff006012cec..2cf4`), and P+0x944 from accelerator vtable+0x798
(`0xfffffff006012d00..2d14`). Both were left zero in our synthetic init data.
The genuine values and other required power-management fields still need tracing.

`0x16d40` performs the real transition:
- For a nonzero target r4, builds `target | 0x10` (`0x16df2`).
- Writes that to **entry0+0x1000** (`0x16e1e..0x16e2a`).
- Waits until `[entry0+0x1000] & 0x1f == target` (`0x16e86..0x16e94`).
- Updates software state only after the hardware acknowledges.

The +0x2058 poll `0x6750` waits for masked bits to **clear**, not become set
(the earlier wording in section 15 was wrong).

### 18.2 Live evidence (high)

Before the new request, with agx-init12's real Fender mapping and RAM RGX:
- Fender+0x10 = 7; +0x14 = 0; +0x1000 = 0; +0x1004 = 8.
- +0x2048 = 1; +0x2050 = 0xf; +0x2054 = 0x2f; +0x2058 = 1.

One AP write, **`devmem 0x201d01000 32 0x11`**, matching the firmware routine:
- +0x1000 becomes **1**, +0x14 becomes 2, +0x2058 becomes **0**.
- Real `devmem 0x201000018 64` returns **0x00000000011b0602**.
- Real `devmem 0x201000020 64` returns **0x00000000000d0a00**.
- No Linux panic or new RTKit crash was observed.

Logs saved locally under `out/resume/fender-request11.log` and
`out/resume/core-identity.log`. `tools/fender-power-on.sh` reproduces the state
request with a bounded wait and does not read RGX unless state 1 is acknowledged.

This proves power and register access only. It does not prove the RAM-backed
firmware's register setup was applied to real RGX, shader compatibility, command
submission, or rendering. The 0x20 register here is the legacy CORE_REVISION;
interpreting it as the newer packed 64-bit BVNC would be incorrect.

## 19. Real-register initialization, rings and coherency (2026-10-29)

### 19.1 Real RGX bring-up (confirmed)

`agx-init13.sh` is a BEFORE_INIT hook for init12. It requests real power and
maps IO entry 3 to real RGX (0x201000000, size 0x20000), with an **empty**
init-sequence page. No RAM-only marker program is used against hardware.
An EP 0x21 kick reaches the fixed initialization code (0x57c0 onward):
- RGX+0x600 changes from 0x30303000 to 0x38482f00.
- RGX+0xe200 becomes 4; +0xe208 becomes 0x4bd22db4.
- Hardware polls on +0x11f00, +0xcd8 and +0xcb8 complete (readback 0).
- Next abort: pc 0x18376, loading a null T+0x7e0 pointer, AFTER fixed init.

`agx-init14.sh` supplies that pointer. T = init+0x1c (VA 0x104000):
- T+0x7e0 = VA 0x126000, an array of **256 u64 physical GPU context roots**.
- Root[0] = scratch PA +0x40000, one zero page; remaining roots/masks = 0.
- T+0x7e4..+0x800 are eight 32-bit masks for contexts 0..255. With masks 0,
  firmware still programs context 0 (0x18376..0x1838c).
- Next abort: pc 0x200f4, loading null X+0xd0 during control-ring processing.

This means the fixed hardware initialization AND power-up function returned.
It does not validate the empty root as a working GPU address space.

### 19.2 Host rings (confirmed format; engine naming inferred)

`agx-init15.sh` supplies the third index pointer and control ring:

| X offset for ring i (0..12) | Meaning |
|---|---|
| +0x0c + 0x10*i | pointer to consumer index |
| +0x10 + 0x10*i | pointer to cache-synchronized producer index |
| +0x14 + 0x10*i | pointer to producer index |
| +0x18 + 0x10*i | pointer to ring entries |

The old X[2] = Z at +0x8 is separate from these fields. The descriptors start
at +0xc, not +0x8 as guessed in section 12.

Control ring i=12: 256 × **32-byte entries**, data at VA 0x127000 in init15.
Firmware 0x200ec..0x20110 synchronizes data then updates the cached index;
0x20904..0x20940 consumes and dispatches opcodes 3..31. Opcode 0 is ignored
and consumed, making it useful for a non-job smoke test.

Work rings i=0..11: four priorities × three engines, **20-byte entries**, 256
slots (0x20116..0x201e4). For priority p, rings 3*p + {0,1,2} correspond to
TA/3D/CL (engine names medium confidence). The third engine's entry has:
- +0x08: firmware-VA pointer to queue object (at least 0x8c bytes).
- +0x0c: u32 engine type = 2.
- +0x10: u16 event/index value.
- +0x12, +0x13: byte flags (precise semantics still open).
- queue+0x88: pointer to a status/tracking object (at least 0x24 bytes).
The consumer calls 0xdac6(queue, entry[0x12], 2) at 0x20788. This is a next
RE entrypoint, NOT a complete compute submission format yet.

### 19.3 Runtime updates need inner-noncacheable mappings (confirmed)

With historical mem-desc flags 2 (attr 0x11b), firmware reached READY and
processed the initial kick but did not observe a later producer-index write.
Clearing the flags (attr 0x41b) fixed it: consumer/cache/producer all became 1.

Firmware mapper 0x247c0:
- attr 0x11b -> MAIR index 0, byte 0xff (write-back).
- attr 0x41b -> MAIR index 2, byte 0xf4 (outer write-back, **inner NC**).
- MAIR0 literal at fw 0x2421c = 0x4ff404ff.

Do not call 0x41b wholly uncached or fully coherent; only the inner-cache
behavior and this runtime shared-memory test are established.

### 19.4 Repeatable smoke (passed on hardware)

`sh /run/agx-smoke.sh` reloads the experiment and tests:
1. Real Fender + real RGX initialization with an empty program.
2. Control opcode 0 consumed: indices 0 -> 1, no crash.
3. Runtime map: VA 0x140000 -> scratch PA +0x3a000, two pages, flags 1.
   Mapping-ring consumer advances 0 -> 1.
4. Control-ring buffer pointer X+0xd8 changed to the new VA; next opcode 0
   consumed through that mapping: control indices 1 -> 2.
5. Zero crashlog bytes, Fender state 1, both identity registers readable.

This validates the **ARM firmware's** runtime mapper, not GPU PTEs. Firmware
0x18352 programs RGX MMU context roots from host memory. Earlier claims that
the mapping ring builds GPU page tables should not be relied upon.

Logs: `out/resume/init13-real-kick.log`, `crash13.bin`, `crash14.bin`,
`init15-nc-control.log`, and `agx-smoke.log`. No shader/compute/render job ran.
For real Fender, scratch R+0x110000 is NOT the live shared page; use U+0x14
for READY instead of interpreting zeros in that historical RAM shadow.

### 19.5 Kext init program builder (static trace, not tested as a real program)

The candidate in section 17.4 is now traced:
`0xfffffff006021d10` zeroes program length (+0x10fc), calls accelerator
vtable+0x708 with (0, *[firmware+0x4e0], 1), then +0x710 with (1), then
appends the type-0 terminator to firmware+0x10a0's buffer.

For the G9P_A0 vtable at 0xfffffff006e1c868:
- +0x708 -> 0xfffffff006030958: write RGX+0xe140 = selector arg, then
  RGX+0xe148 = supplied physical address >> 12 (type-3 sequence entry).
- +0x710 -> 0xfffffff006032568: get a time value and write RGX+0xe160.
- +0x798 -> 0xfffffff006034314: returns 1 (P+0x944).

This program initializes MMU/debug context selection and timebase; it is NOT
the missing Fender power request. Empty-program hardware init already works.
Trace firmware+0x4e0's source and the host GPU page-table builder next.

## 20. Compute follow-up through experiment 35 (2026-10-29)

The detailed current ledger, commands, layouts, evidence and open questions are
in [COMPUTE.md](COMPUTE.md). Key updates that supersede earlier notes:

- Compute queue parsing, scheduler initialization, microsequence dispatch, host
  stamps and event notification have been exercised. Experiment 25 completes
  a **CPU-side cancellation** sequence; it launches no GPU work.
- The real terminate-only stream reaches CDM start but faults with
  `RGX+0xe150 = 0x119`. Experiments 26–35 do not produce a completed GPU job.
  A zero firmware crashlog is not proof of forward progress: recovery can stop
  the GPU without crashing the coprocessor.
- X+0x1ec/+0x1fc were incorrectly classified as pointer slots in section 13.
  The compute layout initializes them to 0; +0x1fc tracks outstanding work.
- V+0x45b4 must request scheduler initialization; otherwise the first compute
  command branches through a null callback. Queue+0x0c needs a scheduling pool.
- T+0x7dc is the MMU-generation array; T+0x7e0 is the physical context-root
  array. A full context-0 invalidation is acknowledged, but the job still faults.
- Kext `0xfffffff0060365a8..0x6036668` establishes G3–G9 three-level GPU table
  geometry and flags. See COMPUTE.md for exact fields and the synthetic layout.
  This is static format evidence, not successful GPU translation validation.
- Kext P[0..0x27] uses fixed constants, not the scratch memory range or root:
  `{0x600000000, 0xffc00000, 0x300000000, 0x300000000, 0x1ffff8000}`.
  Hook 31 corrects the earlier probe's guesses.
- Module reload restarts the IOP but does not reliably reset RGX. Hook 32 cycles
  Fender state 0→1; the MMU fault clears, then recurs on real submission. An
  empty kick after the same init remains fault-free.
- MMU root readback needs its clock forced ON: setting RGX+0x0 bits 17:16 to
  1 gives root PFN 0x802440, matching the supplied root. Mode 2 is AUTO, not OFF.
- Both IMG/Rogue and Apple-style candidate CDM terminate encodings were tried
  without success. Neither control-stream compatibility nor USC ISA compatibility
  has been established. Do not select a Mesa compiler/backend yet.

Latest evidence: `out/resume/compute35-real-slc-bypass.log` and
`compute35-debug.bin`. Linux and USB remain responsive; no firmware patch, kernel
module changes, Mesa changes, or persistent-device storage writes were made during
these probes. This section records the status at 35, superseded by section 21.

## 21. Real GPU completion after DFU resume: experiments 36–49

**Working baseline: `agx-init46.sh`.** The real GPU consumes a terminate-only
stream and produces a compute-finished IRQ. The firmware executes normal
FinalizeCompute/cache flushing, retires the queue (state 3, IP 0x144080), writes
both stamps to 1 and advances the host event producer to 1. No MMU fault or
firmware crash. This was repeated successfully after intentionally faulting 49.
**No USC shader or rendering result has been demonstrated.**

Three important corrections to earlier compute assumptions:

1. **RGX+0x480 is the active CDM stream base**, not +0x498. Experiment 40 put an
   unmapped address in +0x498 with no fault; 41 put it in +0x480 and faulted at
   exactly VA 0x400000. Hook 42 supplies stream VA 0x200000 there and the owned
   context/storage VA 0x202000 at +0x498. The original read fault 0x119 was at
   VA 0 because the actual stream register had been left zero.
2. **Wait mask 4 was correct.** Trace 0x102's arguments are r2, r3, stack0,
   stack1; the successful GPU event has values {3, 0x80000000, 4, 0}. The 8 and
   0x8000 alternatives in 38/39 were wrong. With mask 4, hook 44 enters normal
   finalization but encounters a separate write fault 0xff251 at VA 0.
3. **Q[0:8] supplies the flush scratch/fence address.** Firmware 0x1bb0a copies
   it to local 0x8dd50; 0x597c..0x599c programs RGX+0xe240. Hook 46 sets Q to
   mapped GPU VA 0x203000, fixing finalization without a null mapping. Hook 45's
   temporary null-page catch was a diagnostic, not the final solution.

GPU MMU geometry is now validated for these mappings and fault controls. Decode
all 64 fault bits: address = `(status >> 28) << 4`. The runner's low-32-bit print
alone discards the address. The full fault 0x0000400000000119 identifies VA
0x400000; 0x0300400000000299 identifies PDS code VA 0x300400000.

With the actual stream register corrected, Rogue terminate **0x80000000** works;
0x40000000 instead faults reading VA 0, consistent with a Rogue link to 0. The
old comparison 34 never exercised the actual stream and must not be used to infer
an Apple frontend. Shader/PDS ISA compatibility remains a separate question.

Non-empty dispatch follow-up:

- 47: tentative PDS HALT-only kernel; stalls, no fault. Its group dimensions
  were initially wrong (counts are minus-one encoded).
- 48: corrected 1×1×1 groups and provisional DOUTC/HALT; still no completion.
- 49: intentionally unmapped PDS code offset 0x400000 produces fault at
  0x300400000. The kernel reaches code fetch, but valid-code candidates still
  do not finish. Investigate PDS task/ISA/USC dispatch requirements next.

New session USB port: `/dev/cu.usbmodem21301`; RAM boot and Linux readiness both
verified. Evidence: `dfu-resume-smoke.log`, `compute41-unmapped-480.log`,
`compute44-real-completion.log`, `compute46-real-completed.log`,
`compute49-pds-unmapped-code.log`, `compute46-repeat-after49.log`, and accompanying
verified binary trace captures under `out/resume/`. All changes remain uncommitted.
The user then made the device unavailable, allowing the offline PDS investigation.
That pause ended when they returned it in DFU; see section 22 for the new session.
Offline evidence tooling (`tools/gpu_evidence.py`) checks recorded 46 captures and
rejects stalled or faulted probes. 27 host tests pass, including reference checks.

## 22. PDS candidates tested after second DFU return: experiments 50–54

The existing RAM payload booted and Linux readiness was verified. Current serial
port: **/dev/cu.usbmodem1301**. The old cached module was absent; a new module was
built from unchanged source against matching existing kernel output using the
local kernel-toolchain container. No kernel or firmware source change, no device
storage mount. Module artifact, SHA-256 and exact recipe are in COMPUTE.md.

Results:

- Baseline **46** passed before and after this session; both log/trace pairs pass
  `gpu_evidence.py validate`. The device was restored to this working state.
- **50–52:** full reference fence, empty/shared-allocation, and short fence all
  stall at the IRQ wait, zero stamps/event producer, no MMU fault/crash. Downloaded
  stream/code/constants match the planned bytes. The offline setup differences
  were not sufficient to explain/fix the stall.
- **53:** maps an owned writable output page at GPU VA 0x204000 and a fresh PDS
  page at heap+0x4000. Generic Rogue LIMM/ST/WDF should write 0x1357; CPU sentinel
  **0xabadbeef remains unchanged**. No PDS store or shader result is proven.
- **54:** removes the guard and DOUTC, uses fresh offsets, and targets unmapped
  VA 0x400000. The expected write fault does not appear. No instruction execution
  can be claimed from this negative result.
- Temporary PDS-only and selected PDS/USC/MCU/CDM/BIF clock-forcing tests after
  stalls do not help. Original CLK_CTRL **0xa02a82000a2a2a0a** is restored and
  independently read back. Startup/enable/cache requirements remain open.

Latest evidence under `out/resume/`: `compute50-fence-real.log`,
`compute51-empty-real.log`, `compute52-short-fence-real.log`,
`compute53-store-real.log`, `compute54-unguarded-write-fault.log`, their verified
state/stream captures, `compute54-clock-restored.log`, and
`compute46-after54.log` / `compute46-after54-debug.bin`. The structured
`pds50-54-observations.json` verifies all payloads, marker outcomes and baselines.

The next useful evidence is a native G9P PDS program or instruction-progress
inspection, rather than another assumed generic HALT. Do not infer ISA reuse
from code fetch or numerical C encoder agreement. No USC shader or rendering
result has been demonstrated. All changes remain uncommitted.
See COMPUTE.md for current layouts, reproducibility and evidence paths.


## 9. GPU performance states (2026-11-01)

**Solved (2026-11-01): the GPU's performance state is Fender + 0x1000, the
register the driver already used to power the core on.** Its low four bits
are the state, 0 off and 1 to 6 the steps of the `sgx` table; writing
`state | 0x10` requests one, and the low five bits read back the state once
reached (about 70 us). The firmware's setter (fw 0x16d40) writes exactly
this, and only when P+0x93c and P+0x944 are both set (copied to fw globals
0x30438/0x3043c at init; the kext sets them from a feature flag): with
them 0, as in our layout, the firmware never touches the register, and our
driver's power-on request for state 1 left the GPU at the lowest clock.
The driver now requests state 6 (`apple_perf_state`, default 6). TESTED:
`vk-tri` with 512 multiply-adds per pixel, full screen, 8.69 ms in state 1,
5.47 ms in state 3, 3.70 ms in state 6, identical pixels; `vk-suite`
passes; Hyprland with live blur behind a moving floating window (18-20
renders a frame) from 33.3 ms to 19.0 ms per frame (471 of 547 frames
under 20 ms). Since then Linux scales it (devfreq on an OPP table m1n1
fills from the Apple device tree: bringup/power-display.md).

The notes below are from before this was found.

**The GPU runs in performance state 0: the firmware does no DVFS in our
setup.** The firmware's power-state struct (our layout: heap + 0x69000,
`HEAP_POWER_STATE`; the kext publishes its fields as `fw_power_state`
+0x0c, `fw_power_substate` +0x10, `fw_perf_state_lo/hi/select` +0x2c/
+0x30/+0x34) reads substate 4, powered (+0x38 = 1) and perf state lo, hi
and select all 0, idle and under full load. Writing lo = 1, hi = 6 there
changes nothing (select stays 0, same render times): the firmware takes
its limits elsewhere.

- **The table**: the `sgx` node's `perf-states` (pairs of frequency in Hz
  and voltage in mV), `perf-state-count` 7 (state 0 off), and the
  `gpu-perf-*`/`gpu-pwr-*` controller properties are filled by iBoot at
  boot; the restore device tree has `perf-states` zeroed. The live values
  can be read on the running iPad: the Apple device tree stays in RAM
  (several copies; `/dev/mem`, scanning for the property name). Per-chip
  data, not kept in this repository.
- **The kext** (`agxg9p.c` decompilation of the 17.7.11 kext) copies
  `perf-states` into the accelerator at +0x3348 (count), +0x334c (tables),
  frequencies from +0x3350, voltages from +0x3390; the controller
  properties (`gpu-device-max-power`/`gpu-max-power`, `gpu-pwr-*` gains and
  filters, `gpu-perf-base-pstate`, `gpu-perf-tgt-utilization`,
  `gpu-perf-filter-time-constant*`) go to accelerator +0x2178..+0x2228
  (FUN_fffffff006010a30). The firmware runs power-limit, boost and
  performance controllers (`fw_power_controller_in_charge`,
  `fw_power_limit_controller`, `fw_power_boost_controller`): with a zero
  power budget in our init data, holding the lowest state is plausible.
- **Open**: where the accelerator's +0x2178.. block and the table reach
  firmware memory (init page, section 7.4, or a shared power struct), and
  which PMGR registers the firmware programs per state.
- **Measured in state 0**: about 5.6 GB/s for a full-screen clear and
  store (1536x2048), about 39 G instructions/s of fragment ALU work
  (`vk-tri` with 512 multiply-adds per pixel).
- **The kext initializes the power-state struct** (0x4318 bytes, the
  firmware's at X+0x301; FUN in `agxg9p.c` around the 0x4318 memset):
  +0x2c = 0x100000001 (perf lo = hi = 1), +0x54 = 100, 0x160 bytes at
  +0x5c copied from the power-controller object (+0x640; content not
  traced yet), the power/perf controller parameters at +0x650..+0x7d4
  (from accelerator +0x2178..+0x2230), and per-state frequencies in MHz
  into a second firmware struct (power controller `[0x42]` +0xa5c count,
  +0xa60.. and +0xea0.. two tables). Ours stays zero.
- **PMGR has no GPU performance domain**: the live device tree's
  `pmgr` lists SOC, CPU, MEM and AES (`perf-domains`; `perf-regs` at PMGR
  +0xb4000), and `voltage-states9` repeats the GPU table: the GPU clock is
  the firmware's to set. The MEM domain (memory clock), which iOS raises
  for GPU work, is untouched under Linux and may limit bandwidth as much.
- **Memory looks slow too**: a CPU memset on the iPad reaches about
  5.3 GB/s and a memcpy about 6.9 GB/s of read+write traffic, the same
  ceiling as the GPU's renders (about 5.6 GB/s), where an A10 should do two
  to three times that. The MEM performance domain (memory clock) is the
  first suspect: nothing under Linux raises it. ApplePMGR (iPadOS 17.7.11,
  `__TEXT_EXEC` 0xfffffff005aac000) parses `perf-domains` (28-byte entries:
  id, flags, name; 0x118-byte domain records, `voltage-states%u[-sram]`
  per domain) around 0xfffffff005ab0a4c and `perf-regs` (16-byte entries:
  register window, offset, field, flags) in the function at
  0xfffffff005ab8ea8 before a perf-control setup (FUN_fffffff005ac74ec);
  how a domain's state is written to hardware is not traced yet. PMGR +
  0xb4000 (the `perf-regs` offset) reads zero in both windows.
- **SoC and memory performance state: PMGR + 0x68000** (iOS 10
  `AppleT8010PMGR::setPerfState`, unstripped): domains 1 (SOC) and 3 (MEM)
  have two states each; the low 4 bits of PMGR + 0x68000 take
  `table[soc][mem]` = {{0xd, 0xa}, {0xb, 0xc}} (read-modify-write), bit 31
  is set while the change is pending. Linux boots with 0x...ddd (both low;
  the `mcc` node's `perf-state-freqs` are 396 and 792 MHz). Writing 0xc
  (TESTED, 0xddd -> 0xccc): CPU memset 5.2 -> 10.2 GB/s, memcpy 6.8 ->
  13.6 GB/s; GPU empty full-screen render 2.24 -> 1.32 ms; ALU-bound
  shaders unchanged (GPU clock). A Linux driver for this (a devfreq or the
  GPU driver asking for it while busy) is still to be written.
- **GPU state table goes to P**: the kext's `[0x42]` struct is P (it also
  writes P+0x16e4); P+0xa5c = number of states above 0, P+0xa60.. and
  P+0xea0.. = per-state frequencies in MHz (16 slots). The firmware reads
  P+0xa5c in its DVFS code. Written at runtime they change nothing: they
  are read at init. The power struct's +0xc is the controller mode (the
  firmware's controller runs in mode 2; iOS also starts at 0 with
  +0x10 = 4) and +0x54 the current level in units of 100 per state; what
  moves the firmware to mode 2 is not found yet.
- **The firmware's DVFS step** (decompiled firmware, FUN_00006a98): after
  its controller (FUN_00007d16) computes the level +0x54 (100 per state),
  it sets +0x2c = level / 100 and +0x30 = that or one more (the two states
  it alternates between), and the mode +0xc: 0 on a whole state, 1 between
  two, 2 below state 1. So lo, hi and mode are outputs, and ours (level 0,
  mode 0, lo and hi 0) mean the step never runs: our GPU never leaves its
  boot clock. It is reached through a pointer (no direct call, and neither
  0x6a98 nor 0x6a99 appears in the image), likely a periodic sample timer
  (iOS: `gpu-power-sample-period`, `gpu-pwr-sample-period-aic-clks`). Next:
  find what schedules it and what it needs from P/the power struct.
