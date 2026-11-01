#!/usr/bin/env python3
"""Build gpu-capture and a palera1n overlay that carries it; optionally boot.

Reuses resize-apfs's palera1n discovery and HFS image helpers (RESIZE_APFS,
default ~/projects/OrchardLinux/resize-apfs). Boots with palera1n -T, which starts the
binpack's root telnetd on port 46: this is a development setup. Nothing runs at
boot; session.py drives the tool over telnet and a key-only dropbear.
"""
import argparse
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

HERE = pathlib.Path(__file__).resolve().parent
RESIZE = pathlib.Path(os.environ.get('RESIZE_APFS', '~/projects/OrchardLinux/resize-apfs')).expanduser()
sys.path.insert(0, str(RESIZE / 'scripts'))
from overlay_macos import image, run  # noqa: E402
from palera import discover  # noqa: E402

BUILD = HERE / 'build'


def build_tool():
    BUILD.mkdir(exist_ok=True)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
    tool = BUILD / 'gpu-capture'
    run('xcrun', '--sdk', 'iphoneos', 'clang', '-target', 'arm64-apple-ios16.0', '-isysroot', sdk,
        '-Os', '-fobjc-arc', '-framework', 'Foundation', '-framework', 'Metal',
        HERE / 'capture.m', '-o', tool)
    run('xcrun', '--sdk', 'iphoneos', 'strip', '-S', tool)
    run('ldid', f'-S{HERE / "entitlements.plist"}', tool)
    return tool


def build_overlay(tool, destination):
    with tempfile.TemporaryDirectory(prefix='overlay-', dir=BUILD) as temporary:
        scratch = pathlib.Path(temporary)
        base = scratch / 'base.dmg'
        run(sys.executable, RESIZE / 'scripts/extract-binpack.py', '--output', base)
        mount = scratch / 'mnt'
        mount.mkdir()
        run('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, base)
        try:
            stage = scratch / 'binpack'
            run('ditto', mount, stage)
        finally:
            run('hdiutil', 'detach', mount)
        target = stage / 'usr/bin/gpu-capture'
        shutil.copy2(tool, target)
        target.chmod(0o755)
        destination.unlink(missing_ok=True)
        image(stage, destination, 'GPUCaptureOverlay', scratch)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--boot', action='store_true', help='start palera1n with the overlay')
    args = parser.parse_args()
    overlay = BUILD / 'gpu-capture-overlay.dmg'
    build_overlay(build_tool(), overlay)
    info = discover()
    # -T: palera1n only starts the binpack's root telnetd (port 46) on request.
    argv = [info['path'], *info['rootlessArguments'], '-T', '--override-overlay', str(overlay)]
    print('Overlay:', overlay)
    print('Boot command:', ' '.join(argv))
    if args.boot:
        # Orchard's pattern (cli apple/boot.py): exploit to PongoOS only, then wait
        # for Pongo ourselves. palera1n's own 20 s download-mode wait gives up
        # and re-runs checkm8, so the cable replug A10 often needs lands in the
        # retry. The full boot then picks up the device already in Pongo.
        log = BUILD / 'palera1n-pongo.log'
        print('Booting PongoOS. Wait for the Apple logo; if it does not disappear '
              'after a few seconds, disconnect and reconnect the cable once.', flush=True)
        with log.open('wb') as out:
            subprocess.run([info['path'], '-p'], stdout=out, stderr=subprocess.STDOUT, timeout=120)
        orchard = HERE.parents[2] / 'orchard'
        deadline = time.monotonic() + 120
        while '"mode": "pongo"' not in subprocess.run([orchard, 'devices'], capture_output=True,
                                                      text=True).stdout:
            if time.monotonic() > deadline:
                sys.exit(f'PongoOS did not appear; no retry. Log: {log}')
            time.sleep(1)
        print('PongoOS up; booting iOS with the overlay.', flush=True)
        os.execv(argv[0], argv)
