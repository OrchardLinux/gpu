#!/bin/busybox sh
# Render/compute stress through the powervr UAPI (RENDER.md, "Render jobs
# through the powervr UAPI"): the sequence that once crashed the firmware
# (renders, a compute job, renders), mixed rounds, then four concurrent
# submitters. Expects /run/pvr-render-test and /run/pvr-compute-test.
#
#   sh /run/uapi-stress.sh
chmod +x /run/pvr-render-test /run/pvr-compute-test
lsmod | grep -q powervr || modprobe powervr exp_hw_support=1
sleep 3
step() { echo "== $1"; shift; "$@" | tail -1 | sed 's/after [0-9.]* ms//'; }
for i in 1 2 3; do step render$i /run/pvr-render-test; done
step compute1 /run/pvr-compute-test
step render4 /run/pvr-render-test
for i in $(seq 1 10); do
    /run/pvr-render-test | tail -1; /run/pvr-compute-test | tail -1; /run/pvr-render-test | tail -1
done | sed 's/after [0-9.]* ms//' | sort | uniq -c
echo "== four concurrent submitters"
for p in 1 2 3 4; do
    (for i in $(seq 1 15); do /run/pvr-render-test | tail -1; /run/pvr-compute-test | tail -1; done > /run/par$p.log 2>&1) &
done
wait
cat /run/par*.log | sed 's/after [0-9.]* ms//' | sort | uniq -c
echo "crashes: $(dmesg | grep -c 'co-processor has crashed'), timeouts: $(dmesg | grep -c 'timed out\|did not retire')"
