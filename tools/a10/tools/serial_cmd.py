"""Send one command line to a USB serial shell; stream output live until idle.

Output is printed as it arrives, so a device crash still leaves the last lines.
usage: serial_cmd.py PORT 'command' [idle_seconds] [max_seconds]
"""
import os
import select
import sys
import termios
import time
import tty

port, line = sys.argv[1], sys.argv[2]
idle = float(sys.argv[3]) if len(sys.argv) > 3 else 3.0
limit = float(sys.argv[4]) if len(sys.argv) > 4 else 120.0
fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
tty.setraw(fd)
attrs = termios.tcgetattr(fd)
attrs[4] = attrs[5] = termios.B115200
termios.tcsetattr(fd, termios.TCSANOW, attrs)
try:
    while select.select([fd], [], [], 0.3)[0]:
        try:
            os.read(fd, 65536)
        except BlockingIOError:
            break
    os.write(fd, line.encode() + b'\n')
    start = last = time.monotonic()
    while time.monotonic() - start < limit and time.monotonic() - last < idle:
        if select.select([fd], [], [], 0.2)[0]:
            try:
                chunk = os.read(fd, 65536)
            except BlockingIOError:
                continue
            if chunk:
                sys.stdout.write(chunk.decode(errors='replace').replace('\r', ''))
                sys.stdout.flush()
                last = time.monotonic()
except OSError as error:
    print(f'\n[serial lost: {error}]', flush=True)
    sys.exit(1)
finally:
    try:
        os.close(fd)
    except OSError:
        pass
