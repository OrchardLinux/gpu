# J81 GPU follow-up, 22 November 2026: identity, always-on `dwi`, META core

Field report on one iPad Air 2 (J81, A8X/T7001). Continues [DWI-CORE-ID.md](DWI-CORE-ID.md). Tags: **E** measured on
the device, **I** inferred, **U** unknown. Source notes (all in
[mattonik/ipad-nixos](https://github.com/mattonik/ipad-nixos/tree/main/research), dated 2026-11-22):
`j81-gpu-identity-result`, `j81-dwi-always-on-result`, `j81-ablation-a1-id-result`, `j81-ablation-a2-id-result`,
`j81-gpu-driver-step1-result`, `j81-gpu-meta-read-result`, `j81-gpu-coremem-read-result`.

## Identity words (E)

After the same recipe, three reads in one irq-off batch: `CORE_REVISION` (`+0x20`) `0x00070500`, `CORE_ID` (`+0x18`)
`0x011b0803`, `+0x24` `0x00000000`. The offline prediction from the iPadOS kernelcache was a low half of `0x0803` (BVNC
7.5.8.3, "G4G A1"); it matched. The register layout follows the upstream PowerVR headers (`pvr_rogue_cr_defs.h`: ID in
bits 31:16, CONFIG in 15:0). **U:** meaning of the upper half `0x011b`.

## `dwi` always-on replaces the late store (E)

With `&ps_dwi { apple,always-on; };` in the J81 DT, `0x20e020120` reads `0xff` from the first snapshot and stays, no
store from userspace is made, and the run gives the same words, the same GFX voltage word `0x164`, and the same PMIC
row `0x0128` -> `64 00 64 00`, held at +10 s. One run; the production Wi-Fi kernel carries the patch now.
**Cost (U):** the domain stays powered; power not measured.

## Which steps are needed (E, partial)

Omitting only the PLL1 `+0x1008` write, or only the PLL4 `+0x4008` write, each gave a normal no-core observation and
then the same identity words. This does not show either write is unnecessary for firmware start, and the other steps
(MCC group, TVM, bridge tables) and combinations are untested.

## The first RGX page and the META core (E)

An in-kernel driver does the whole recipe step by step with old-value checks and reads allow-listed registers one per
stage (so a hang names its register). All reads returned. Highlights (names from the upstream PowerVR headers; Apple's
integration is **U**): `SOFT_RESET` 0 (nothing held in reset); `CLK_CTRL` `0x2a2aaaaa`/`0xa02aaa00`;
`META_SP_MSLVCTRL1` `0x07000040` (slave port ready and idle). Through the slave port (address select in `MSLVCTRL0`,
data in `MSLVDATAX`, bounded waits): `META_CORE_ID` `0x141e0203` (version byte `0x1e` = MTP219 in the upstream table),
`T0ENABLE` `0x0201c032` and `T1ENABLE` `0x0201c132` (bit 0 clear: not running), `T0STATUS` `0x00020000`, `TXCLKCTRL`
`0xaa202222`, both MMCU cache controls 0, `MMCU_SEG0_BASE/LIMIT` `0x08000f02`/`0x17fff000`.
The coremem code (`0x80000000`) and data (`0x82000000`) windows return the same eight words, non-zero and
high-entropy (`0x52eab189 0x02080040 ...`): aliasing or ignored upper address bits, and probably uninitialised memory
rather than firmware (**I**, not checked across boots).

## Reading the upstream PowerVR driver

Mainline `drivers/gpu/drm/imagination` already contains a META boot path (`pvr_fw_meta.c`, `pvr_fw_startstop.c`,
`pvr_rogue_meta.h`). Its register and boot sequence is a useful map; its firmware interface expects Imagination's
current firmware, which probably differs from Apple's (**I**).

## Limits

One device, one run per item, no firmware loaded, nothing written to GPU memory. Reads of the META register space and
two address-select writes to `MSLVCTRL0` are the only GPU-side writes besides the power-up recipe.
