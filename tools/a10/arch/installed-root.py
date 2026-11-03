#!/usr/bin/env python3
# Root side of apply-installed.sh, on the installed Omarchy A: install what it
# pushed to /tmp and switch the session to the GPU when the GPU is there.
# Idempotent: a second run changes nothing.
import os
import shutil
import subprocess

SESSION = '/usr/local/libexec/arch-ipad-login-session'
PICKER = '/usr/local/bin/omarchy-picker-process'
MARK = '# A10 GPU (gpu repo tools/a10/arch/apply-installed.sh)'

SESSION_ANCHOR = 'export LIBGL_ALWAYS_SOFTWARE=1 LIBSEAT_BACKEND=seatd MOZ_ENABLE_WAYLAND=1\n'
SESSION_BLOCK = MARK + '''
# With the GPU's render node and the fork's Vulkan driver: Labwc on wlroots'
# GLES2 renderer on Zink; otherwise pixman as above. The shell stays on Qt's
# software renderer (on the GPU it hung the A10, 2026-11-02).
if [[ -e /dev/dri/renderD128 && -e /usr/share/vulkan/icd.d/powervr_mesa_icd.json ]]; then
  export WLR_RENDERER=gles2 WLR_RENDER_DRM_DEVICE=/dev/dri/renderD128
  export MESA_LOADER_DRIVER_OVERRIDE=zink PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1
  unset LIBGL_ALWAYS_SOFTWARE
  for card in /sys/class/drm/card*; do
    [[ $(basename "$(readlink -f "$card/device/driver")") == apple-adbe ]] && export WLR_DRM_DEVICES=/dev/dri/${card##*/}
  done
fi
'''

PICKER_OLD = '''env -u QT_QUICK_BACKEND LIBGL_ALWAYS_SOFTWARE=1 QSG_RHI_BACKEND=opengl \\
  qs -p "$config" >"$runtime/omarchy-picker.log" 2>&1 9>&- &
'''
PICKER_NEW = MARK + '''
# On the GPU session (WLR_RENDERER=gles2) Mesa would pick Zink on the GPU,
# whose shader backend lacks derivatives yet: llvmpipe, named explicitly.
if [[ ${WLR_RENDERER:-} == gles2 ]]; then
  env -u QT_QUICK_BACKEND -u MESA_LOADER_DRIVER_OVERRIDE LIBGL_ALWAYS_SOFTWARE=1 \\
    GALLIUM_DRIVER=llvmpipe QSG_RHI_BACKEND=opengl \\
    qs -p "$config" >"$runtime/omarchy-picker.log" 2>&1 9>&- &
else
  env -u QT_QUICK_BACKEND LIBGL_ALWAYS_SOFTWARE=1 QSG_RHI_BACKEND=opengl \\
    qs -p "$config" >"$runtime/omarchy-picker.log" 2>&1 9>&- &
fi
'''

# The first switch drew the picker with the GPU (2026-11-02): no derivatives yet
PICKER_GPU_V1 = MARK + '''
# On the GPU session (WLR_RENDERER=gles2) the picker draws with the GPU.
if [[ ${WLR_RENDERER:-} == gles2 ]]; then
  env -u QT_QUICK_BACKEND QSG_RHI_BACKEND=opengl \\
    qs -p "$config" >"$runtime/omarchy-picker.log" 2>&1 9>&- &
else
  env -u QT_QUICK_BACKEND LIBGL_ALWAYS_SOFTWARE=1 QSG_RHI_BACKEND=opengl \\
    qs -p "$config" >"$runtime/omarchy-picker.log" 2>&1 9>&- &
fi
'''


def install(src, dst, mode):
    """A new file renamed over the old one: a running compositor keeps the
    driver it mapped (copying over it in place crashed Labwc, 2026-11-02)."""
    os.makedirs(os.path.dirname(dst), mode=0o755, exist_ok=True)
    temporary = dst + '.new'
    shutil.copyfile(src, temporary)
    os.chmod(temporary, mode)
    with open(temporary, 'rb') as f:
        os.fsync(f.fileno())
    os.replace(temporary, dst)
    os.remove(src)
    print('installed', dst)


def edit(path, old, new, previous=None):
    with open(path) as f:
        text = f.read()
    if previous and previous in text:
        text = text.replace(previous, new)
        with open(path, 'w') as f:
            f.write(text)
        print('updated', path)
        return
    if MARK in text:
        print('already switched', path)
        return
    if text.count(old) != 1:
        raise SystemExit(f'{path}: the expected lines are not there; not changed')
    os.makedirs('/var/backups', exist_ok=True)
    shutil.copy2(path, '/var/backups/' + os.path.basename(path) + '.orig')
    with open(path, 'w') as f:
        f.write(text.replace(old, new))
    print('switched', path)


os.umask(0o022)
install('/tmp/gfx-t8010.bin', '/usr/lib/firmware/apple/gfx-t8010.bin', 0o644)
install('/tmp/libvulkan_powervr_mesa.so', '/usr/lib/libvulkan_powervr_mesa.so', 0o755)
install('/tmp/powervr_mesa_icd.json', '/usr/share/vulkan/icd.d/powervr_mesa_icd.json', 0o644)
with open('/etc/modprobe.d/powervr-a10.conf', 'w') as f:
    f.write('# The A10 GPU is not in the kernel driver\'s supported list yet\n'
            'options powervr exp_hw_support=1\n')
os.chmod('/etc/modprobe.d/powervr-a10.conf', 0o644)
subprocess.run(['gpasswd', '-a', 'tablet', 'render'], check=True)
edit(SESSION, SESSION_ANCHOR, SESSION_ANCHOR + SESSION_BLOCK)
edit(PICKER, PICKER_OLD, PICKER_NEW, PICKER_GPU_V1)
os.remove('/tmp/gpu-installed-root.py')
# A DFU reset is a hard reset: without this, ext4's delayed allocation left
# every installed file empty at the next boot (2026-11-04).
os.sync()
print('done: log out and in')
