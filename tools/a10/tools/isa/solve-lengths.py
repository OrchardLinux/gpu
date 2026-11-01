#!/usr/bin/env python3
"""Infer instruction lengths from a corpus of applegpu_g9p code.

Every stream must split into instructions that end exactly on its final
0x8000. Instructions whose length rule is known (segment.py's length())
keep it; for the others, the length is assumed to depend only on a key of
the first word (KEY below) and is searched for, consistently across all
streams, by backtracking. Prints the key → length table and the split of a
few streams.

  solve-lengths.py CORPUS.txt [KEYMASK]
"""
import importlib.util
import pathlib
import sys

spec = importlib.util.spec_from_file_location(
    'segment', pathlib.Path(__file__).with_name('segment.py'))
segment = importlib.util.module_from_spec(spec)
spec.loader.exec_module(segment)

KEYMASK = int(sys.argv[2], 0) if len(sys.argv) > 2 else 0xffff
LENGTHS = range(1, 7)
sys.setrecursionlimit(100000)


def solve(streams):
    table = {}

    def walk(si, i):
        if si == len(streams):
            return True
        words = streams[si]
        if i == len(words):
            return walk(si + 1, 0)
        known = segment.length(words, i)
        if known is not None:
            return i + known <= len(words) and walk(si, i + known)
        key = words[i] & KEYMASK
        if key in table:
            n = table[key]
            return i + n <= len(words) and walk(si, i + n)
        for n in LENGTHS:
            if i + n > len(words):
                break
            table[key] = n
            if walk(si, i + n):
                return True
            del table[key]
        return False

    return table if walk(0, 0) else None


def main():
    streams, names = [], []
    for line in open(sys.argv[1]):
        if line.strip():
            name, *hexwords = line.split()
            names.append(name)
            streams.append([int(w, 16) for w in hexwords])
    table = solve(streams)
    if table is None:
        print('no consistent assignment with this key')
        return 1
    for key in sorted(table):
        print(f'{key:04x}: {table[key]}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
