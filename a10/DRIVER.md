# A10 kernel driver plan

Goal: fully accelerated Hyprland on the A10. The kernel side is a DRM driver
exposing the mainline **powervr UAPI** (`include/uapi/drm/pvr_drm.h`), so that
Mesa's PowerVR Vulkan driver (fork with a G9P shader backend) and Zink can run
on it. Background: [REFERENCE.md](REFERENCE.md); the hardware protocol it
implements: [COMPUTE.md](COMPUTE.md), [FENDER.md](FENDER.md),
[RENDER.md](RENDER.md).

## Shape: an Apple firmware variant of `drivers/gpu/drm/imagination`

The A10's fixed-function hardware is Rogue: PDS, CDM, MMU page tables and
`RGX_CR_*` registers. Its firmware is Apple's: RTKit on an A7 IOP. The
`imagination` driver splits along that line:

| Reused as-is (protocol-free) | Apple variant (new, next to the IMG files) |
|---|---|
| `pvr_drv.c` ioctls, `pvr_gem.c`, `pvr_vm.c` (`drm_gpuvm`), `pvr_mmu.c` (Rogue PC/PD/PT), device info, `pvr_sync.c` | Firmware boot (RTKit + A7IOP mailbox), Fender power, firmware heap and init data (X/P/Q/T/U/V), rings, job submission (work items, microsequences, CDM records), completion via stamps and the event ring |

Selected by `compatible = "apple,t8010-gpu"`. The device data carries:
- **Apple `pwr_ops`:** power on = boot the GFX IOP and request Fender state 1.
  RGX registers are only accessed after that. Power off = Fender state 0.
- **Firmware path:** `apple/gfx-t8010.bin` is a raw image, not an IMG container;
  there is no IMG header validation.
- **Static device info:** the A10 has no IMG firmware header. Identity comes
  from CORE_ID `0x011b0602` (legacy format) and features from captures.

Mesa sees a normal `powervr` device. Job submission translates the UAPI's
compute (later render) jobs into the Apple work items COMPUTE.md documents.

## Dependencies already in the tree

- `drivers/soc/apple/mailbox.c`: `apple,t8010-a7iop-mailbox` (in the scratch
  tree; becomes a patch in `kernel/patches/drivers/soc-apple/`).
- mainline `apple-rtkit` (protocol v12 supported).
- DT: `gpu@201000000` and `gpu_mbox` in `t8010.dtsi`.

## Golden reference

`tools/golden.sh OUT 46` replays the baseline-46 bring-up on the host and
writes the exact firmware window and scratch images, the Fender write sequence
and the mailbox messages. The driver's layout code is compared with these
byte for byte (allowing for its own physical addresses) before any device run.

## Milestones

1. **Firmware up inside powervr:** probe, window, RTKit boot, Fender power,
   CORE_ID read, init data accepted (ready flag), `/dev/dri/renderD128`
   registered, `DEV_QUERY` answers. No jobs.
2. **Kernel-internal compute self-test:** experiment 46 (terminate-only), then
   68 (`store_marker` writes 0x1357) issued by the driver, with completion
   through the event ring and a dma-fence.
3. **UAPI compute jobs:** `CREATE_BO`, `VM_MAP`, `CREATE_CONTEXT`,
   `SUBMIT_JOBS` (compute) from a small userspace test reproducing 68.
4. **Render:** decode RENDER.md's VDM/PPP/TA/3D data, add render jobs, draw
   the triangle.
5. **Mesa fork:** pvr + G9P backend, Vulkan, then Zink, EGL/GLES, Hyprland.

## Status

**Milestone 2 reached on hardware (2026-10-30, `out/resume/driver2-*.log`):**
- The firmware uses powervr's own GPU page tables: `pvr_mmu` 16 KiB pages,
  with the `kernel_vm_ctx` root in the context-0 root array.
- The command stream, PDS/USC code and output are GEM objects mapped with
  `pvr_vm_map`.
- `apple_selftest=2` runs experiment 68 from the driver, and the output
  buffer reads `0x1357`.
- `rmmod powervr` (Fender state 0, RTKit shutdown) followed by a reload works.

**Milestone 3, groundwork, on hardware (2026-10-30, `out/resume/driver3-*.log`).**
Built from the patch layers on hardware 619b916.
- Repeated jobs work (`apple_selftest=3`). Each job gets its own slot, a
  command-ring entry and a work-ring descriptor; the producer index and the
  stamp carry the sequence number.
- GPU VM switching works (`apple_selftest=4`). The driver reprograms GPU
  context 0 (RGX `MMU_CBASE_MAPPING`) and bumps its generation, so the firmware
  invalidates the TLB. A store job in a second VM writes only that VM's page.
- `pvr_vm.c` changes: on Apple, userspace VM contexts no longer allocate an
  IMG firmware memory context, and the userspace heap check uses the
  context's own flag.

Firmware facts used:
- The init routine (fw 0x18352) loads `root[0]` plus each `root[i]` flagged
  in the bitmask at T+0x7e4.
- 0x18530 invalidates context `k` (RGX+0xe138) when `gen[k]` differs from
  the acknowledged copy.
- Host control command type 5 also invalidates the context named at `+4`.

Next: wire powervr's `CREATE_CONTEXT`/`SUBMIT_JOBS` (compute) onto this.
Apple contexts and queues replace the IMG ones, and `run_job` translates
`rogue_fwif_cmd_compute` (stream base, context-state base). Then a userspace
test.

**Milestone 3 reached on hardware (2026-10-30, `out/resume/driver4-*.log`):**
`pvr-compute-test` (`tools/pvr-compute-test.c`, static arm64, also
`/usr/bin/pvr-compute-test` in the payload) runs experiment 68 through the
powervr UAPI only. It creates a VM context, five BOs in powervr's heaps, a
compute context and `SUBMIT_JOBS`; out[0] reads 0x1357 0.5 ms after
submission. What makes this work:
- **Code bases:** the firmware takes the PDS/USC code bases from P+0x10/+0x18,
  which are now powervr's heap bases (0xDA00000000 / 0xE000000000). Verified
  with `apple_selftest=4`.
- **`pvr_apple_queue.c`:** a `drm_sched` backend whose `run_job` translates
  `rogue_fwif_cmd_compute` (stream base, context-state base) into an Apple job.
  Fences are signalled by a 1 ms stamp poller.
- **Context, job and VM paths:** Apple compute contexts have no IMG FW objects,
  and the job lock skips the missing `fw_obj`. Every userspace VM gets the
  driver's reserved data page at 0x200000 (`pvr_vm_map_reserved`).
- **MMU flushes:** on Apple, powervr's MMU flushes bump context 0's generation
  (lock-free; a mutex there wedged the device once).

The command-stream layout follows the device's feature set, with no
extension headers. The sync-op array stride must be set even when empty.

Still open: completion without polling (the firmware sends no message on
completion in the tested setup); render jobs; firmware power management.

**Render design (2026-10-30, from RENDER.md).** Same shape as compute: a
translation in `run_job` from powervr's UAPI to Apple's firmware commands.

- *Inputs Mesa already provides:* geometry job (`rogue_fwif_cmd_geom`
  regs: VDM stream base, PPP/TE/TPU control, VDM context tasks), fragment job
  (`rogue_fwif_cmd_3d_regs`: ISP background depth/vals/AA/ctl, PDS background
  programs, PBE words, ZLS, …), and the HWRT dataset and free lists
  (`CREATE_HWRT_DATASET`: `vheap_table_dev_addr`,
  `macrotile_array_dev_addr`, `pm_mlist_dev_addr`, region headers, RTC, TPC).
- *Apple side:* one render record per pass (TA part at +0, 3D part at
  +0x120; the 64-bit/32-bit register blocks whose slot → RGX-register map is
  in RENDER.md), a TA context buffer whose +0xa0/+0xa8/+0xb0 carry
  `PM_MLIST0_BASE`/`PM_MTILE_ARRAY`/`PM_VHEAP_TABLE`, unit-state arrays and
  stamps as for compute, and microsequences built like the kext's: TA
  `5 (0x1a words) / 4 / 6`, 3D `7 (0x1d) / 8 (0x13)`.
- *Open:* names of the remaining slots (0x408–0x470, 0xc00–0xd20 for TA;
  0xf18–0xfd8 and 0x618–0x6d0 for 3D), to be matched by value against what
  Mesa computes for the captured triangle; the remaining microsequence
  words; free-list / PM page handling.

**Fixed (2026-10-30, boot 8): `rmmod powervr` hung after userspace jobs.**
Found over the new USB SSH channel (`orchard exec -- cat /proc/kmsg`, sysrq
`w`). The cause was a scheduler self-deadlock, not unload. When a process exits
before its job's fence signals, the last job reference drops in drm_sched's
free_job work. The job releases the context, the context destroys its queue,
and `drm_sched_fini()` waits for that same free_job work (`cancel_work_sync`).
`rmmod` then blocked in `destroy_workqueue(sched_wq)`. Upstream's IMG path has
the same structure. Fix: `pvr_context_release()` unlinks the context and
queues the rest (queue teardown, frees) on `sched_wq`, which
`pvr_queue_device_fini()` drains. Verified on hardware (boot 9,
`out/resume/driver5-unload.log`): jobs, `rmmod`, reload, jobs, twice.
A second race showed as `WARN_ON(!xa_empty(&job_ids))` when `rmmod` ran right
after the last job: its fence or free_job was still pending. On Apple,
`pvr_remove()` now calls `pvr_apple_quiesce()` first: wait for the last job,
signal fences, flush `sched_wq` (free_job, then context releases). Verified
with 3 × (4 jobs, immediate `rmmod`, reload), no warnings
(`out/resume/driver6-quiesce.log`).

**Milestone 1 reached on hardware (2026-10-30, first run, `out/resume/driver1.log`):**
`modprobe powervr exp_hw_support=1 apple_selftest=1` boots the GFX firmware
(RTKit v12) and powers the core (Fender state 1). The firmware accepts the
init data, and the in-driver self-test completes a terminate-only compute job
(stamp 1). powervr registers as DRM minor 1 with `/dev/dri/renderD128`. It is
built from:
- `pvr_apple_layout.c`: matches the baseline-46 golden image byte for byte
  (`tools/layout-test/run.sh`).
- `pvr_apple.c`: RTKit boot, Fender power, init, bring-up self-test.
- Wiring in `pvr_device.c`, `pvr_drv.c`, `pvr_power.c`, Kconfig
  (`DRM_POWERVR_APPLE`, enabled in `kernel/configs/apple-16k/config`) and the Makefile.

The patch is saved as `kernel/0002-drm-imagination-apple-t8010.patch`. The
platform kernel carries `powervr.ko` (`orchard build examples/gpu-001` stages
it with the payload).

Device run, once authorized: boot `gpu-001`, stage `tools/driver-test.sh`, then
`SELFTEST=1 sh /run/driver-test.sh` (loads `powervr exp_hw_support=1
apple_selftest=1`). Do not load `apple_gpu_iop.ko` in the same boot.

Kernel changes are developed in the shared kernel work tree
(`~/.cache/orchard/kernel-work/apple-16k-PIN/source`, see `kernel/build`;
`tools/patch-repo.sh` edits the GPU layers outside it) and exported as patch
layers under `kernel/patches/`, written
in upstream style (no bring-up scaffolding in the final series).
