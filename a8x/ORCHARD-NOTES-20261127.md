# A8X (J81): from the alive event to the first job, notes from the A8/A9 driver

**Scope.** This follows our 11-24 reply and your report from 26 November (OrchardLinux/gpu `a8x/FIRMWARE-BOOT.md`, run 65 and research requests 14 to 18). It answers E1 to E5, the idle-PC "noise" and scheduler `+0x778`. It does not repeat the 11-24 reply. We still have no A8X of our own. Where your device result and our reading differ, your result stands and we say where we differ.

**Sources and tags.** These are the tags of the 11-24 reply, plus three new ones.

| Tag | Meaning |
|---|---|
| `[A8 on device]` | Measured on our iPod touch 6 (T7000) under Linux. |
| `[A9 on device]` | Measured on our iPad 5 (S8003) under Linux. |
| `[Apple code, A8 kc 0x…]` | iPod7,1 iOS 12.4 (16G77) kernelcache. |
| `[Apple code, A9 kc 0x…]` | j71t iOS 16.7.10 kernelcache. |
| `[Apple code, A9 fw 0x…]` | Apple's A9 META firmware, MINIM execution PCs. |
| `[Apple code, A8X 16G77]` | **New.** iPad5,3 iOS 12.4 (16G77) kernelcache and its `METAFW_G4G` firmware. This is the A8X, but three years older than your 19H394. |
| `[yours]` | **New.** Your notes and research results 14 to 18, not re-checked by us. |
| `[inferred]` | Our reading, not measured. |

**Code references.** `S:n` is line n of `drivers/gpu/drm/imagination/pvr_apple_s8003.c` in [OrchardLinux/linux `059fadee`](https://github.com/OrchardLinux/linux/blob/059fadee222d64ba540fe8155597935c2ffd49f2/drivers/gpu/drm/imagination/pvr_apple_s8003.c). The A8 code is patches 0067 to 0076 and the A9 code patches 0015 to 0025 at orchard tag [`kernel-patches-final`](https://github.com/OrchardLinux/orchard/tree/kernel-patches-final/kernel/patches/drivers/gpu). The A8 work merged with orchard#196 on 23 November (0063 to 0073); 0074 to 0076 came after it. As of 27 November the patches live as commits in OrchardLinux/linux. Your request 18 cites the same file with the same `S:n` numbers, so the numbers line up. `VM:n` is `pvr_vm.c`, `MMU:n` is `pvr_mmu.c` and `DEFS:n` is `pvr_rogue_mmu_defs.h`, all at the same commit.

---

## 0. What is new since 11-24

1. **Your 19H394 firmware uses the A9's object sizes, not our A8's.** Use our A9 offsets for root, state and POLICY. Your config is a hybrid: our A8's head, then the A9's fields (section 1).
2. **E5, the first command**, step by step, with what proves it ran:
   - command 8 on the device-control ring;
   - the consumer index moves only after the command's handler returns;
   - in the A9 firmware's code, CONTROL `+0x1024` also counts up (section 6).
3. **Corrections to the plan in your request 18:**
   - We map the MMIO windows with bit 62 as well as bit 3.
   - Alive does not need the four hardware objects. Only PM/META-protect flags *on* them stop it.
   - Our A9 POLICY has one more word than your list.
4. **The idle-PC "noise" has a likely cause.** MINIM executes at twice its storage offset. Your idle PCs are stored inside the loaded core-memory code, and the addresses you read are storage the LDR never writes (section 7.1).
5. **Scheduler `+0x778`** is, by our A9 firmware reading, where the partial-render scan of that block starts (section 7.2, partly inferred).
6. **A public MINIM decoder.** `tools/a9/firmware/minim.py` has been in OrchardLinux/gpu since 23 November. A new branch adds A8/A8X use, measured coverage, tests and a PC-to-storage helper (section 8).

---

## 1. Which layout your firmware has

Your object sizes match our A9 table exactly, not our A8 table.

| Object (our CPU-side id) | A8 G4P, 16G77 | A9 G5P, 16.7.10 (`S:553-585`) | J81 19H394 `[yours]` |
|---|---|---|---|
| INIT (0x44), your "root" | 0x1118 | 0x1490 | 0x1490 |
| channel blocks 0x47/0x48/0x49 | 0x990/0x8e0/0x8c0 | 0x990/0x8e0/0x8c0 | 0x990/0x8e0/0x8c0 |
| POLICY (0x4a) | 0x1058 | 0x938 | 0x938 |
| PLATFORM (0x4d), your "config" | 0x4dc | 0x78c | 0x318 |
| CONTROL (0x5e), your "state" | 0x1528 | 0x2058 | 0x2058 |
| ring control, per lane | 0x30 | 0x20 | check your kext |

Our iOS 12.4 A8X (16G77) kext has the A8 table byte for byte `[Apple code, A8X 16G77]`. So the layout changed between iOS 12 and your iOS 15, not between the A8 and the A8X.

Your config (PLATFORM) is a hybrid:

- **Up to the window table** it follows our A8 PLATFORM: the same heap bases and the same `+0x30`, then larger CSC blocks.
- **From the window table on** it carries the A9's fields, in the A9's order.
- **The last word** is the A8's again.

Your offsets below are from your request 14 t1 and request 18 `[yours]`. The A8 and A9 columns are what we write (`S:3649-3788`, `S:829-858`).

| Field | A8 16G77 | A9 16.7.10 | J81 19H394 `[yours]` |
|---|---|---|---|
| heap bases | `+0x00..+0x28` | `+0x00..+0x18` (other values) | `+0x00..+0x28`, the A8's values |
| YUV CSC object VA | `+0x30` | — | `+0x30` |
| CSC blocks | `+0x38..+0x187`, 2 × 0xa8 | — | `+0x38..+0x1b7`, 2 × 0xc0 |
| BorderColorTable VA | `+0x188` | — | `+0x1b8` |
| MMIO window table | `+0x190`, 12 entries | `+0x630`, 9 entries | `+0x1c0`, 9 entries |
| Fender enabled = 1 | `+0x250` | `+0x6c0` | `+0x250` |
| PIO supported = 1 | `+0x258` | `+0x6c8` | `+0x258`? `[inferred]`: both mappings land there; your t1 does not list it |
| chip info | `+0x300/+0x304/+0x308` | `+0x704/+0x708/+0x70c` | `+0x290` (u64), `+0x298` |
| highest state, count, MHz | `+0x30c/+0x310/+0x314` | `+0x710/+0x714/+0x718` | `+0x29c/+0x2a0/+0x2a4` |
| IRQ word, bit, AIC time | `+0x494/+0x498/+0x49c` | `+0x758/+0x75c/+0x760` | `+0x2e4/+0x2e8/+0x2ec` |
| thread 1 pc, sp | `+0x4a0/+0x4a4` | `+0x764/+0x768` | `+0x2f0` (pc low, sp high) |
| FenceBuffer VA | `+0x4a8` | `+0x76c` (we leave it 0) | `+0x2f8` |
| firmware base | `+0x4b0` | `+0x774` | `+0x300` |
| BIF data master 7 in the high word | `+0x4b8` | — (`+0x77c` = `0x300000`) | `+0x308` |

So from `+0x250` on your offsets are the A9's minus 0x470. From the chip info on they are minus 0x474: one word goes missing between them.

**Clusters (your "2 clusters?").** The A8X has 8. iOS 12.4 writes chip info `{3, 2, 0, 8}` where the A8 has `{2, 4, 0, 4}` `[Apple code, A8X 16G77: readChipInfo 0x694d268]`. The 2 is chip-info word 1, not a cluster count. The 8 is the count every job-record builder loops over. Expect `{3, 2}` in your u64 at `+0x290` and 8 at `+0x298` `[inferred]`. The A9 has `{1, 5}` and 6 clusters (`S:847-849`).

---

## 2. E1: page-table flags

The bits are from `DEFS:80-106`: bit 0 valid, bit 2 CC, bit 3 SLC bypass, bit 62 PM/META protect. `MMU:779-788` builds them from the BO flags.

| Region | Our A8 (works) | Our A9 (works) | Your plan (request 18) |
|---|---|---|---|
| image, root, shared | V \| b3 \| b62: `T7000_FW_FLAGS` (`S:3406`, mapped `S:3566-3571`) | image V \| b62; root and shared V \| b2 \| b62 (`S:964-981`) | V \| b3 \| b62 — **same as our A8** |
| zero page at VA 0 | V \| b3 \| b62 (`S:3573`) | V only (`S:983`) | not mapped yet |
| MMIO windows | **V \| b3 \| b62** (`pvr_vm_map_io`, `VM:1036`) | V \| b3 \| b62 (same function) | V \| b3 — **differs** |
| hardware objects `0x8_…` | V \| b3: `T7000_VM_FLAGS` (`S:3408`, `S:3576`) | none named | V \| b3 — **same** |
| A8 PM objects in job VMs | V \| b3 (`S:4689`) | — | later |

- **What "plain" meant on 11-24:** valid plus SLC bypass, without protect. It did not mean valid-only. Your request-18 table already reads it this way.
- **Why the A8 bypasses the SLC:** like your `dma_alloc_coherent` region, our A8 host maps this memory uncached (comment at `S:3552-3558`). With bypass the firmware and the host see the same bytes, and we never flush the SLC on the A8 `[A8 on device]`. Your run 65 says the same from the other side.
- **The A9 differs** because its memory is mapped cache-coherent (CC). That is not your situation `[inferred]`.
- **MMIO windows:** we have only ever run them with bit 62. If bit 3 alone works for you, that is new data; tell us.
- **Before E5:** do E1 first. With valid-only pages a consumer index that does not move proves nothing: the firmware's store may sit in the SLC. The firmware can also read stale SLC lines of a ring it has read before `[inferred]`.
- **Same code on the A8X:** the A8X 16G77 kext's GART, segment-MMU, boot-MMU and Fender code is instruction-equal to the A8's. Only the boot stream's SLC word differs (`0x3800` = `0x0003550000300001`, which matches your read-back `0x00300001`) `[Apple code, A8X 16G77]`. Your 19H394 kext may differ.

---

## 3. E2: the perf-state table, and the pins around it

The list in your request-18 t3/t4 is `0, 365, 450, 500, 550, 182, 225, 250, 275, 0 …`. Index 0 is state 0 at 0 MHz. That is the shape we use on both chips. Keep the leading 0: the summary in `FIRMWARE-BOOT.md` lists the values without it.

| | A8 16G77 (`S:3736-3744`) | A9 16.7.10 (`S:733-765`) | J81 `[yours]` |
|---|---|---|---|
| highest state | `+0x30c` = 3 | `+0x710` = 4 | `+0x29c` = 4 |
| count | `+0x310` = 16 (the capacity, iOS live value) | `+0x714` = 5 (entries we fill) | `+0x2a0` = 16 |
| MHz, index = Fender state | `+0x314`: 0, 365, 450, 500, 182, 225, 250 | `+0x718`: 0, 340, 474, 550, 723 | `+0x2a4..` |
| mV | `+0x354`: 600, 871, 896, 912, … | none | none |

The A9 also writes governor limits that keep the firmware in the state the host powered it up in. Then it never changes the clock and never powers the core off on its own; the host does that `[A9 on device]`. The A9 values, with q the start state and N the highest state (`S:746-765`):

| Word | A9 value |
|---|---|
| CONTROL `+0x1028` | 3348 (the A9's power envelope, mW; yours unknown) |
| CONTROL `+0x102c`, `+0x1040` | 100·q |
| CONTROL `+0x1030`, `+0x1038` | 100·N |
| POLICY `+0x688`, `+0x68c` | 100·N |
| POLICY `+0x6f0`, `+0x6f4` | 100·q |
| for q > 1 only | POLICY `+0x28` = q<<32 \| q, `+0x30` = 0, `+8` = 0 |

Your kext writes 100·N = 400 to POLICY `+0x6fc` and `+0x7cc` `[yours]`. Our iOS 16 reading puts 100·N at `+0x688/+0x68c`. We cannot settle which pair your 19H394 firmware reads. Trust your kext, and treat our offsets as the A9's.

The A8 has the same kind of pins in a different place: CONTROL `+0xc66` = 1867 and `+0xc6a/+0xc6e` = 100·q (`S:3769-3771`).

---

## 4. E3: POLICY

We start the A9 from these words, everything else zero, written before the release (`S:860-864`):

| POLICY word | A9 value | In your list? |
|---|---|---|
| `+0x08` (u64) | `0x4_00000000`, i.e. `+0x0c` = 4 | **no** |
| `+0x10` (u64) | `0x3f800000` (1.0f) | yes |
| `+0x28` (u64) | `0x1_00000001` | yes |
| `+0x38` | 100 | yes |
| `+0x8f8` (u64) | the timer now (`arch_timer_read_counter()`, 24 MHz) | yes |
| pins | from section 3 | |

With this, plus the perf table and pins, the A9 boots, takes commands and runs jobs `[A9 on device]`.

Our A8 POLICY is a different, larger object (0x1058 bytes). It carries a 0x160-byte power-model block and the governor words copied from iOS (`S:3605-3634`, `S:3756-3764`). Don't port it to your layout. Two pieces of it do apply to the A8X:

- **The power-model values.** They come from the ADT's `gpu-pwr-*` and `gpu-perf-*` properties, and the A8X's differ from the A8's `[Apple code, A8X 16G77; ADT]`. Your request 18 already leaves them for later.
- **The max-power word.** The A8's `0xaba` becomes `0x1392` on the A8X `[Apple code, A8X 16G77; ADT]`.

---

## 5. E4: the four hardware objects

Your request-18 t2 matches ours: VAs, 0x4000 each, the border table from kext data, and the naming fields. Three additions:

1. **Alive does not need them.** On 11-24 we said the firmware does not boot when they are mapped with PM- or firmware-protect flags. Without them it reaches alive and takes commands:
   - our A9 names none (`+0x76c` stays 0, object 0x4c is 8 zero bytes) and runs jobs `[A9 on device]`;
   - your A8X reached alive without them `[yours]`.

   So E4 is not on the path to E5.
2. **The first job needs them, in that job's VM.** The firmware loads the FenceBuffer VA into `MCU_FENCE` (R0 `0x1740`) at boot.
   - The MCU then writes the fence through the **running job's** page catalogue. On the A8 our first TA job stalled on an MMU write fault at VA `0x8_00010000` in the job's context, while the objects were mapped only in context 0 `[A8 on device]`.
   - Map all four at the same VAs in every VM that runs jobs (`t7000_vm_map`, `S:4311-4324`). Apple's kext reserves `0x8_00000000` plus 4 MiB in every GART `[Apple code, A8 kc 0xfffffff008463138]`.
   - The border table is read through R0 `0x1790/0x17a0/0x17a8` once a sampler uses border colours. Zeros are fine until then `[inferred]`.
3. **Without E4, map a zero page at VA 0 in every job context.** With the FenceBuffer word 0, the firmware sets `MCU_FENCE` = 0, so the fence lands at VA 0. Our A8 jobs ran that way before the objects were named, because a page at 0 was mapped in both contexts `[A8 on device]`. The A9 driver keeps such a page at 0 (`S:956-963`). Your request 18 rates the zero page low because BIF faults stay 0 so far. That holds for alive and device-control commands, not for jobs.

---

## 6. E5: the first command from an idle firmware

### 6.1 Which command

| | A9 (your layout's generation) | A8 16G77 |
|---|---|---|
| first command | **8**, no payload (`s8003_first_command`, `S:2980-2992`) | 3 = load a VM slot; this variant has no first-command hook (`s8003_variant_a8`, `S:6081-6121`) |
| proven | every A9 boot `[A9 on device]` | taken in 231–273 µs, 6 of 6 `[A8 on device]` |

**We recommend command 8 first** `[inferred for your G4G]`. It touches no page table and no slot.

The A9 firmware's device-control switch covers commands 3 to 10 through one table `[Apple code, A9 fw 0x10001cf4]`. Command numbering in your 19H394 build is unchecked. To check it, find your kext's device-control writer: it uses a 20-byte ring stride and writes MTS `0x10`. The A9's is `[Apple code, A9 kc 0xfffffff006ca05d4]`, the A8's `[Apple code, A8 kc 0xfffffff00846f9a0]`.

### 6.2 Steps

This is `s8003_device_control` (`S:1587-1620`) and `s8003_doorbell` (`S:1564-1575`), with your offsets. "DC ctl" is the device-control ring's control lane, "DC ring" its 0x1400-byte entry array. Both are named in INIT like your other rings.

0. **Before you start:**
   - E1 is done, and you have seen alive without a flush.
   - Read the DC ctl's consumer (`+0x00`, written by the firmware) and producer (`+0x10`, written by you). Both must be equal and below 256.
1. **Payload count:** state (CONTROL) `+0x1020` = 0.
2. **Entry:** write 20 bytes at DC ring `+ 20 × producer`: `{8, 0, 0, 0, 0}`.
3. **Producer:** `wmb()`, then DC ctl `+0x10` = producer + 1 (mod 256), then `mb()`.
4. **Wake Fender:** `+0x14` = 7. Read it back: any bit beyond `0x7` means stop (`S:1566-1568`). Keep your own 1 ms spacing between Fender accesses. We have no such rule, but your device needed it in state 0.
5. **Check the core:** Fender `+0x1000` has no request in flight (bit 4 clear) and state ≠ 0 (`s8003_core_ready`, `S:1261-1268`). The A8's state-0 handling, if you need it, is at `S:4259-4298`.
6. **Kick:** R0 `0xb00` = `0x10` (`MTS_SCHEDULE`, TASK_COUNTED, DM0).
7. **Wait:** poll the DC ctl consumer until it equals the new producer, every 100 µs, up to 3 s. Drain the event ring between polls (6.4).

### 6.3 What proves it ran

The handler and its effects `[Apple code, A9 fw 0x10001f08, 0x10001cf4]`:

1. It zeroes root (INIT) byte `+0x498`.
2. It copies CONTROL `+0x1020` (0) into INIT `+0x1480`.
3. It skips the payload copy, because the count is 0.
4. It does cache maintenance.
5. It **increments CONTROL `+0x1024`**.
6. Only then does it publish the DC consumer. The consumer moves only after the handler returns.

The consumer index is the signal our A9 driver waits on, on every boot `[A9 on device]`. The `+0x1024` count comes from reading the A9 firmware's code; we have never logged it on a device. It is still worth reading before and after, because it tells two failure cases apart:

| Result | Meaning |
|---|---|
| consumer +1 (and `+0x1024` +1) | done |
| `+0x1024` +1, consumer unchanged | look at memory visibility (E1) |
| neither | the firmware never reached the handler: the kick, or the governor gate (7.3) |

**Thread 1.** Before the copy, command 8 calls a thread-1 sync helper (`0x10021d48`). It can spin while a firmware word is 0 `[Apple code, A9 fw]`. Our A9 never starts thread 1, and command 8 completes on every boot `[A9 on device]`. Your finding that thread 1 is not needed agrees.

### 6.4 Rings you must drain

- **Events (firmware → host):** the firmware writes the producer (`+0x10`), you write the consumer (`+0x00`).
  - On the A9 the firmware posts an alive event on every scheduler pass, about 290 per second `[A9 on device]` (`S:213-216`). A full 256-entry ring stalls it (`S:1166-1167`).
  - Your run 65 shows a single event so far. Drain anyway, the way `s8003_drain` does (`S:1172-1214`):
    - set the consumer to the producer on the four log lanes, statistics and trace;
    - read events one by one and advance their consumer.
- **The interrupt:** the AIC software interrupt, IRQ 138 for you. Ack it in the AIC's software-clear word, `0x20e104090`, bit `0x400`, as in the 11-24 reply. `S:106` is the base of that array (AIC `+0x4080`, one word per 32 IRQs). Polling works without the interrupt.

### 6.5 After command 8

1. **Slot load (command 3).** On the A9 the entries come in pairs; on the A8 there is one:
   - MMU root[slot] (8 bytes each) = the VM's page catalogue;
   - host tag[slot] = `0x00400000`;
   - entry `{3, slot}`.

   The "cookie" in the 11-24 reply's `{3, slot 1, cookie}` is this host tag, kept in its own array. It is not a third word of the ring entry.

   Done when the consumer moves **and** the firmware's seen-tag[slot] equals the tag (`s8003_slots_load`, `S:1634-1683`). The tag and root arrays are the objects that A9 CONTROL `+0x1044` and `+0x1048` name (`S:868-870`). Your request 18 lists `+0x104c` as A9-only; whether 19H394 also names `+0x1044/+0x1048` is for your kext to say.
2. **First job: compute** (`t7000_submit_compute`, `S:4433`, record `T7000_CU_W_SIZE` 0x298):
   - the job's record and microsequence go into the compute channel;
   - a 20-byte work-ring entry `{engine, channel, end}`;
   - the doorbell with DM2 (`t7000_publish`, `S:4391-4424`);
   - completion is the channel's finish stamp (`t7000_engine_done`, `S:4343-4354`).

   The A8X 16G77 compute record differs from the A8's in one word: `W+0x20 = 0xff`, all eight clusters `[Apple code, A8X 16G77: 0x694e36c]`. The TA and 3D records shift by +8 and their per-cluster arrays double. Your 19H394 records may differ again.

---

## 7. Open questions

### 7.1 Why core-memory reads near the idle PC return noise

- **The mapping:** in a MINIM region the core executes at twice the storage offset, `pc = base + 2 × (storage − base)`. PCs the firmware reports are execution addresses `[TRM 2.1.235; Lauterbach META manual; Apple code, A9 fw]`. On the A9, the alive event's PC `0x8000a120` is stored at `0x80005090`, inside the LDR's core-memory load.
- **Your request 16** reads PC `0x80009c74` as "outside the loaded coremem code (`0x80000080`–`0x80005334`)" `[yours]`. That holds only if the PC is a storage address. Mapped, your PCs fall inside that range:

  | PC (execution) | Stored at |
  |---|---|
  | `0x80009c14` (alive) | `0x80004e0a` |
  | `0x80009c74` (sampled) | `0x80004e3a` |

  `minim.py --base 80000000 --pc 80009c14` prints the first.
- **What you read at `0x80009c40..0x80009cc0`:** as storage this lies past the end of your load (`0x80005334`) and below the zeroed block at `0x8000a000` `[yours]`. The LDR never writes it. The two LDRs we have look the same:
  - A9: loaded up to `0x8000565c`;
  - A8X 16G77: loaded up to `0x80005388`;
  - both zero-filled from `0x8000a000` `[Apple code, A9 and A8X 16G77 LDR records]`.
- **So** those reads most likely return SRAM's power-up contents. That fits your run 57/58 note that the page "held unwritten SRAM" `[inferred]`. To see the idle loop itself, read storage `0x80004e0a` on.

### 7.2 Scheduler `+0x778`

- **The block:** your scheduler block is the 0x8e0 block, our object 0x48 (CHANNEL+1). Apple's host dump calls it the scheduler `[yours]`. Our A9 firmware notes call the block whose `+0x76c..+0x778` the 3D scheduler's partial-render path uses "the 3D context" `[Apple code, A9 fw]`. That this is the same 0x8e0 block is our reading: it is the only object Apple's A9 kext writes `+0x778` on `[inferred]`. In that block:
  - `+0x76c` = partial-render requests;
  - `+0x770` = requests handled (the 3D scheduler `0x10002a90` calls `0x10000ba4` while they differ);
  - `+0x774` = the channel whose ring is scanned;
  - **`+0x778` = the ring index where that scan starts.** `0x10001cb4` stores `+0x774/+0x778` from the TA's work record when it splits a render.
- **The init value:** Apple's A9 kext writes `0xffffffff` there at init `[Apple code, A9 kc 0xfffffff006c96be8]`. We read it as "no index" `[inferred]`. Our A9 driver does the same (`S:822`).
- **Other chips:** Apple's A8 16G77 kext does not write it, and it reads 0 under iOS `[Apple code, A8 kc 0xfffffff008466578; A8 on device, under iOS]`. Your 19H394 kext writes it, as the A9 does `[yours]`.
- **Apple's name for it:** unknown.

### 7.3 One more gate, from the A9 firmware

On every scheduler pass, before it reads the MTS, the A9 firmware calls its governor (`0x1000c0d8`) if PLATFORM `+0x6c0` (Fender enabled) and `+0x6c8` (PIO supported) are both nonzero `[Apple code, A9 fw 0x10001ac8, 0x10003ca4]`. Apple's kext sets both to 1, and so do we (`S:841-842`).

- In your layout these are `+0x250`, which your kext sets to 1, and most likely `+0x258` `[inferred]`.
- If `+0x258` is 1 while the perf and POLICY inputs are zero, the governor runs on empty inputs before every command fetch. Whether it returns is not established `[inferred]`.
- So fill E2 and E3 before E5, and log `+0x250/+0x258` in your E5 run.

---

## 8. MINIM decoder

- **It already exists.** `tools/a9/firmware/minim.py` has been public in OrchardLinux/gpu since 23 November. It is a MINIM → standard-META expander built from the public Meta HTP TRM 2.1.235, with GNU binutils 2.30 `objdump` as the back end.
- **New branch** `a9-minim-decoder` (not pushed yet):
  - `test_minim.py`, with no Apple bytes;
  - `--pc`/`--storage` conversion and per-region statistics;
  - `$METAG_OBJDUMP`, and `objdump -z`;
  - a fix so `extract-kext-firmware.py` reads the A8 and A8X kernelcaches, which have `IOAcceleratorFamily2` instead of `IOGPUFamily`. We checked the iPad5,1's iOS 15.8.8, your generation;
  - README notes for the A8 and A8X.
- **Coverage** (encodings the expander accepts, counted over code and data, not verified as correct):

  | Firmware | Expanded (of non-zero) |
  |---|---:|
  | A9 G5P, iOS 16.7.10 | 97.7 % |
  | A8 G4P, iOS 15.8.8 | 97.2 % |
  | A8X G4G, iOS 12.4 | 97.4 % |

  What stays UNKNOWN is mostly conditional extended ALU forms, A-unit ADD/SUB with extension bit 13, and multi-register GET/SET.
- **For you:** run it on your 19H394 LDR to read the idle loop at storage `0x80004e0a` and the command-8 handler.
