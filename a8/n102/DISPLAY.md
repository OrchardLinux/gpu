# A8 display: adbe and display-DART scanout

On the A8 Linux first drew through the bootloader's framebuffer (simpledrm). With the A9/A10 display-pipe driver
(`adbe`) ported to the T7000, the compositor's GPU buffers are scanned out directly. Tags as in
[README.md](README.md#evidence-levels).

## The hardware

- **[KC]** The A8's display pipe is the A9's: iOS 12 drives it with the same `AppleH7DisplayPipe` class (inside a
  different ADBE kext wrapper), with identical FIFO, parameter-store, busy, layer, CRC, blend and format registers
  and the same start-up error mask.
- **[KC]** One difference: the A8 kext never checks the SPDS version. It reads the boot-arg and ignores it and never
  touches registers `0x1010`/`0x1014`, where the A9 path reads `0x1014` and panics unless it is 0x13. The Linux
  driver therefore skips that check on the A8.
- **[KC]** `disp0` is `adbe0,t7000`; the pipe window is at `0x206200000` (1 MiB), with IRQs 103 and 108-111.
- **[KC]** `dart-disp0`: the DART at `0x206304000` with its SMMU at `0x206300000`, IRQs 106/107, 4 KiB pages. It uses
  the T7000 DART support (error reflector written first, protection bits kept) that the PCIe Wi-Fi on the N102
  already proved.
- **[KC]** Panel links: the N102, N61 and N56 use MIPI DSI (2 lanes). The iPad mini 4 (J96/J97) and the A8X iPad Air 2
  (J81) use eDP through a `displayport,t7000` window at `0x206700000` (4 lanes, the panel supply on a PMU GPIO). The
  other per-board `disp0` and DART values are the N102's.

## What the driver does

- The orchard series (#204) adds a `apple,t7000-display-pipe` binding, per-SoC match data with a MIPI DSI
  connector, an optional `dp` window with an eDP connector for the iPad mini 4, a per-SoC panel-size table, and the
  `disp0` and `dart-disp0` device-tree nodes for the N102, N61, N56 and J96/J97. `dart-disp0` stays disabled in the
  device tree; the driver enables it after mapping the live scanout buffer the bootloader left.
- **Self-check:** before trusting the DART the driver scans out a test pattern and compares CRCs: the pattern's CRC
  must equal the translated (through the DART) CRC, and a permuted mapping must give a different one. It needs one
  physically contiguous pattern buffer (about 2.9 MiB on the N102, 12 MiB on the iPad mini 4). If that fails the
  driver stays in DART bypass, which does not hang, but then scattered GPU buffers cannot be scanned out **[INF]**.
- The driver holds the framebuffers the compositor imported until the display no longer reads them, so labwc can
  scan out the GPU's dma-bufs directly.

## Results

- **[HW] N102 (iPod touch 6):** the self-check passes (pattern CRC = translated CRC, permuted CRC differs, no
  faults); scanout runs through the display DART; DRM `adbe` binds built-in and as a module; labwc scans out imported
  GPU buffers directly; the connector is `DSI-1` at 640x1136@60 (it was `Unknown-1` under simpledrm); 30 page flips
  at 16.6 ms.
- **[HW] N61 (iPhone 6),** tester kit 4, a tester's device
  ([report](https://github.com/OrchardLinux/orchard/pull/196#issuecomment-7096670158)): 9 of 9 display checks pass, twice: `DSI-1` 750x1334@60,
  scanout through the display DART, pattern CRC = translated CRC, 30 flips at 16.6 ms, a GPU buffer imported, no
  kernel warnings. Its boot framebuffer has a 3008-byte stride (750 × 4 + 8 bytes of padding), which the driver
  handles. This is the first MIPI board other than the N102: adbe and the display DART work unchanged.
- **[INF] iPad mini 4 (J96/J97, eDP):** from a static review, adbe never maps or drives the eDP transmitter unless a
  panel-supply GPIO property is present (none is in the shipped device trees), so it should pass with the panel lit
  as iBoot left it. Not yet run.

## Open

- No panel power-off in system sleep on the A8 (no DSI panel-off path yet).
- The A8's DisplayPort transmitter layout has not been compared with the A9's; eDP link retraining after sleep uses
  the A9's offsets.
- labwc's software cursor blocks direct scanout.
