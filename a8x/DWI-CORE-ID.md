# J81: the core-ID read returns on Linux once the PMGR `dwi` power state is on (21 Nov 2026)

Field report on one iPad Air 2 Wi-Fi (`iPad5,3`, J81, A8X/T7001, Imagination GXA6850). It is a measurement, not a
driver, a device-profile change or a procedure. J81's `gpu = "missing"` in Orchard's `devices/j81/device.toml` is
unchanged. **No firmware has been loaded, no job submitted and no frame rendered; the only GPU register read so far is
the core ID.**

Labels: **E** observed on the device, **I** inference, **U** unknown.

## Result in one paragraph

On Linux the first core-ID read, `0x201000020`, hung the bus in every earlier run, even after the PMGR, bridge, GPC and
MiscACG steps matched iPadOS. With the PMGR `dwi` power state (`0x20e020120`) switched from `0x200` (off) to `0xff` (on)
before the GFX activation, the read returned `0x00070500`, the value iPadOS reads (E). This held on two of two runs on
separate fresh boots; the same recipe with the core load compiled out returned normally, and every run without `dwi`
on hung (E). LLB and iPadOS keep `dwi` on; Linux switches it off about 0.7 s into boot together with 19 other domains
that the boot chain hands over switched on (E). The earlier note [J81 DWI voltage transport](https://github.com/mattonik/ipad-nixos/blob/main/research/2026-11-11-j81-dwi-voltage-transport.md)
had flagged the domain; its tests predate the MiscACG store (19 Nov) and so could not discriminate.

## Mechanism (E unless marked)

`dwi` carries the SoC voltage manager's requests to the PMIC (Dialog D2207, I2C bus 0, address `0x3c`). With `dwi` off the
GFX request is made (voltage word `0x20e02300c` goes to `0x164`) but the PMIC does not act on it.

| PMIC buck row (read-only I2C) | before the batch | after the batch | +10 s |
| --- | --- | --- | --- |
| `0x0128` | `00 00 40 00 40 e0 0f 31` | `64 00 64 00 40 e0 0f 31` | `64 00 64 00 40 e0 0f 31` |
| `0x0100`, `0x0150`, `0x01c8` | unchanged | unchanged (row `0100` moved `6d`->`88`->`6d` in one run) | unchanged |

With `dwi` off, row `0x0128` stayed `00 00 40 00` in a separate snapshot campaign. **I:** buck 1 is the GPU rail.
**U:** whether the rail reaches its target voltage; `64/64` is a register value, not a measurement.

## Recipe (one shot per boot, each store checked by readback)

1. RAM-root Linux 7.3.0-rc1 (Hoolock `6831bc7`) started from checkm8, PongoOS and m1n1; `dwi` is already off.
2. PLL1 +8, PLL4 +8, MCC bank bit 31 on five words, MiscACG `0x20e032000 = 1`, SoC TVM enable: the Apple order from the
   [19 Nov report](MISCACG-PAGE5.md) and the notes it links. Tools: `boot/pmgr-pll-set.c`, `pmgr-mcc-set.c`,
   `pmgr-miscacg-set.c`, `pmgr-tvm-set.c` in [mattonik/ipad-nixos](https://github.com/mattonik/ipad-nixos/tree/main/boot).
3. **One store of target 15 to `0x20e020120`** ([`boot/pmgr-dwi-on.c`](https://github.com/mattonik/ipad-nixos/blob/main/boot/pmgr-dwi-on.c)),
   only if the word reads exactly `0x200`; readback must be `0xff`.
4. One GFX power activation (a single `pm_runtime_get_sync`, no off/on cycle).
5. One in-kernel batch with interrupts masked (`kernel/gpc-page5-kpoll-*`): the 66 bridge stores, GPC `+0x10000 =
   0xffff0000`, `+0 = 0x40000000`, `+0x1000 = 0x11`, poll for state 1, page-5 `+4` sample (bit 30 set), core-ID read.
   Mappings are non-posted (`ioremap_np`). Measured: bridge stores about 48 us, core read 458-500 ns.

## Runs on 21 November (all fresh boots)

| Run | Result |
| --- | --- |
| single GFX activation instead of off/on | core read still hangs |
| compressed irq-off batch, non-posted mappings | still hangs |
| same, core load compiled out | batch returns: the stall is the core load itself |
| bridge words read back before/after GPC | 66/66 equal the plan |
| `dwi` off, request made | PS stays `0x200`; PMIC row stays `00/40` |
| `dwi` on, no core read | batch returns; row `0x0128` -> `64/64`, held 10 s |
| **`dwi` on + core read, run 1** | **`0x00070500`**, no hang |
| **`dwi` on + core read, run 2** | **`0x00070500`**, no hang |

Per-run notes: [`research/2026-11-21-j81-*-result.md`](https://github.com/mattonik/ipad-nixos/tree/main/research);
summary: [2026-11-21-j81-dwi-gpu-core-id-summary.md](https://github.com/mattonik/ipad-nixos/blob/main/research/2026-11-21-j81-dwi-gpu-core-id-summary.md).

## Limits

One device, two successful runs with one module and one runner. Not shown: which of the earlier PMGR stores are still
required with `dwi` on; whether keeping `dwi` on from early boot behaves like the post-boot store; any other GPU register.

## If your core-ID read hangs on another A8/A8X/A9

Check the genpd debugfs entry for `dwi` and the PMGR word at `+0x20120` after boot. A domain LLB left on and Linux turned
off before your GFX activation is the lead. The fix being tested here is `apple,always-on` on `ps_dwi` in the board DT
(the PMGR driver already honours it); Orchard's T7000-handheld trees carry an equivalent through the `dwi_bl` node.
