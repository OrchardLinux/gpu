# pv.sh CASE "ENV" ...: job 0 of depth-vk per env: bytes written
export PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1
d=/sys/devices/platform/soc/201000000.gpu/power/runtime_status
c=$1; shift
for e in "$@"; do
B=$(dmesg | grep -c "resetting the GPU")
o=$(env $e timeout -k 2 12 /tmp/depth-vk --case $c 2>&1 | grep -a -m1 "job=0")
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do [ "$(cat $d)" = suspended ] && break; sleep 1; done
echo "resets+$(( $(dmesg | grep -c "resetting the GPU") - B )) $(echo "$o" | sed -E 's/.*result=([A-Z]+).*ms=([0-9.]+)runs:(.*)\| runs ([0-9]+) bytes ([0-9]+) of ([0-9]+).*/\1 \2ms bytes=\5\/\6 runs=\4 \3/' | cut -c1-90) [$e]"
done
