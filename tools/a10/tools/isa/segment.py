#!/usr/bin/env python3
"""Split applegpu_g9p code into instructions with the lengths learned so far.

Reads `name  word word ...` lines (explore.py output) and splits each stream
into instructions: bit 8 of a word means another word follows. A stream is
consistent when the split ends exactly on its final 0x8000.

  segment.py CORPUS.txt [--all]
"""
import sys


def length(words, i):
    """Length in words of the instruction at @i: bit 8 of every word means
    another word follows (ISA.md, "Instruction length")."""
    n = 1
    while i + n - 1 < len(words) and words[i + n - 1] & 0x0100:
        n += 1
    return n


def split(words):
    out, i = [], 0
    while i < len(words):
        n = length(words, i)
        if n is None:
            return out, i
        out.append(words[i:i + n])
        i += n
    return out, None


def main():
    show_all = '--all' in sys.argv
    good = bad = 0
    for line in open(sys.argv[1]):
        if not line.strip():
            continue
        name, *hexwords = line.split()
        words = [int(w, 16) for w in hexwords]
        insns, stuck = split(words)
        if stuck is None:
            good += 1
            if show_all:
                print(f'{name:<10} ' + ' | '.join(' '.join(f'{w:04x}' for w in x) for x in insns))
        else:
            bad += 1
            done = ' | '.join(' '.join(f'{w:04x}' for w in x) for x in insns)
            rest = ' '.join(f'{w:04x}' for w in words[stuck:stuck + 6])
            print(f'{name:<10} {done} || ?? {rest}')
    print(f'{good} streams split, {bad} stuck', file=sys.stderr)


if __name__ == '__main__':
    main()
