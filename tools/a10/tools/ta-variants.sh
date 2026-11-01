#!/bin/busybox sh
# Geometry bring-up: run apple_selftest=5 once per apple_ta_variant, reloading
# powervr in between (a reload resets the firmware and the TA).
#
#   sh /run/ta-variants.sh 17 1 4 5
set -u
for v in "$@"; do
    rmmod powervr 2>/dev/null
    before=$(dmesg | wc -l)
    modprobe powervr exp_hw_support=1 apple_selftest="${SELFTEST:-5}" apple_ta_variant="$v"
    sleep 5
    echo "=== variant $v"
    dmesg | tail -n +$((before + 1)) | grep -E 'self-test|empty:|crash|WARN'
done
