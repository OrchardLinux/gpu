# A10 GPU: the first look (2026-10-28 to 2026-10-30)

The first notebook of the A10 work, kept as written: is the Rogue core
reachable, what does it identify as, and what state is the gfx-kf
coprocessor in? It started as orchard's `examples/gpu-001`, whose payload is
now `tools/a10/`. For the current state read [the bring-up guide](bringup/README.md).

## What is known going in

From the iPadOS 17.7.11 kernelcache and the captured J71b ADT:

- The GPU is a PowerVR Rogue derivative (`AGXG9P`; the kext still prints
  `RGX_CR_*` register names). No Mesa or Linux driver covers it; Mesa's PVR
  driver lists 6XT/7XE parts but no 7XT.
- Apple does not run Imagination's META firmware on it. `gfx-kf` is an RTBuddy
  (RTKit) coprocessor with firmware `GFX`, booted by
  `AGXFirmwareKextG9PRTBuddy` (`requestFirmwareBinary`, `getBootConfigOffset`).
  The ADT `sgx` node still carries a `meta-sw-interrupt` property.
- One power state, `GFX` (pmgr id 0x7c), covers the core and gfx-kf.

- The kernel-side model is Asahi's, not Imagination's: `AGXArmFirmware`
  (`kickFirmware`, `waitForFWAlive`), channels (`AGXTAChannel`, "Invalid Channel
  Command Type"), event/statistics/trace rings, and `AGXParameterManagement`
  for parameter-buffer growth.
- The hardware underneath is still Rogue: `RGX_CR_MMU_ENTRY` (Rogue MMU, not
  Apple UAT) and `RGX_CR_USC_*` (Rogue shader core). The same kext family also
  has META-only paths ("this code should only be run on META GPUs"), probably
  for the older chips.

Working hypothesis: a hybrid driver. Firmware and channel handling are shaped
like `drm/asahi` (on mainline `apple-rtkit`); MMU and register knowledge come
from `drivers/gpu/drm/imagination`; userspace might build on Mesa `pvr` if
shader and control-stream compatibility are demonstrated. Neither is established
yet. This probe checks the hardware and firmware interfaces on real hardware.

## Kernel driver (2026-10-30)

The mainline `powervr` driver now runs the A10 through an Apple firmware
variant: firmware boot, core power, init data and a completed compute self-test
from inside the kernel, plus `/dev/dri/renderD128`. Design and milestones:
[DRIVER.md](DRIVER.md).

## Current status (2026-10-29, through experiment 69)

**A native shader now runs on the A10 under Linux.** Experiment **66** dispatches
the `applegpu_g9p` empty kernel, compiled offline by Apple's `metal-tt`. The
CDM record, PDS program and PDS data are exactly what iPadOS submits for a Metal
dispatch, captured with `ios-capture/` under palera1n. It completes (both
stamps, no fault). Control **67** points the same dispatch at an unmapped shader
page and faults at exactly that address. So the USC fetched and ran the code,
and the USC code base is 0x300000000. Earlier probes failed because A10 CDM
kernel records are 8 words (ours were 7) and because of a wrong PDS data address.
**Experiment 68 then ran Apple's `store_marker` kernel and read `0x1357` back
from the bound buffer; control 69 moved the binding and the write moved with
it.** Compute shaders work end-to-end from Linux. Rendering, a DRM driver,
our own shader compiler and an accelerated desktop are not done yet. Details:
[COMPUTE.md](COMPUTE.md).

The key fixes were the actual stream base at **RGX+0x480**, not +0x498, and the
missing flush scratch/fence address in **Q[0:8] → RGX+0xe240**. GPU VA 0 remains
unmapped in the working layout. Controlled faults validate the address decoding.

**Latest handoff:** [COMPUTE.md](COMPUTE.md) records experiments 16–61, exact
commands, layouts, evidence and next checks. The user returned the device in DFU;
Linux is running again on **`/dev/cu.usbmodem1301`**, with a rebuilt matching module.
The device was restored to the successfully repeated **46** state after all tests.

[PDS-OFFLINE.md](PDS-OFFLINE.md)'s reference-shaped candidates **50–52 have now
been tested**: all stall, with zero stamps and no MMU fault/crash. Downloaded
stream/code/constants match their plans. Probe 53's PDS-store marker stays at
0xabadbeef; 54's unguarded store to an unmapped address produces no expected write
fault. Temporary clock-forcing tests did not help and original clocks were
restored. **PDS branch target fetch is shown by 55; PDS retirement and the
DOUTU→USC path remain unproven (56–61).**

**27 host tests pass**, including generic Mesa C encoder/disassembler and XML
comparisons, which do not certify A10 ISA compatibility. Saved pre/post-session
baseline captures pass the evidence checker. `agx-smoke.sh` is still a separate
bring-up test, not an acceleration test.

**Real RGX power-up and identity reads now work.** With the experiment firmware
running and GFX PMGR on, `Fender+0x1000 = 0x11` requests state 1. Readback is
`0x1`; the previously stuck `Fender+0x2058` clears to 0. Reads of real
`RGX_CR_CORE_ID` (`0x201000018`) and `CORE_REVISION` (`0x201000020`) return
`0x011b0602` and `0x000d0a00`, respectively, without a panic.

The request is taken directly from firmware `0x16d40`, not guessed. Our zeroed
`P+0x93c/+0x944` skipped that routine and set a **software** powered flag instead.
This explains why the earlier RAM-backed success did not power real hardware.
See [FENDER.md section 18](FENDER.md#18-real-core-power-up-2026-10-29).
`tools/fender-power-on.sh` reproduces the state request and guards identity reads.
This is not yet hardware rendering or a complete GPU driver.

**Reproducible real-hardware smoke test:** stage `tools/agx-init12.sh` through
`agx-init15.sh`, `tools/fender-power-on.sh`, and `tools/agx-smoke.sh` to `/run`
with `tools/serial_put.py` (the experiment module must be at
`/run/apple_gpu_iop.ko`), then run `sh /run/agx-smoke.sh` over USB serial.
Use an idle timeout of at least 8 seconds with `serial_cmd.py` so the script's
3-second initialization wait does not truncate capture.

The smoke test passed: real-register initialization, inert control-ring entry
consumption, runtime ARM mapping, and access through the newly mapped VA; zero
firmware crashlog bytes. It enqueues **no GPU job**. Shared indices must use
inner-noncacheable firmware mappings (mem-desc flags 0), not the historical
flags 2: otherwise runtime host updates remain invisible to the IOP.

Experiment 25's **CPU cancellation** and experiment 46's **real GPU terminate-only
completion** are distinct milestones. The latter now validates the tested GPU VM
and submission/completion path, not a complete MMU implementation or shader ISA.

Current next target: complete a non-empty PDS/USC dispatch and obtain a known
shader-written result. Experiment 49's expected fault at GPU VA 0x300400000 proves
that the test kernel reaches PDS code fetch, but the valid-code candidates have
not completed. Do not assume compiler compatibility yet. Details are in COMPUTE.md.

## Results on J71b (2026-10-28; historical progression)

Reverse-engineering notes with kext addresses: [FENDER.md](FENDER.md).

| Step | Result |
| --- | --- |
| `ps_gfx` (pmgr+0x80328) f/f | Safe. GFX-SGX/-KF/-BUSY have no own power state. |
| Any `RGX_CR_*` read (`0x201000018`) | **Panics.** Fender only powers the Rogue core when the GFX firmware tells it to. The AP request bit (`+0x10`) is not enough. |
| Fender window `0x201d00000` | Is 0x5000 long. `+0x4000` and above fault. |
| gfx-kf `0x201d20000` | AppleA7IOPV2, the same IOP block as Paul's SIO (`apple-sio-core.c`). |
| Firmware boot (`gfx-boot`) | Image at a 1 MB uncached buffer, both remap windows, mailbox, run bit `0x201d02048` → **RTKit HELLO v12** right away. |
| RTKit management by hand | HELLO_REPLY accepted. EPMAP: endpoints 0, 1 (crashlog), 0x20, 0x21 (Asahi AGX layout). Crashlog buffer request on ep 1. |
| Mailbox framing | One 64-bit word: endpoint in bits 63:56, payload in bits 55:0. Mainline `apple-rtkit` (v10–12) fits with a mailbox backend. |
| Clean handshake (`rtkit-mgmt`, no doorbell) | Completes: EPMAP, STARTEP, crashlog buffer, IOP power ack 0x20, AP power ack 0x20. The earlier stall came from wrong EPMAP replies and ringing `+0xc004`/`+0xc024` (that write stops the firmware reading its inbox). |
| Kernel (`apple_gpu_iop.ko` + mailbox variant) | `apple,t8010-a7iop-mailbox` in `drivers/soc/apple/mailbox.c` plus DT nodes `gpu@201000000` and `mbox@201d24000` (IRQ 189–192). Mainline `apple-rtkit` boots the firmware: "RTKit: Initializing (protocol version 12)". recv IRQ fires. Endpoints 0x20/0x21 start and stay silent: they wait for host init data. |

Firmware: `AGXFirmwareKextG9PRTBuddy` `__TEXT,__const`, file offset `0xd41edf`, `0x5b320` bytes, ARM32, load base 0, runtime region `0x8f000`. `rootfs/usr/share/gpu-001/*.bin` is extracted locally and ignored by Git.

### AGX init on endpoint 0x20 (crash-driven, `apple_gpu_iop` debugfs)

Message `0x81 << 48 | PA` (44-bit byte PA of a one-page init buffer). The firmware copies the first 0xa4 bytes. Each module reload power-cycles the firmware, so every crash is one cheap iteration.

| Init page content | Firmware result |
| --- | --- |
| all zero | "Unable to register init mem desc at PA_0 size:16384, status:0x80000002" |
| message PA >> 12 / >> 14 | "Unable to register init data at PA_<value> size:4096": the message carries the byte PA |
| whole page = candidate PA | "mem desc at PA_219C00000000008": the field sits at 4 mod 8 |
| `+0x8c/+0x90` = PA of a zeroed 16 KiB page, `+0x94` = 0 | mem-desc registered; next crash comes later (through `init+0x18`, the AGX context pointer) |

Field meanings come from firmware RE in FENDER.md sections 8 and 9.
| + mem-desc entry `{VA, PFN, 0, pages, flags}` → X page → P (`+0x640` = R) | VA ≥ 0x10000000: "Unable to map VA_… status:0x8000000B". VA 0x00100000/0x01000000 accepted. The firmware then writes R+0x110000+0x48 = 1 and data-aborts at pc 0x278c (r0 = 0x30000). |

Host tools in `tools/`: `serial_cmd.py` runs one shell line over USB serial;
`serial_put.py` uploads files and `serial_get.py` downloads them with SHA-256
checks. `agx-init2.sh` was the layout at this historical point, not the current
one. Current tests use `agx-init12.sh` plus chained BEFORE_INIT hooks through
`agx-init54.sh` (working baseline 46); see COMPUTE.md.
| `tools/agx-init4.sh`: mappings at VA 0x00100000 (X = {P, Q, Z}), init `+0x1c/+0x98/+0x9c/+0xa0` pointers | **"Ready" reached:** shared page `+0 = 1`, `U+0x14 = 1`; the firmware starts agx_recovery/interrupt/sampler/power tasks. Next crash is in the runtime (pc 0x5038). The GPU power-up path has not run yet. |
| `tools/agx-init6.sh`: 13 ring index pairs plus every X pointer the firmware reads (FENDER.md section 13) | **Init complete and stable**: no crash, idle loop, ready flags set. |
| Ring 0 indices made unequal, kick `0x83 << 48` | On EP 0x20: ignored. On **EP 0x21** (doorbell): the firmware processes the ring and data-aborts at pc 0x1820e (r0 = init+0x9c struct, r1 = 0x4560). |
| `tools/agx-init8.sh`: + mapping-update ring in V (`+0x455c/+0x4560`); power-state struct (≥ 0x41f8 bytes) on its own pages at VA 0x130000 | Init still clean. A doorbell kick reaches the power code: data abort at pc 0x6b54 via `0xc1001000 + 0x2058` (a firmware high-VA mapping, probably the MMIO I/O-mapping table we don't supply yet). |
| `tools/agx-init9.sh`: I/O table entry 0 ("Fender", `P+0x640`) RAM-backed at R, to trace the firmware's reset sequence | The reset sequence (`AGFHALExecuteResetSequence`) writes entry0+0x2058 first. The last two `CrgA` words are DFSR/DFAR: size 2 MiB → external abort on the L2 table walk at 0xc1202058 (page-table pool missing?). Size 0x4000 → **permission fault** at 0xc1003058, the same for every entry flag value. Mapper attributes are still being reverse-engineered. |
| Entry 0 read/write (`+0x14 = 1`; long-descriptor MMU, the DFSR codes are permission faults) | Reset sequence runs against RAM: it writes **Fender+0x2058 = 1** and polls. Clearing it from the host (emulating the hardware) lets the firmware continue to "Unable to register init sequence memory at addr 0 size:4096": it now needs the host-supplied Fender power-up program. |
| `tools/agx-init11.sh`: init-sequence program at `init+0x08/+0x0c` (20-byte entries `{val lo, val hi, reg, shift, type}`); I/O entries 1–6 backed by 128 KiB of RAM each | The program's register offsets are relative to **I/O entry 3 (RGX)**. The software power flag is set and bring-up writes reach RAM **without crashing**; this did not prove it returned from hardware polls (later RAM probes stalled until self-clearing bits were emulated). Captured writes include `0x600`–`0x730`, `0x12e0`–`0x1310`, an `0xe200` test pattern, `0x11f00` and `0x13800`. |
