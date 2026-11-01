# timeline.py FILE: read the kernel's apple_timeline (timeline.patch;
# 16-byte records {u64 ns, u32 event << 16 | engine, u32 seq}; events 0
# queued, 1 written and doorbell rung, 2 fence signalled, 3 a geometry job
# saw the previous fragment job retired; engines 1 geometry, 2 fragment).
# Prints the per-render hand-offs and, per frame (renders less than 1.5 ms
# apart), how long the chain of renders runs and how frames are spaced.
#   python3 timeline.py apple_timeline.bin
import statistics as st
import struct
import sys

recs = sorted(r for r in struct.iter_unpack('<QII', open(sys.argv[1], 'rb').read()) if r[0])
written, signalled = {}, {}
for ns, ev, seq in recs:
    kind, engine = ev >> 16, ev & 0xffff
    if kind == 1:
        written[(engine, seq)] = ns
    elif kind == 2:
        signalled[(engine, seq)] = ns

renders = []
for seq in sorted(s for (e, s) in written if e == 1):
    g, f = (1, seq), (2, seq)
    if g in signalled and f in written and f in signalled:
        renders.append((written[g], signalled[g], written[f], signalled[f]))
if len(renders) < 20:
    sys.exit(f'only {len(renders)} complete renders in {len(recs)} records')


def show(name, values, unit=1e3):
    v = sorted(x / unit for x in values)
    print(f'  {name:40s} median {st.median(v):8.2f}  p10 {v[len(v) // 10]:8.2f}  p90 {v[9 * len(v) // 10]:8.2f}')


print(f'{len(renders)} renders (us)')
show('geometry: written -> signalled', [r[1] - r[0] for r in renders])
show('geometry signalled -> fragment written', [r[2] - r[1] for r in renders])
show('fragment: written -> signalled', [r[3] - r[2] for r in renders])
show('fragment signalled -> next geometry written',
     [b[0] - a[3] for a, b in zip(renders, renders[1:]) if b[0] - a[3] < 1.5e6])

frames, cur = [], [renders[0]]
for a, b in zip(renders, renders[1:]):
    if b[0] - a[3] > 1.5e6:
        frames.append(cur)
        cur = []
    cur.append(b)
frames.append(cur)
starts = [f[0][0] for f in frames]
periods = [b - a for a, b in zip(starts, starts[1:])]
print(f'{len(frames)} frames, median {st.median(len(f) for f in frames)} renders each (ms)')
show('chain: first geometry written -> last fragment', [f[-1][3] - f[0][0] for f in frames], 1e6)
show('frame start to next frame start', periods, 1e6)
# late frames (the next one starts more than 25 ms later) by chain length:
# a sharp step shows the deadline the chain must meet
buckets = {}
for f, p in zip(frames, periods):
    if len(f) < 3 or p > 200e6:
        continue
    b = int((f[-1][3] - f[0][0]) / 1e6)
    late, n = buckets.get(b, (0, 0))
    buckets[b] = (late + (p > 25e6), n + 1)
print('  chain ms: late frames / frames')
for b in sorted(buckets):
    print(f'  {b:3d}-{b + 1:<3d} {buckets[b][0]:5d} / {buckets[b][1]}')
