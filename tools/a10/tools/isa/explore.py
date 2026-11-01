#!/usr/bin/env python3
"""Compile Metal compute kernels for applegpu_g9p (A10) and print their code.

Every line `kernel void NAME(...) {...}` in FILE.metal (one kernel per
line; other lines are a shared header) is compiled as its own library and
pipeline: metal-tt compiles every function of a library, names each
_agc.main and keeps no order. Needs Xcode's Metal toolchain
(xcodebuild -downloadComponent MetalToolchain). For the ISA study in ISA.md.

  explore.py FILE.metal [WORKDIR]
"""
import json
import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
g9p_text = __import__('g9p-text')


def run(*cmd):
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    src = pathlib.Path(sys.argv[1]).resolve()
    work = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else src.with_suffix('.build'))
    work.mkdir(parents=True, exist_ok=True)
    lines = src.read_text().splitlines()
    header = [l for l in lines if not re.match(r'\s*kernel\s', l)]
    kernels = [(re.search(r'kernel\s+void\s+(\w+)', l).group(1), l)
               for l in lines if re.match(r'\s*kernel\s', l)]
    names = [n for n, _ in kernels]
    # One kernel per metallib: metal-tt compiles every function of the
    # library, names each _agc.main and does not keep any order.
    funcs = []
    for name, line in kernels:
        one = work / f'{name}.metal'
        one.write_text('\n'.join(header + [line]) + '\n')
        air, lib = work / f'{name}.air', work / f'{name}.metallib'
        script, out = work / f'{name}.mtlp-json', work / f'{name}.g9p.bin'
        script.write_text(json.dumps(
            {'pipelines': {'compute_pipelines': [{'compute_function': name}]}}))
        try:
            run('xcrun', 'metal', '-target', 'air64-apple-ios17.0', '-c', str(one), '-o',
                str(air))
            run('xcrun', 'metallib', str(air), '-o', str(lib))
            run('xcrun', 'metal-tt', '-arch', 'applegpu_g9p', '-target', 'air64-apple-ios17.0',
                str(lib), str(script), '-o', str(out))
        except subprocess.CalledProcessError:
            print(f'{name}: compile failed', file=sys.stderr)
            funcs.append(b'')
            continue
        data = out.read_bytes()
        found = None
        start = 4
        while (i := data.find(b'\xcf\xfa\xed\xfe', start)) >= 0 and not found:
            start = i + 4
            found = g9p_text.parse(data, i)
        funcs.append(found[1] if found else b'')
    width = max(map(len, names))
    for name, code in zip(names, funcs):
        words = [int.from_bytes(code[k:k + 2], 'little') for k in range(0, len(code) - 1, 2)]
        while words and words[-1] in (0xc000,):
            words.pop()
        # drop the padding run before the trailing end word
        if words and words[-1] == 0x8000:
            end = words.pop()
            while words and words[-1] == 0xc000:
                words.pop()
            words.append(end)
        print(f'{name:<{width}}  ' + ' '.join(f'{w:04x}' for w in words))


if __name__ == '__main__':
    main()
