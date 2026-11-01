# Device-side bring-up tools

Small static programs for the iPad, run from the Debian chroot
(`orchard exec -- chroot /run/sid /root/NAME ...`). Build with `build.sh`,
copy with `push.sh` after `mesa/setup-device.sh`. They poke physical
memory through `/dev/mem`: read before you write, and only write registers
whose meaning the bring-up guide (a10/bringup) documents.

| Tool | Use |
|---|---|
| `gpuperf [STATE]` | GPU performance state at Fender + 0x1000: print it, or request STATE (1-6 on T8010) and time the switch |
| `socperf [STATE]` | SoC/memory performance state at PMGR + 0x68000 (T8010): print or set the low nibble |
| `mmiord ADDR N` | N 32-bit registers (mapped, so device memory is read with 32-bit loads) |
| `memrd ADDR N` / `memwr ADDR VALUE` | RAM words (the firmware heap, init data) |
| `memdump ADDR SIZE OUT` | copy physical memory to a file |
| `membw` | CPU memset/memcpy bandwidth: tells a slow memory clock |
| `adtscan START END OUTDIR` | find the Apple device tree iBoot left in RAM (by its `perf-states` properties) and save 64 KiB around each copy; the live tree has the values the restore tree zeroes. Its output is Apple data: keep it out of the repository |

`perf-install.sh` puts Debian's `perf` into the chroot (it has no network);
`mesa/hypr-bench.sh profile` uses it.

`timeline.patch` and `timeline.py`: a kernel-side log of GPU job writes and
completions with timestamps, for finding where a frame waits (a10/bringup/performance.md). Bring-up only, not part of the driver: apply it in the
patch repository (`tools/patch-repo.sh`), build, and load the module with
`apple_timeline=1`; read `/sys/kernel/debug/apple_timeline` after a run.
