# From the A8 to the A8X (T7001, iPad Air 2 J81/J82)

What our A8 (T7000) stack would carry over to the A8X, and what has to change. This is a static comparison
of Apple's two kexts and firmware images in the iOS kernelcache **[KC]**, checked against the J81 hardware
results in [../../a8x/](../../a8x/README.md) where those exist (**[HW-J81]**, other contributors' device). It
has not been run on an A8X with our driver.

## What carries over

- **[KC]** Apple's A8X kext (`AGXG4G` 133.6) is the A8's (`AGXG4P` 133.6) with chip constants changed: about 76 %
  of the instructions are equal. Same object size table and 0x30-byte ring control, same heap bases and PLATFORM
  fill, same BIF MMU boot writes, the same Fender writers and power states, reset stream, GART, ring and channel
  code, segment MMU set-up, recovery and quiesce.
- **[KC]** The same LDR format and the same 27 configuration writes, byte for byte; the same border-colour table.
- **[KC]** The device-tree GPU node matches the A8's (`gpu,t7001`, same registers, IRQs 134-138, the same firmware
  interrupt tuple, PMGR gate 124).
- **[KC][HW-J81]** The same PMGR offsets: MISC_ACG, SOC_TVM, PS_GFX, the GPU PLL lock bit, the DVFS table and the
  voltage word. The MISC_ACG store that makes the PLL lock on the A8 was found on the J81 first
  ([../../a8x/MISCACG-PAGE5.md](../../a8x/MISCACG-PAGE5.md)).
- **[KC]** One shader compiler backend: iOS 12.4's compiler has one AGX1 backend in which the A8 (`g4p-b1`) and
  the A8X (`g4g-a1`) share the G4 scheduling model, so the A8 encoding findings in [SHADERS.md](SHADERS.md)
  should apply as they are.

## What differs

| | A8 (T7000) | A8X (T7001) | Evidence |
|---|---|---|---|
| BVNC | 3.10.4.5, 4 clusters | 7.5.8.3 (GXA6850 class), 8 clusters; revision word `0x00070500` | [HW-J81] |
| Chip-info record | `{2, 4, 0, 4}` | `{3, 2, 0, 8}`, two cluster groups | [KC] |
| Default parameter buffer | 96 MiB | 144 MiB | [KC] |
| Firmware | `METAFW_G4P g4p_b0`, no META core memory, image 0x24000 | `METAFW_G4G g4g_a0`, **with** core memory (0xc590 bytes at `0x80000080`), image 0x29000; INIT's core-memory size word is 0xc590 (A8: 0) | [KC] |
| SLC set-up | `SLC_CTRL_MISC` 32-bit `0x200001` | 64-bit, a scramble word in the high half and a different address-decode field | [KC] |
| Bridges | one table (33 stores) | two A8 tables back to back (66 stores), at `0xc1000` instead of `0x81000` | [KC] |
| DVFS | 3 + 3 states | 4 + 4 (adds 550 / 275 MHz) | [HW-J81] |
| Power domains | none needed beyond GFX | `dwi` must stay on, or the GPU rail request never reaches the PMIC | [HW-J81] |
| TA/3D records | A9 layout + 8 | one more u64 early and per-cluster arrays doubled (4 → 8), so the tails move | [KC] |
| Compute record | | one word differs (`W+0x20` = 0xff, or 0xf on a user flag) | [KC] |
| Display | MIPI DSI | eDP; no `disp0` node in the T7001 device tree yet | [KC] |

- **[KC]** The A8 loader rejects a firmware image with core memory, so the A8X needs the A9's core-memory path.
- **[KC]** One A8X-only builder writes register `0x8238` (0, then 1); for which job type is not known.
- **[KC]** Power-model coefficients and the maximum-power word differ (governor only).
- **[INF, from our code]** Our A8 identity check accepts only revision `0x00030a00`, so on an A8X it should refuse
  7.5.8.3 cleanly: Fender back to state 0 and `-ENODEV` from the probe. Not run on an A8X.

## A probe-first kit for the A8X

The plan for a J81/J82 kit is to go one stage at a time, with the unknown BVNC behind an experimental flag:
(1) power and ID; (2) the firmware to its alive event; (3) the render node; (4) one compute job. TA, 3D and the
display stay refused until their differences are derived. Because internal storage *writes* work on the A8X, the
payload disables internal storage outright, makes the PMIC NVMEM read-only, adds no NOR or NVRAM nodes and runs
under a 30 s watchdog.

Open questions only a J81 run answers: whether the ID is reached without the PLL1/PLL4 and memory-controller
stores; whether the G4G firmware comes alive with our INIT and PLATFORM; the 64-bit SLC value under our boot
stream; and the compute terminate word.
