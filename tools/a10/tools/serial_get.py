#!/usr/bin/env python3
"""Download one device file over the USB shell, checking its SHA-256.

usage: serial_get.py PORT REMOTE LOCAL
Unlike a raw terminal capture, this refuses partial/corrupt transfers.
"""
import base64
import hashlib
from pathlib import Path
import re
import shlex
import subprocess
import sys


def decode_transfer(output):
    begin = '\n__GPU_B64_BEGIN__\n'
    end = '\n__GPU_B64_END__\n'
    body, suffix = output.split(begin, 1)[1].split(end, 1)
    encoded = ''.join(body.split())
    data = base64.b64decode(encoded, validate=True)
    expected = re.search(r'(?m)^([0-9a-f]{64})\s', suffix)
    if expected is None or hashlib.sha256(data).hexdigest() != expected[1]:
        raise ValueError('missing or mismatched device SHA-256')
    return data


def main():
    port, remote, local = sys.argv[1:4]
    remote = shlex.quote(remote)
    command = ("printf '\\n__GPU_B64_BEGIN__\\n'; base64 " + remote +
               "; printf '\\n__GPU_B64_END__\\n'; sha256sum " + remote)
    result = subprocess.run(
        [sys.executable, '-I', str(Path(__file__).with_name('serial_cmd.py')),
         port, command, '5', '120'], capture_output=True, text=True,
        check=True, timeout=130)
    data = decode_transfer(result.stdout)
    Path(local).write_bytes(data)
    print(f'{len(data)} bytes -> {local} (SHA-256 verified)')


if __name__ == '__main__':
    main()
