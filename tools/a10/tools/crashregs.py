"""Fetch the GPU firmware crashlog over serial, save it, print strings and CrgA registers.

usage: crashregs.py PORT OUTFILE
"""
import base64, re, struct, subprocess, sys
port, out = sys.argv[1:3]
here = __file__.rsplit('/', 1)[0]
text = subprocess.run([sys.executable, '-I', here + '/serial_cmd.py', port,
                       'echo ===B64===; base64 /sys/kernel/debug/apple_gpu_iop/crashlog; echo ===END===', '4', '60'],
                      capture_output=True, text=True).stdout
body = text.split('===B64===', 2)[-1].split('===END===')[0]
data = base64.b64decode(''.join(l.strip() for l in body.splitlines() if re.fullmatch(r'[A-Za-z0-9+/=]+', l.strip() or '-')))
open(out, 'wb').write(data)
print(len(data), 'bytes ->', out)
for m in re.finditer(rb'[\x20-\x7e]{8,}', data):
    s = m.group().decode()
    if not s.startswith(('RTKit', 'agx_', 'rtk_')):
        print('  str', s)
i = data.find(b'AgrC')
if i >= 0:
    w = struct.unpack_from('<19I', data, i + 16)
    names = [f'r{n}' for n in range(13)] + ['sp', 'lr', 'pc', 'cpsr']
    print('CrgA type', hex(w[0]), ' '.join(f'{n}={v:#x}' for n, v in zip(names, w[2:])))
