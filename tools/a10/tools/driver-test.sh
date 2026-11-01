#!/bin/busybox sh
# Driver milestone 1 on the device: load powervr with its Apple A10 variant.
# Expected kernel log: "GFX firmware initialized", then (SELFTEST=1)
# "self-test: terminate-only compute job completed"; /dev/dri/renderD128.
# Do not load apple_gpu_iop.ko in the same boot: it matches the same node.
#
#   SELFTEST=1 WAIT=8 sh /run/driver-test.sh
set -u
lsmod | grep -q '^apple_gpu_iop' && { echo 'apple_gpu_iop is loaded; reboot first' >&2; exit 1; }
before=$(dmesg | wc -l)
modprobe powervr exp_hw_support=1 apple_selftest="${SELFTEST:-1}"
echo "MODPROBE_EXIT=$?"
sleep "${WAIT:-8}"
dmesg | tail -n +$((before + 1))
ls -la /dev/dri 2>&1
# Fender power state (Fender is always readable; RGX only while state is 1)
printf 'Fender state: '; devmem 0x201d01000 32
