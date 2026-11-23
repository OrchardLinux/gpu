# a8-passcap: one Metal pass per feature (A8, iOS 12)

A command-line Metal program for an A8 device on jailbroken iOS 12 (built and run on the iPod touch 6,
N102). Every pass draws the same small triangle into a 64x64 target and changes one thing: a target
format, a depth/stencil mode, MSAA, a load action, a texture kind, a sampling form (LOD, bias, gradients,
gather, offsets, arrays, cubes), the number of textures and samplers, vertex-stage textures, flat and
centroid varyings, and so on. Running each pass in its own command buffer lets you compare how iOS encodes
the feature against the one-feature-off baseline. The A8 notes in [a8/n102/](../../../a8/n102/README.md)
were checked this way where they say **[iOS]**.

| File | What |
|---|---|
| `a8-passcap.m` | the program: pass table, resources, capture and loop modes |
| `passcap.metal` | the vertex and fragment functions the passes use (Metal 2.1) |
| `metal.entitlements.plist` | the entitlements a command-line process needs to open a Metal device on jailbroken iOS |
| `build.sh` | builds `a8-passcap` and `passcap.metallib` and signs the binary with `ldid` |

## Build and run

On macOS with Xcode and `ldid`:

```sh
./build.sh            # writes out/a8-passcap and out/passcap.metallib (OUT=... to change)
```

Copy both to the device, then:

```sh
./a8-passcap -L                                     # list the passes and what each one isolates
./a8-passcap -l passcap.metallib -o OUTDIR          # every pass once; status and target readback per pass
./a8-passcap -l passcap.metallib -p PASS -t 60      # draw one pass every frame for 60 s
```

The capture mode also saves the process's own GPU-visible memory before and after each commit
(`-m MB` caps it), and the loop mode keeps one pass running so that a separate kernel-memory reader can
look at the firmware's view of it. That reader is not included here.

## What you must not publish

The capture mode's output contains Apple-compiler shader binaries and command data written by Apple's
driver. Keep it on your own machine: study it locally and write up what you learn in your own words (field
positions and meanings), as the notes here do. The repository's rule is in the top-level
[README](../../../README.md#apple-data).

The program only reads its own memory and its own resident pages; it opens no device pager and writes
nothing outside its output directory.

Licence: MIT (SPDX headers in the files). Written with AI assistance (Claude).
