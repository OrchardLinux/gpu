# Power on the iPod touch 6: GPU idle and the USB charge grant

Tags as in [README.md](README.md#evidence-levels).

## GPU idle power

- **[KC]** The A8 idles its GPU at two levels, as the A9 does. **Level 1:** the firmware parks itself
  (Fender state 0) with no hysteresis whenever CONTROL `+0x28` is non-zero and nothing vetoes it (engine busy,
  ring or channel lists not empty, a firmware inhibit mask). **Level 2:** the host's idle timer (40 ms first,
  5 ms re-arm) checks that Fender is quiescent, stops it and powers the GPU off in PMGR; resume does not rebuild
  the firmware's RAM.
- **[KC]** CONTROL `+0x28` is iOS's `GPUIdlePoweroffState` (default 1; the boot-args `gpu_idle_poweroff=0` and
  `light-em-up=1` clear it). Setting it to 0 only changes accounting.
- **[HW]** Our driver sets CONTROL `+0x28` = 1, so the firmware parks between jobs. A geometry job then takes
  about 495 µs from doorbell to start when the core is awake and about 930 µs after a wake; 30-68 % of
  back-to-back jobs woke the core in the 100-frame test. **[INF]** Clearing it while the GPU is busy and setting
  it again before runtime suspend should save roughly 130-300 µs per frame; this is designed, not flown.
- **[HW]** The GPU is held at the lowest performance state (365 MHz) by two CONTROL words set to 100; iOS allows
  up to 300 (500 MHz). Runtime PM autosuspends after 1000 ms, which stops the firmware and powers PS_GFX off.
- **[KC]** Fender: `R1+0x1000` = 0x10 | state (poll bit 4), `R1+0x14` = 7 to wake, `R1+0x20000` the core power
  bit (bit 5).
- **[INF]** Linux runs with global automatic clock gating (MISC_ACG) off on any boot chain that does not set it.
  The A8 driver sets it because the GPU needs it; on the A9 the same `enableACG` exists, the GPU PLL locks without
  it, and setting it there is only an idle-power candidate (unchecked).

## The D2186 charge grant

Under GPU load the iPod drained its battery to 0 while plugged into a Mac.

- **[HW]** The kernel logged the host's grant (Apple's USB vendor request: 1000 mA extra, 1500 mA in suspend), but
  the USB input current stayed at 130-216 mA. The D2186 PMU driver was read-only and the N102 USB device node had
  no `usb-psy-name`, so the grant reached nothing.
- **[KC]** `AppleD2186PMUPowerSource`: the input current limit is register `0x4c0`, one byte, code = (mA − 70) / 10
  (500 mA = 0x2b, 1500 mA = 0x8f; 0 below 70 mA; at most 0xff, 2620 mA). Input suspend is register `0x10` bit 2
  (used only below 70 mA). The charge current is register `0x4c6`, mA / 30 in 6 bits. iOS trims it with the factory
  battery calibration, clamped to 80-120 %; Linux does not use the calibration (so the limit is good to about
  ±20 %) and does not write it.
- **Fix** (ported from the iPad 5 series): the USB gadget's grant goes through dwc2's `vbus_draw` to the input
  current limit of the supply the device tree names, and the charger caps and ramps it. Rules: 500 mA when the host
  reports nothing or 500 mA or less; a larger grant only between 5 and 40 °C and 3.2 and 4.35 V; iOS's ramp (100 mA
  held 100 ms, then 100 mA steps every 10 ms); every write read back; a 1 s guard restores a limit the PMIC changed;
  losing the input withdraws the grant; the boot value of `0x4c0` comes back on remove and shutdown. Linux writes
  only `0x4c0`. The N102 device tree caps it at 1500 mA. Attach and detach come from a 1 s poll (no PMU event line
  for this on N102).
- **State:** the series is written (PMU binding and driver, dwc2, the N102 device tree) on top of the N102 battery
  series ([orchard#202](https://github.com/OrchardLinux/orchard/pull/202), D2186 battery status). **[HW]** It runs
  on the N102 in the combined development kernel: with the grant applied the USB input rose to about 1 A (from
  130-216 mA) and the battery reports Charging under the GPU desktop. It is not yet a pull request. Above 40 °C the grant falls back to 500 mA, so drain under heavy GPU
  load can return there **[INF]**. The battery's current reads 0 while charging (open).
