#!/usr/bin/env python3
"""Summarise the A10 kernel's per-job timing ring.

The ring is an experiment in the development kernel (debugfs
`pvr_apple_jobtimes`, 16384 records of 32 bytes: u64 run, u64 doorbell, u64
completion signalled (CLOCK_MONOTONIC ns), u32 engine | seq << 8, u32 the
worker's tgid, meaningless). Read it as root:

    cat /sys/kernel/debug/pvr_apple_jobtimes > jobtimes.bin

    jobtimes.py jobtimes.bin               per engine: waits, GPU times, occupancy
    jobtimes.py jobtimes.bin --frames N    the last N jobs in doorbell order
    jobtimes.py jobtimes.bin --trace T     GPU time per pass: T is the g9p:
                                           trace lines (G9P_TRACE) of the same
                                           run; passes matched by submission time

"wait" is run to doorbell (the kernel's own waits), "gpu" doorbell to
completion (firmware and GPU, including retirement for fragment jobs).
"""
import argparse, bisect, collections, re, struct

ENGINES = {0: 'compute', 1: 'geometry', 2: 'fragment'}


def load(path):
    d = open(path, 'rb').read()
    recs = [struct.unpack_from('<QQQII', d, i) for i in range(0, len(d) - 31, 32)]
    return sorted((r for r in recs if r[0]), key=lambda r: r[1])


def summary(recs):
    span = (max(r[2] for r in recs) - min(r[1] for r in recs)) / 1e9
    print('%.1f s, %d jobs' % (span, len(recs)))
    for e, name in ENGINES.items():
        rs = [r for r in recs if r[3] & 0xff == e]
        if not rs:
            continue
        w = sorted((r[1] - r[0]) / 1e3 for r in rs)
        g = sorted((r[2] - r[1]) / 1e3 for r in rs)
        n = len(rs)
        iv = sorted((r[1], r[2]) for r in rs)
        busy, (s, en) = 0, iv[0]
        for a, b in iv[1:]:
            if a > en:
                busy += en - s
                s, en = a, b
            else:
                en = max(en, b)
        busy += en - s
        print('%-8s n=%6d  wait med %5.0f p90 %6.0f us | gpu min %5.0f med %5.0f p90 %6.0f us'
              ' | occupied %3.0f%%' % (name, n, w[n // 2], w[int(n * .9)], g[0], g[n // 2],
                                       g[int(n * .9)], 100 * busy / 1e9 / span))


def frames(recs, count):
    rs = recs[-count:]
    t0 = rs[0][1]
    for run, kick, done, es, _ in rs:
        print('%8.2f ms  %-8s #%-6d gpu %6.2f ms  waited %5.2f ms' % (
            (kick - t0) / 1e6, ENGINES.get(es & 0xff, '?'), es >> 8, (done - kick) / 1e6,
            (kick - run) / 1e6))


def passes(recs, trace):
    geom = [r for r in recs if r[3] & 0xff == 1]
    frag = {r[3] >> 8: r for r in recs if r[3] & 0xff == 2}
    runs = [r[0] for r in geom]
    agg = collections.defaultdict(lambda: [0, 0.0, 0.0])
    used = set()
    for line in open(trace):
        m = re.search(r'trace \d+: (\d+x\d+)(?: x(\d+))? (\w+), (\d+) draws, at ([\d.]+) ms'
                      r'.*pipelines ?([\d ]*)', line)
        if not m:
            continue
        t = float(m.group(5)) * 1e6
        i = bisect.bisect_left(runs, t)
        while i < len(geom) and i in used:
            i += 1
        if i >= len(geom) or geom[i][0] - t > 20e6:
            continue
        used.add(i)
        g = geom[i]
        f = frag.get(g[3] >> 8)
        draws = int(m.group(4))
        key = (m.group(1), 'x' + (m.group(2) or '1'), m.group(3), draws if draws < 20 else 'many',
               ' '.join(m.group(6).split()[:3]))
        a = agg[key]
        a[0] += 1
        a[1] += (g[2] - g[1]) / 1e3
        a[2] += (f[2] - f[1]) / 1e3 if f else 0
    for k, (n, gs, fs) in sorted(agg.items(), key=lambda x: -(x[1][1] + x[1][2]))[:20]:
        print('%-10s %-3s %-8s %-5s %-10s n=%5d  geometry %6.0f us  fragment %6.0f us' % (
            *k, n, gs / n, fs / n))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('ring')
    ap.add_argument('--frames', type=int)
    ap.add_argument('--trace')
    a = ap.parse_args()
    recs = load(a.ring)
    if a.frames:
        frames(recs, a.frames)
    elif a.trace:
        passes(recs, a.trace)
    else:
        summary(recs)


if __name__ == '__main__':
    main()
