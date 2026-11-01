#!/usr/bin/env python3
"""Compile a Metal render pipeline for applegpu_g9p (A10) with a given colour
attachment state and print the fragment code Apple's compiler makes for it:
its blending (done in the shader), framebuffer fetch ([[color(0)]] inputs)
and output conversion (ISA.md "Tile read and blending").

FILE.metal defines a vertex function `vs` and the fragment functions named
on the command line. The attachment is BGRA8Unorm; KEY=VALUE pairs set
metal-tt pipeline-script colour attachment keys (blending_enabled,
source_rgb_blend_factor, destination_rgb_blend_factor, rgb_blend_operation,
the alpha ones, write_mask), e.g. premultiplied source-over:

  explore-blend.py FILE.metal fs blending_enabled=true \\
      source_rgb_blend_factor=One destination_rgb_blend_factor=OneMinusSourceAlpha \\
      source_alpha_blend_factor=One destination_alpha_blend_factor=OneMinusSourceAlpha
"""
import json
import pathlib
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
explore_render = __import__('explore-render')


def main():
    src = pathlib.Path(sys.argv[1]).resolve()
    names = [a for a in sys.argv[2:] if '=' not in a]
    att = {'pixel_format': 'BGRA8Unorm'}
    for arg in (a for a in sys.argv[2:] if '=' in a):
        key, value = arg.split('=', 1)
        att[key] = {'true': True, 'false': False}.get(value, value)
    with tempfile.TemporaryDirectory() as tmp:
        work = pathlib.Path(tmp)
        air, lib = work / 'all.air', work / 'all.metallib'
        explore_render.run('xcrun', 'metal', '-target', 'air64-apple-ios17.0', '-c', str(src),
                           '-o', str(air))
        explore_render.run('xcrun', 'metallib', str(air), '-o', str(lib))
        for fs in names:
            script, out = work / f'{fs}.mtlp-json', work / f'{fs}.g9p.bin'
            script.write_text(json.dumps({'pipelines': {'render_pipelines': [{
                'vertex_function': 'vs', 'fragment_function': fs,
                'color_attachments': [att]}]}}))
            try:
                explore_render.run('xcrun', 'metal-tt', '-arch', 'applegpu_g9p', '-target',
                                   'air64-apple-ios17.0', str(lib), str(script), '-o', str(out))
            except subprocess.CalledProcessError:
                print(f'{fs}: compile failed', file=sys.stderr)
                continue
            for name, code in explore_render.functions(out.read_bytes()):
                print(f'{fs} [{name}]  ' +
                      ' '.join(f'{w:04x}' for w in explore_render.words(code)))


if __name__ == '__main__':
    main()
