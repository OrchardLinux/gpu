# Tools

Small, self-contained scripts from our A9 (G5P) work that are useful to anyone bringing up Linux on an older
Apple PowerVR GPU. They are cleaned-up copies of what we actually ran, with paths and chip names turned
into arguments. Licence: **MIT** ([LICENSE.md](LICENSE.md)).

**None of these tools' outputs are in this repository, and yours should not be in any public repository
either.** The firmware extractor and the Metal compiler probe produce Apple code and Apple-compiler output:
study them locally and write up what you learn in your own words.

| Tool | Runs on | What it is for |
|---|---|---|
| [firmware/extract-kext-firmware.py](firmware/extract-kext-firmware.py) | any host, Python 3 stdlib | Split the AGX kexts and the GPU firmware out of a prelinked kernelcache; decode the firmware's META LDR records |
| [firmware/build-metag-binutils.sh](firmware/build-metag-binutils.sh) | Linux, or Docker | Build a META-capable `objdump` (binutils 2.30, the last release with metag) |
| [firmware/disassemble-ldr.py](firmware/disassemble-ldr.py) | any host (+ objdump) | Rebuild the firmware's memory regions from the LDR records and disassemble them |
| [firmware/minim.py](firmware/minim.py) | any host (+ objdump) | Expand MINIM (META's compressed encodings) to standard META so `objdump` can read it; provisional. Tests: [firmware/test_minim.py](firmware/test_minim.py) |
| [census/glm-census.sh](census/glm-census.sh) | the Linux device | glmark2 per scene: fps, GPU busy %, GPU ms/frame, jobs/frame, in the compositor's real environment |
| [census/gpu-stats.py](census/gpu-stats.py) | anywhere | Parse our driver's `g5p_gpu_stats` debugfs snapshot into GPU ms and busy % |
| [metal/offline-compile.sh](metal/offline-compile.sh) | macOS with Xcode | Compile Metal with Apple's own GPU backend offline and split it per shader |
| [metal/macho_split.py](metal/macho_split.py) | any host | Split GPU Mach-O objects out of a compiled metallib or binary archive |
| [ram/ram-census.sh](ram/ram-census.sh) | the Linux device | Read-only RAM snapshot with GPU BO inventory, PSS per process, zram and PSI |

## Firmware: kernelcache to readable META code

Apple's GPU firmware ships inside the kernelcache, in the firmware kext's `__TEXT,__const` section, as an
Imagination META "LDR" image. The A9 firmware runs on a META core next to the GPU.

```text
extract-kext-firmware.py KERNELCACHE --list          # which AGX bundle ids exist (pick --gpu)
extract-kext-firmware.py KERNELCACHE OUT --gpu G5P   # kexts, sections, agx-g5p-c0.ldr, meta-ldr.json, strings.tsv
build-metag-binutils.sh ~/metag                      # once; DOCKER_IMAGE=<linux image> on macOS
disassemble-ldr.py OUT REGIONS --objdump ~/metag/bin/metag-linux-objdump
minim.py REGIONS --objdump ~/metag/bin/metag-linux-objdump
```

- KERNELCACHE is the decompressed arm64 Mach-O from the restore image for your device and iOS version.
  The extractor handles the old *prelinked* layout (`__PRELINK_INFO`). The A9's iOS 16.7.10, the iPad5,1's
  iOS 15.8.8 and the iPad5,3's iOS 12.4 kernelcaches use it [V]. It refuses the newer MH_FILESET layout.
- We have run this on the A9 (j71t, iOS 16.7.10, `--gpu G5P`), the A8 (iPad5,1, iOS 15.8.8, `--gpu G4P`) and
  the A8X (iPad5,3, iOS 12.4, `--gpu G4G`). The A8 and A8X kernelcaches have no `IOGPUFamily`; the extractor
  then takes `IOAcceleratorFamily2` instead. The iPod7,1's iOS 12 kernelcache has a merged layout the
  extractor cannot read yet. On another chip, run `--list` and pass the suffix you see. Then
  check two things before you trust the output: that the firmware kext's `requestFirmwareBinary` returns the
  `__TEXT,__const` pointer and length, and that the blob starts with the META LDR device id the decoder checks.
- `strings.tsv` (the kext `__cstring` strings plus the strings inside the LDR) is a good starting index for
  Ghidra. The kext's strings name many methods, and the LDR carries a few firmware strings and labels (e.g.
  `META FW started!`).
- Most of the A9 firmware's code is MINIM, which plain `objdump` decodes as garbage. `minim.py` expands
  the general-purpose subset following the public META HTP TRM. Its decodes are provisional. The docstring
  explains the storage-order trap: a 16-bit instruction is a little-endian halfword, not the byte pair as printed.
- For the kexts, load `<kext>.macho` into Ghidra as AARCH64 at its original VAs.

### MINIM: what `minim.py` does and how far it gets

**Source.** The encodings come from Imagination's public *Meta HTP* TRM 2.1.235, section 3
(<https://docs.alexrp.com/metag/meta_htp_insns.pdf>). Lauterbach's META debugger manual
(<https://www2.lauterbach.com/pdf/debugger_meta.pdf>) explains MINIM's storage and execution addresses.
GNU binutils 2.30 (`build-metag-binutils.sh`) is the back end: `minim.py` rewrites every MINIM instruction it
understands as the standard 32-bit META word, at the PC where MINIM executes it, and lets `objdump` print that.
`minim.py` invents no mnemonics of its own.

**Storage is not the PC.** In a MINIM region the core executes at twice the storage offset:
`pc = base + 2 * (storage - base)`. A 2-byte instruction advances the PC by 4, a 4-byte one by 8. Branch
targets, return addresses and the PCs the firmware reports (in its alive event, or a halted thread's PC) are
execution PCs. Data pointers are plain addresses. Reading the bytes at a PC's numeric value reads something
else. To find the bytes:

```text
minim.py --base 80000000 --pc 80009c14     # pc 0x80009c14 -> storage 0x80004e0a
minim.py --base 80000000 --storage 80004e0a
```

**On an A8 or A8X.** Same pipeline, with the firmware kext's suffix:

```text
extract-kext-firmware.py KERNELCACHE OUT --gpu G4G   # A8X; the A8 is G4P
disassemble-ldr.py OUT REGIONS                       # <base>.bin per region; objdump optional
METAG_OBJDUMP=~/metag/bin/metag-linux-objdump minim.py REGIONS 10000000 20000000 80000000 c0000000
```

- The objdump comes from `--objdump`, `$METAG_OBJDUMP`, or `--docker-image` plus `--tools-dir`. Without one,
  `minim.py` still writes `<base>.minim.json` (PC, storage address, bytes, expanded word) and
  `<base>.minim-stats.json`.
- `<base>.minim.dis` has one line per instruction: execution PC, storage address and bytes, decode.
  `UNKNOWN` marks an encoding the expander refuses. `; 0x0000 halfword` marks zero fill.
- Leave out the data regions: `0xe0001000` is a data page (we have not seen code there). `0xc0000000` holds
  only the 0x38-byte bootloader stub.
- Keep REGIONS out of public repositories: it is Apple's firmware.

**Coverage.** These are counts over every halfword in the code regions, code and data alike, since the
listing does not follow control flow. "Expanded" means the expander accepted the encoding. It does not mean
the decode is right. Only the GP anchors in the tests and the sites we read by hand in our A9 work are
verified. All three went through the pipeline above. Regions: `0x10000000`, `0x20000000`, `0x80000000` and
`0xc0000000`. The A8 image has no core memory at `0x80000000`; we also left out its small `0x60000000` data
range. Another iOS version's firmware is a different build and gives somewhat different counts.

| Firmware | Instructions | 0x0000 halfwords | Non-zero | UNKNOWN | Expanded (of non-zero) |
|---|---:|---:|---:|---:|---:|
| A9 G5P, iOS 16.7.10 | 57,175 | 22,194 | 34,981 | 815 | 97.7 % |
| A8 G4P, iOS 15.8.8 | 45,572 | 11,904 | 33,668 | 957 | 97.2 % |
| A8X G4G, iOS 12.4 | 57,585 | 22,866 | 34,719 | 918 | 97.4 % |

Before this version `objdump` folded runs of zero words into `...`, so their lines printed as `?`. All of
those lines were 0x0000 halfwords. `minim.py` now passes `-z`.

**What stays UNKNOWN** (the A9 counts; the A8 and A8X show the same classes in about the same numbers; the
A8 G4P image also has 47 rejected long forms):

| Class | A9 count | What is missing |
|---|---:|---|
| extended shift, ADD, SUB, MUL, OR, AND, XOR with extension bit 12 | 498 | the conditional form; only immediate ADD to XOR is implemented |
| extended A-unit ADD/SUB with extension bit 13 | 190 | bit 13's meaning is not decoded |
| extended GET/SET, multi-register | 73 | MGET/MSET with an extension word |
| extended CMP/TST | 30 | register form with extension bits 7..1, or bit 13 |
| short `0x9xxx` group 3 (MSET/MGET/MOV family) | 24 | sub-forms not implemented |

Read around them by hand, and don't feed a listing into anything automatic.

**Tests.** `python3 tools/a9/firmware/test_minim.py` needs no firmware. It covers the TRM GP and DCACHE
encodings, all 65,536 halfwords' classification, every short-branch offset and condition, the 4-byte branch
range limits, the storage/PC mapping, and `run()` on a synthetic region. With `METAG_OBJDUMP` set, one more
test runs the synthetic region through `objdump`. On macOS, point it at a script that runs the Linux objdump
in Docker.

## Measuring: GPU ms/frame, not just fps

`census/glm-census.sh` runs a fixed list of glmark2 scenes. For each one it records fps, GPU busy %, GPU
ms/frame and jobs/frame, and the `up=` uptime window, so you can line the scene up with kernel log
events. It copies the GPU-relevant environment from a running compositor (labwc by default;
`ENV_MATCH` picks one session). That way you measure the Mesa the desktop actually loads, not a stale
private build.
`census/gpu-stats.py` is the parser. Its docstring describes the counters, so you can add the same
counters to your own driver: per-job firmware start and end stamps per engine, in a snapshot you can reset.

## Shader questions: ask Apple's compiler

`metal/offline-compile.sh` uses the Xcode Metal toolchain's `metal-tt` with `-arch applegpu_g5p` to turn Metal
source into the exact GPU code the iOS driver would load. `macho_split.py` then splits it into one blob
per shader. `example/` has a vertex+fragment triangle and a compute kernel. We used this to answer questions
like "does Apple unroll this loop?" or "how many varyings fit?". A one-factor change in the
Metal source lets you diff the outputs.

What we found about other generations (Xcode Metal toolchain 27.1, 2026-11-11):
- A strings scan of one of the toolchain's GPU backend libraries lists the architecture names `applegpu_g4p`
  and `applegpu_g4g`. [V]
- `metal-tt -arch applegpu_g4p` (and `g4g`) reports "No available translator". [V] That these two names
  mean A8 and A8X is our guess. [I]
- `applegpu_g5p` compiles only with deployment target iOS 16.0 or later. [V]
- An A8 port therefore needs another reference compiler: an older Xcode, or the compiler in the device's
  own iOS, on a device you own. [I]

## RAM

`ram/ram-census.sh LABEL` prints a read-only snapshot to stdout: meminfo, iomem, memblock, the GPU BO
inventory from debugfs, PSS per process, zram, PSI and reclaim counters. Take one at idle and one under
load, and diff them. The rules that kept our numbers honest are printed at the end. Views overlap, so don't
sum them; BO counters are device-wide, so don't multiply them per client. The output contains your boot id and
kernel command line, so don't publish it raw.

## Before you run anything on a device

- The device-side scripts use `sudo -n` only for debugfs and `/proc/<pid>/environ`. `sudo` strips
  `LD_LIBRARY_PATH` and `LD_PRELOAD`, so a GPU client started under sudo silently loads a different Mesa.
- Copying scripts to the device can lose the executable bit. Run them as `bash script.sh`.
