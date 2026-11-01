"""Copy a local file to the device's USB serial shell (base64 heredoc), verify by sha256.

usage: serial_put.py PORT LOCAL REMOTE
"""
import base64
import hashlib
import os
import select
import sys
import termios
import time
import tty

port, local, remote = sys.argv[1:4]
data = open(local, 'rb').read()
fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
tty.setraw(fd)


def drain(wait):
    out = b''
    end = time.monotonic() + wait
    while time.monotonic() < end:
        if select.select([fd], [], [], 0.05)[0]:
            try:
                out += os.read(fd, 65536)
            except BlockingIOError:
                pass
    return out


def send(text):
    blob = text.encode()
    i = 0
    while i < len(blob):
        try:
            i += os.write(fd, blob[i:i + 512])
        except BlockingIOError:
            # Port buffer full: let the device catch up, then retry.
            time.sleep(0.05)
        time.sleep(0.01)
        drain(0)


drain(0.3)
send(f"stty -echo; base64 -d > {remote} <<'__EOF__'\n")
encoded = base64.encodebytes(data).decode()
send(encoded)
send('__EOF__\nstty echo; sha256sum ' + remote + '\n')
reply = drain(2.0).decode(errors='replace')
expected = hashlib.sha256(data).hexdigest()
print('ok' if expected in reply else 'MISMATCH', expected[:16], len(data), 'bytes')
os.close(fd)
