# A10 (T8010) GPU: power, clocks and display

Part of the bring-up guide (README.md). Same entry format: what is true, evidence, code, how to verify, A9.

## Power and clocks

Three clocks decide how fast the GPU path runs: the GPU's own, the memory's
and the CPU's. On the T8010 the first two were stuck at their lowest
setting under Linux, and nothing failed: everything just ran 2-3x slow.
Check all three early on a new chip, before optimizing anything else.

**Concepts.** Apple SoCs change clock and voltage together in *performance
states* (DVFS). The tables (frequency, voltage per state) are per chip and
per device: iBoot fills them into the Apple device tree (ADT) at boot, and
the restore device tree in the IPSW has them zeroed. The live ADT stays in
RAM after m1n1 boots Linux, so `tools/device/adtscan` can find it (by its
`perf-states` properties). Such tables are Apple data: read them on the
device, never commit them.

### GPU performance state: Fender + 0x1000

- **Fact.** The register the driver writes to power the GPU on, Fender +
  0x1000, is also the GPU's performance state. The low four bits are the
  state: 0 is off, 1 to N are the steps of the `sgx` node's `perf-states`
  table, slowest to fastest (N = `perf-state-count` - 1; 6 on T8010).
  Writing `state | 0x10` requests a state; the low five bits read back the
  state once it is reached (about 70 us on T8010). The hardware sets the
  matching voltage itself: no other register is involved.
- **Evidence.** The GFX firmware's own setter (fw 0x16d40) writes exactly
  this and polls for the readback; iOS 10's unstripped kext has the same
  register as the "GPC" perf state (`G5::AGXMetaFender::
  enableGPCPerfStateOverride`). Measured: `vk-tri` with 512 multiply-adds
  per pixel over the full screen took 8.69 ms in state 1, 5.47 ms in state
  3, 3.70 ms in state 6, with identical pixels.
- **What went wrong.** The driver requested state 1 to power on, which is
  the slowest clock. The firmware would raise it itself only with its DVFS
  enabled (next item), which our init data leaves off.
- **Code.** `pvr_apple.c`: `pvr_apple_power_on()` requests
  `apple_perf_state` (module parameter, default 6) through
  `pvr_apple_request_power_state()`.
- **Verify on new hardware.** With the GPU powered, read the register
  (`tools/device/gpuperf`), request each state and time an ALU-bound render
  (`vk-tri` with `TRI_FS_SPV=fma512.spv`, `TRI_REPEAT=20`): the time should
  fall roughly with the frequency, and the pixels must not change.
- **A9:** likely the same mechanism: iOS 10's kext has per-generation
  variants of a "GPC perf state override" (G3, G4G, G4P, G5; which one is
  A9's is not established) that wait on bit 4 of + 0x1000. The state count
  and table differ. Check the A9 firmware's setter for the register it
  writes.

### The firmware's own DVFS (not used)

- **Fact.** The GFX firmware runs power, boost and performance controllers
  that pick the state from GPU utilization. It does so only when two init
  fields are set: P + 0x93c and P + 0x944 (copied at init into fw globals
  0x30438 and 0x3043c, which gate every call of the setter: fw 0x6a98,
  0x7774, 0x16d40 callers). The kext sets P + 0x93c from a feature flag
  (bit 1) and P + 0x944 from an accelerator method that also decides
  whether the IO-mapping table is filled. With both 0 the firmware only
  records "state 1" in its power struct (+0x38) and never touches the
  register.
- **To use it** the controller parameters must be filled too: the power
  struct (heap + 0x69000 in our layout, `HEAP_POWER_STATE`, 0x4318 bytes,
  pointed to by X + 0x301) and the per-state table in P (+0xa5c count,
  +0xa60 and +0xea0 per-state values in MHz). The kext's initialization is
  FUN_fffffff006012dbc in the iPadOS 17.7.11 kernelcache; iOS 10's
  `AGXFirmware::initPowerAndPerformanceData` (unstripped) names the
  device-tree properties each value comes from (`gpu-perf-*`, `gpu-pwr-*`).
  Writing these fields at runtime does nothing: they are read at init.
- **Status.** Not used: Linux scales the clock instead (next section).
- **A9:** unknown; the gate fields' offsets depend on the firmware build.

### Scaling the GPU clock: m1n1's OPP table and devfreq

- **Fact.** The GPU's clock is scaled by Linux, not by the firmware. m1n1
  fills the GPU's `operating-points-v2` table, which the device tree leaves
  empty, from the Apple device tree: one entry per powered state of the
  `sgx` node's `perf-states`, with `opp-hz`, `opp-microvolt` and the state
  number as `opp-level` (the convention of the CPU table in t8010.dtsi).
  The driver runs devfreq's `simple_ondemand` governor on it every 20 ms
  (above 40% busy: fastest; busy = time with jobs in flight) and requests
  the OPP's level at Fender + 0x1000. No Apple values are in the
  repository, and nothing is per chip: m1n1 does this for any GPU node
  whose table is empty (A7-A11), and leaves the GPU at its boot clock if
  the Apple device tree has no table.
- **Evidence.** TESTED on J71b: 378 MHz idle, 1008 MHz under load, 376
  changes in a benchmark and demo run; live blur 598 of 602 frames under
  20 ms (602 of 604 in another run), as with the clock fixed at the
  fastest state; `vk-suite` passes; no job timeouts.
- **Code.** m1n1: `boot/m1n1/patches/orchard/0011` (orchard),
  `kboot_gpu.c:dt_set_gpu_pstates()` (called for chips `dt_set_gpu()` does
  not know). DT: `gpu_opp` in t8010.dtsi and the `gpu` alias the bootloader
  looks for (t8010-j71b.dts). Driver: `pvr_apple.c`,
  `pvr_apple_opp_init()`, `pvr_apple_devfreq_start()`, the
  `pvr_apple_devfreq_*` callbacks; `apple_perf_state=N` fixes a state.
  `/sys/class/devfreq/201000000.gpu` shows the states, the current one and
  `trans_stat`.
- **Pitfall found on the way.** `pm_runtime_forbid()` in probe powers the
  device up on the spot, so `power_on()` runs before anything after it in
  `power_init()`. The OPP table was read after it, so the first load after
  boot asked for state 0 (off) and the firmware then started on a powered-
  down core: the iPad reset, without a log. Later loads in the same boot
  worked, which made it look like a timing problem. Found with checkpoints
  that print and sleep 150 ms each, so the last one reaches the Mac over
  `cat /proc/kmsg` before the reset.
- **Verify on new hardware.** Before loading the driver,
  `/proc/device-tree/opp-table-gpu/` must list one `oppNN` per state;
  after, `cur_freq` should drop when idle and `gpuperf` should read the
  matching state.
- **A9:** the m1n1 side should work unchanged if its `sgx` node has
  `perf-states` and `perf-state-count`; the driver side needs only its
  Fender register (see above).

### SoC and memory performance state: PMGR + 0x68000

- **Fact.** On T8010 the memory clock (MEM domain) and the SoC fabric (SOC
  domain) share one register: the low four bits of PMGR + 0x68000 take
  `table[soc][mem]` = {{0xd, 0xa}, {0xb, 0xc}} (read-modify-write), bit 31
  is set while a change is pending. Linux booted with 0xd (both low; the
  `mcc` node lists two memory frequencies). Nothing in Linux raised it.
- **Evidence.** iOS 10's unstripped `AppleT8010PMGR::setPerfState`.
  Measured with 0xc: CPU memset 5.2 -> 10.3 GB/s, memcpy 6.8 -> 13.6 GB/s,
  an empty full-screen GPU render 2.24 -> 1.32 ms (store bandwidth).
- **Symptom to look for.** The GPU's store bandwidth equal to the CPU's
  memset bandwidth, both well below what the chip should do
  (`tools/device/membw`).
- **Code.** `drivers/soc/apple/apple-pmgr-misc` T8010 variant
  (kernel/patches/drivers/soc-apple/0011-0012, DT node in t8010/0012,
  `CONFIG_APPLE_PMGR_MISC`): sets both high at boot.
- **A9:** check the A9 PMGR kext's `setPerfState` (look for an S8000 one in the iOS 10 kexts
  (github.com/userlandkernel/ios-unstripped-kexts has unstripped iOS 10
  kexts); the register and table likely differ.

### CPU

Linux's cpufreq (schedutil) already runs the CPU up to its top frequency on
T8010; nothing to do there. Check `scaling_cur_freq` under load anyway.

## Display

- **Fact.** The ADBE display pipe (drivers/gpu/drm/adbe, written for the A9's display pipe and shared with the A10)
  gives real 60 Hz vblank events and scans out the GPU's buffers directly
  (no copy). A new framebuffer goes through the pipe's parameter FIFO and
  is applied at the next frame boundary; the "packet applied" status bit
  completes the page flip. Before it, simpledrm had no vblank and
  compositors copied every frame.
- **Consequences for the GPU side.** Frame pacing is real: a frame that
  misses its boundary waits a whole 16.7 ms (so frame times cluster at
  16.7 and 33 ms). With ADBE, card0 is the GPU and the display is the next
  card (`kms-grab` picks the first KMS-capable card).
- **"Ghost copies" of a moving window** on the panel were the 60 Hz LCD's
  persistence, not our frames (screen grabs during moves are clean): fast
  animations that jump 150-250 px per frame look like several windows.
  The demo slows window moves for that reason.
