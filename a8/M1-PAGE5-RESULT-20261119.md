# M1 result: page-5 +0x4 at AGX power-on, J96 (19 Nov 2026)

iPad mini 4 (J96, iPad5,1, A8/T7000, iPadOS 15.8.3 `19H386`). The
full-state KPF probe (branch `a8-bringup`, `tools/a8/kpf/`, built by the
`J96 KPF page-5 probe` CI workflow, run `44383495723`, artifact SHA-256
`23f7fe07e9c9e3da40a1e5bdec9de2fe65cbf4cde62ea5c205880d84b2478028`) ran on
the device and produced the intended planned panic.

Panic report: `panic-full-2026-11-19-023138.000.ips`
(collected to `~/Projects/j96-pongo-probe-20261030/ios-reports-197G3LAX/`).

`far == 0xbeef` → the dump was captured (not `0xdead`, which would mean the
capture hook never ran).

## Answer to M1

**Page 5 `+0x04 = 0x40000000` → bit 30 is SET** at the AGX post-GPC-poll
point. This is the same boundary the J81 (A8X) series pinned, now confirmed on
J96. Under Linux the same word reads `0` at idle and the GFX PLL never starts
(first RGX read freezes the SoC) — bit 30 is the missing enable.

## Register → value map (panic `x0..x28`)

`x10..x25` = PMGR clock page 5 `+0x5000..+0x503c`; `x26` = `+0x1c200`;
`x27` = `+0x1c300`; `x28` = `+0x2300c`. (`far` = `0xbeef`/`0xdead` magic.)

| Reg | PMGR offset | iPadOS (post-poll) | Linux (idle snapshot) | Δ |
|---|---|---|---|---|
| x10 | +0x5000 | 0x00001010 | 0x00001010 | — |
| **x11** | **+0x5004** | **0x40000000** | **0x00000000** | **bit 30 SET** |
| x12 | +0x5008 | 0x81480348 | 0x81480348 | — |
| x13 | +0x500c | 0x081c8385 | 0x081c8385 | — |
| x14 | +0x5010 | 0x01ac0418 | 0x01ac0418 | — |
| x15 | +0x5014 | 0x02187000 | 0x02187000 | — |
| x16 | +0x5018 | 0x04000040 | 0x00000001 | Δ |
| x17 | +0x501c | 0xb8040000 | 0x04040000 | Δ |
| x18 | +0x5020 | 0x0b931000* | 0x14790c38 | Δ* |
| x19 | +0x5024 | 0x000004b6 | 0x000004b6 | — |
| x20..x25 | +0x5028..3c | 0 | 0 | — |
| x26 | +0x1c200 | 0x80110100 | 0x80000000 | Δ |
| x27 | +0x1c300 | 0x40000001 | 0x00000000 | Δ |
| x28 | +0x2300c | 0x0000015f | 0x00000000 | Δ |

\* `x18` is the Darwin platform register; the panic dump shows
`0xfffffff00b931000` (high bits not zeroed). The meaningful 32-bit value is
`0x0b931000`. Re-check this word on a second run / use a non-reserved register
if it matters.

## The power-on sequence (from the hook site's own disassembly)

The read hook sits at `0x6695a44`, just after AGXG4P's GPC busy-poll:

```
0x6695a2c  mov  w8, #0x40000000
0x6695a30  str  w8, [x0]           // Fender: write 0x40000000 (power-on)
0x6695a34  mov  w8, #0x11
0x6695a38  str  w8, [x0, #0x1000]  // Fender +0x1000 = 0x11 (GPC state req)
0x6695a3c  ldr  w8, [x0, #0x1000]  // read back
0x6695a40  tbnz w8, #4, -0xc       // poll until bit 4 clears
0x6695a44  mov  w0, #0xa           // <- hook site (post-poll)
```

So the driver writes `0x40000000` to Fender, requests GPC state `0x11`, polls,
and only then is page-5 `+0x04` bit 30 set. This matches the A10 lead
(`a10/FENDER.md` §18.2).

## Where this leaves M1

- **Confirmed:** the working iPadOS value of page-5 `+0x04` at AGX power-on is
  `0x40000000`. Linux never reaches it because its power-on path does not leave
  bit 30 set before the first RGX read.
- **Next (see README "Next phase"):** extend the dump to the full state (all
  six clock pages, ps registers `0x20000–0x21010`, LLB pages, DWI) and/or
  trace the Linux GPU power-on path against the sequence above to find which
  write is missing or mis-ordered.

## Rules (unchanged)

Read-only on PMGR clocks; no guessed writes to page 5/perf/voltage; no RGX
access under Linux while the clock question is open. Apple data stays private.
