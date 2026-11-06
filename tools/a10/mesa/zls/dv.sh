# dv.sh "ENV" CASE...: PR 6's depth-vk per case, waiting for idle
export PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1
d=/sys/devices/platform/soc/201000000.gpu/power/runtime_status
envs=$1; shift
for c in "$@"; do
B=$(dmesg | grep -c "resetting the GPU")
env $envs timeout -k 2 25 /tmp/depth-vk --case $c 2>&1 | grep -a -E '^case=|result=|refuses|rror|^runs' | cut -c1-210 | head -9
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do [ "$(cat $d)" = suspended ] && break; sleep 1; done
echo "--> $c resets+$(( $(dmesg | grep -c "resetting the GPU") - B )) [$envs]"
done
