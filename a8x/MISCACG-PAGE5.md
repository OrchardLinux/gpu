# J81: one MiscACG store makes page-5 bit 30 rise on Linux (19 Nov 2026)

Field report on one iPad Air 2 Wi-Fi (`iPad5,3`, J81, A8X/T7001). It is a measurement, not a driver, a device-profile
change or a procedure. J81's `gpu = "missing"` in Orchard's `devices/j81/device.toml` is unchanged, and **no GPU register
beyond power, bridge, GPC and PMGR words has answered on Linux yet**: the first core-ID read still hangs (see
[What did not work](#what-did-not-work)).

## Result in one paragraph

On iPadOS 15.8.5 (`19H394`), PMGR region 0 offset `0x32000` (physical `0x20e032000`) reads `1` before the GPC
request, and page 5 `+0x4` (`0x20e005004`) then rises to `0x40000000`. Under Linux the same word reads `0`, and page 5
stays `0`. Storing `1` to `0x20e032000` once, after the GFX power cycle and the bridge stores and before the GPC
request, makes page 5 `+0x4` read `0x40000000` after the GPC poll, as on iPadOS. This reproduced on three of three
fresh boots with the store. The control without the store (one boot) read `0` at the same two sample points.

## What the register is

Static analysis of the iPadOS 15.8.5 kernel (`19H394`) shows `ApplePMGR::enableACG(bool)` operating on the register group
the driver itself names `kRegGroupMiscACG`: it reads the word at PMGR region 0 `+0x32000`, computes `(old & ~1) | enable`,
and stores it, with no poll or read-back on the traced tail. During `ApplePMGR::start()` it is called with `true`
before the voltage-manager enable. The call happens in the `start()` startup path, before any GPU driver runs. Which clocks the group gates is **not** established here.

## iPadOS observations (one device, kernel probes, `19H394`)

| Point | `0x20e032000` | Source |
| --- | --- | --- |
| `ApplePMGR::start()` entry | `0` | read-only entry control, `r9` field |
| Immediately after `enableACG(true)` returned | `1` | two boots |
| End of `ApplePMGR::start()`, before GFX power-on, bridge stores and GPC writes | `1` | one boot |

In that last boot the same probe then ran the GFX power-on, the 66 bridge stores and the GPC request, with these
records (`J81_BOOT`, one boot, logged by the kernel's `AGXk` logger):

| Record | Value |
| --- | --- |
| pre-GPC GFX PS `0x20e020320` | `0x00000300` (off) |
| pre-GPC page 5 `+0x4` | `0x00000000` |
| pre-GPC MiscACG `0x20e032000` | `0x00000001` |
| GPC poll | ended after `0x3909` counter ticks (24 MHz, about 606 us) |
| page 5 `+0x4`, three samples after GPC | `0x40000000`, `0x40000000`, `0x40000000` |
| perf `0x20e01c200` | `0x80000000` before, `0x80110100` after |
| `0x20e02300c` | `0x164` after (the same word read `0` before GPC in the earlier boot below) |
| core ID `0x201000020` | `0x00070500` |

An earlier boot of the earlier probe (without the MiscACG field) recorded the same pre/post pattern and core ID, so the
page-5 rise and the core answer are not specific to the one boot above.

## Linux experiment (same device, observer kernel Linux 7.3.0-rc1, RAM boot)

Sequence on every boot: GFX power cycle (get, put, get) so the GFX PS word reads `0x3ff`; snapshot A; the 66 bridge
stores; snapshot B; **(write boots only)** guarded MiscACG store; snapshot B2; the GPC request and a paired page-5
read in the kernel; snapshot C. Snapshots read only the PMGR offsets `0x20320 0x32000 0x1008 0x4008 0x1c200 0x2300c 0x5004`.
The GPC request is the same three stores iPadOS performs (`+0x10000 <- 0xffff0000`, `+0 <- 0x40000000`,
`+0x1000 <- 0x11`), polled until `(raw & 0x1f) == 1`.

The MiscACG store is guarded: it maps `/dev/mem` at `0x20e032000`, reads the word, and stores `1` **only if it
reads exactly `0`**, then reads it back. It touches no other address.

| | MiscACG at A / B | after store (B2) | page 5 `+0x4` after GPC (first, later sample) | perf `0x1c200`, `0x2300c` after GPC |
| --- | --- | --- | --- | --- |
| control, no store (1 boot) | `0` / `0` | n/a | `0x00000000`, `0x00000000` | `0x80110100`, `0x164` |
| store, boot 1 | `0` / `0` | `1` | `0x40000000`, `0x40000000` | `0x80110100`, `0x164` |
| store, boot 2 | `0` / `0` | `1` | `0x40000000`, `0x40000000` | `0x80110100`, `0x164` |
| store, boot 3 | `0` / `0` | `1` | `0x40000000`, `0x40000000` | `0x80110100`, `0x164` |

In all four boots the GPC poll ended after 11 reads (about 290 to 298 us from the first store to the successful poll)
and the first page-5 sample was taken less than 1 us after the poll, the later one about 100 us after it. The words
at `0x1008` and `0x4008` were identical in every snapshot of every boot (`0x80480348`, `0x88480348`). The perf and
`0x2300c` transitions happen with or without the store; **only page 5 differs**.

One variable (MiscACG bit 0 before the GPC request) therefore flips the page-5 outcome on this device. It is a
correlation in a fixed sequence on one device; this experiment does not show that MiscACG drives bit 30 through any
particular clock, nor that the store is sufficient for anything beyond the word.

## What did not work

With MiscACG at `1`, page 5 at `0x40000000`, GPC state `1` and GPC control `0x40000000` (all read immediately before),
the first read of the core window (`0x201000020`) **still hung**: the host acknowledged the pre-read checkpoint, no
result came back, and the hardware watchdog reset the iPad about 20 s later (one boot). That read was issued seconds after
the GPC poll; iPadOS issues it tens of microseconds after. Whether the delay matters, or another iPadOS startup step is
still missing, is not established. A same-boot timed variant is prepared but has not been run.

## Boundaries

- One iPad, one kernel (`19H394`), one Linux image. Boot-to-boot repeats are three store boots and one control boot.
- The iPadOS pre-GPC MiscACG value comes from one boot of an instrumented kernel; the entry and post-enable values
  from separate boots. The sample point is before GFX power-on, not between GPC and the page-5 rise.
- The Linux store was made through `/dev/mem` (needs `CONFIG_STRICT_DEVMEM` off); a driver would do it through the
  PMGR region the kernel already maps.
- J96 (A8/T7000) is the same family; whether `+0x32000` is MiscACG there and behaves the same is untested.
- No firmware, kernelcaches, ADT dumps, captures or device identifiers are included.

## Source notes

The raw logs and the instrumented iPadOS modules stay private. The measurement work is done in
[mattonik/ipad-nixos](https://github.com/mattonik/ipad-nixos); its `research/` directory is where the longer notes live.
