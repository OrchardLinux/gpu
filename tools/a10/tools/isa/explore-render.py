#!/usr/bin/env python3
"""Compile Metal vertex/fragment pairs for applegpu_g9p (A10) and print the
code of every function in the result (for the graphics part of ISA.md).

FILE.metal has a shared header; each line starting with `// pair VS FS`
names one render pipeline (BGRA8Unorm colour attachment):

  explore-render.py FILE.metal [WORKDIR]
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


def functions(data):
    """(name, code) of every nested Mach-O function in @data."""
    out, start = [], 4
    while (i := data.find(b'\xcf\xfa\xed\xfe', start)) >= 0:
        start = i + 4
        found = g9p_text.parse(data, i)
        if found:
            out.append(found)
    return out


def words(code):
    w = [int.from_bytes(code[k:k + 2], 'little') for k in range(0, len(code) - 1, 2)]
    while w and w[-1] == 0xc000:
        w.pop()
    if w and w[-1] == 0x8000:
        end = w.pop()
        while w and w[-1] == 0xc000:
            w.pop()
        w.append(end)
    return w


def main():
    src = pathlib.Path(sys.argv[1]).resolve()
    work = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else src.with_suffix('.build'))
    work.mkdir(parents=True, exist_ok=True)
    text = src.read_text()
    pairs = re.findall(r'^// pair (\w+) (\w+)', text, re.M)
    air, lib = work / 'all.air', work / 'all.metallib'
    run('xcrun', 'metal', '-target', 'air64-apple-ios17.0', '-c', str(src), '-o', str(air))
    run('xcrun', 'metallib', str(air), '-o', str(lib))
    for vs, fs in pairs:
        script, out = work / f'{fs}.mtlp-json', work / f'{fs}.g9p.bin'
        script.write_text(json.dumps({'pipelines': {'render_pipelines': [{
            'vertex_function': vs, 'fragment_function': fs,
            'color_attachments': [{'pixel_format': 'BGRA8Unorm'}]}]}}))
        try:
            run('xcrun', 'metal-tt', '-arch', 'applegpu_g9p', '-target', 'air64-apple-ios17.0',
                str(lib), str(script), '-o', str(out))
        except subprocess.CalledProcessError:
            print(f'{fs}: compile failed', file=sys.stderr)
            continue
        for name, code in functions(out.read_bytes()):
            print(f'{fs} [{name}]  ' + ' '.join(f'{w:04x}' for w in words(code)))


if __name__ == '__main__':
    main()
