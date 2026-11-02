#!/usr/bin/env python3
"""Drive a palera1n-booted iPad over USB: install an SSH key through the
binpack's root telnetd (palera1n -T), start a key-only dropbear on port 2222,
then run commands or pull the capture over SSH.

  session.py shell 'uname -a'        # any root command
  session.py capture                 # run gpu-capture, copy to ../out/ios-capture
  session.py render [VARIANT...]     # render variants (capture.m kVariants), to ../out/ios-render/
  session.py grid                    # install build/gpu-capture, run --grid, to ../out/ios-grid
"""
import os
import pathlib
import socket
import shutil
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
KEY = HERE / 'build/id_ed25519'
TELNET, SSH = 4646, 4444  # local ports -> device 46 (telnetd), 2222 (our dropbear)
OUT = HERE.parent / 'out/ios-capture'
RENDER_OUT = HERE.parent / 'out/ios-render'
GRID_OUT = HERE.parent / 'out/ios-grid2'
VARIANTS = ('base', 'base2', 'verts6', 'draws2', 'size128x32', 'clear', 'load', 'color')
UDID = os.environ.get('UDID')  # the iPad's UDID (idevice_id -l); required when several devices are attached


def proxies():
    procs = [subprocess.Popen(['iproxy', *(['-u', UDID] if UDID else []), f'{local}:{remote}'], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL) for local, remote in ((TELNET, 46), (SSH, 2222))]
    time.sleep(1)
    return procs


def telnet(command, wait=2.0):
    """Run one line in the root telnet shell, refusing every option negotiation."""
    s = socket.create_connection(('127.0.0.1', TELNET), timeout=5)
    s.settimeout(0.5)
    out = b''
    end = time.time() + wait
    sent = False
    while time.time() < end:
        try:
            data = s.recv(4096)
        except socket.timeout:
            data = b''
        i = 0
        while i < len(data):
            if data[i] == 255 and i + 2 < len(data) and data[i + 1] in (251, 252, 253, 254):
                reply = 252 if data[i + 1] in (253, 254) else 254  # DO/DONT -> WONT, WILL/WONT -> DONT
                s.sendall(bytes([255, reply, data[i + 2]]))
                i += 3
                continue
            out += data[i:i + 1]
            i += 1
        if not sent and time.time() > end - wait + 0.8:
            s.sendall(command.encode() + b'\r\n')
            sent = True
    s.close()
    return out.decode(errors='replace')


def ssh(*args, **kw):
    return subprocess.run(['ssh', '-p', str(SSH), '-i', str(KEY), '-o', 'StrictHostKeyChecking=no',
                           '-o', 'UserKnownHostsFile=/dev/null', '-o', 'LogLevel=ERROR',
                           'root@127.0.0.1', *args], **kw)


def ensure_key():
    if not KEY.exists():
        KEY.parent.mkdir(exist_ok=True)
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(KEY)], check=True)
    if ssh('true', stdin=subprocess.DEVNULL, capture_output=True).returncode == 0:
        return
    pub = (KEY.with_suffix('.pub')).read_text().strip()
    print(telnet(f"mkdir -p /var/root/.ssh && chmod 700 /var/root/.ssh && echo '{pub}' >> "
                 "/var/root/.ssh/authorized_keys && chmod 600 /var/root/.ssh/authorized_keys && echo KEY-OK"))
    # Key-only, loopback-only (reached through usbmux); host key generated on demand.
    print(telnet('/cores/binpack/usr/sbin/dropbear -R -s -g -p 127.0.0.1:2222 -P /var/run/gpu-dropbear.pid && echo SSHD-OK'))
    time.sleep(1)
    ssh('true', stdin=subprocess.DEVNULL, check=True)


if __name__ == '__main__':
    procs = proxies()
    try:
        ensure_key()
        if sys.argv[1] == 'shell':
            sys.exit(ssh(' '.join(sys.argv[2:])).returncode)
        if sys.argv[1] == 'capture':
            ssh('gpu-capture /var/tmp/gpu-capture', check=True)
            OUT.mkdir(parents=True, exist_ok=True)
            with subprocess.Popen(['tar', '-C', str(OUT), '-xf', '-'], stdin=subprocess.PIPE) as tar:
                ssh('tar -C /var/tmp/gpu-capture -cf - .', stdout=tar.stdin, check=True)
                tar.stdin.close()
            print('Capture in', OUT)
        if sys.argv[1] == 'grid':
            tool = '/var/tmp/gpu-capture-grid'
            with open(HERE / 'build/gpu-capture', 'rb') as f:
                ssh(f'cat > {tool} && chmod 755 {tool}', stdin=f, check=True)
            ssh(f'rm -rf /var/tmp/gpu-grid; {tool} --grid /var/tmp/gpu-grid')
            GRID_OUT.mkdir(parents=True, exist_ok=True)
            with subprocess.Popen(['tar', '-C', str(GRID_OUT), '-xf', '-'], stdin=subprocess.PIPE) as tar:
                ssh('tar -C /var/tmp/gpu-grid -cf - .', stdout=tar.stdin, check=True)
                tar.stdin.close()
            print('Grid capture in', GRID_OUT)
        if sys.argv[1] == 'render':
            tool = '/var/tmp/gpu-capture-render'
            with open(HERE / 'build/gpu-capture', 'rb') as f:
                ssh(f'cat > {tool} && chmod 755 {tool}', stdin=f, check=True)
            # GC_INSTANCES / GC_REPEAT pass through to the tool (capture.m); the
            # output directory carries them: instanced-i10-r100
            env = ' '.join(f'{k}={os.environ[k]}' for k in ('GC_INSTANCES', 'GC_REPEAT') if k in os.environ)
            suffix = ''.join(f'-{k[3].lower()}{os.environ[k]}' for k in ('GC_INSTANCES', 'GC_REPEAT')
                             if k in os.environ)
            for variant in sys.argv[2:] or VARIANTS:
                remote = f'/var/tmp/gpu-render-{variant}{suffix}'
                # The tool may die after the submit; the snapshot is saved first.
                ssh(f'{env} {tool} --render {remote} {variant}')
                out = RENDER_OUT / (variant + suffix)
                # a fresh directory: older runs' regions would mix in
                shutil.rmtree(out, ignore_errors=True)
                out.mkdir(parents=True, exist_ok=True)
                with subprocess.Popen(['tar', '-C', str(out), '-xf', '-'], stdin=subprocess.PIPE) as tar:
                    ssh(f'tar -C {remote} -cf - .', stdout=tar.stdin, check=True)
                    tar.stdin.close()
                print('Render capture in', out)
    finally:
        for p in procs:
            p.terminate()
