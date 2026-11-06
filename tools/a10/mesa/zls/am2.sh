export PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1
d=/sys/devices/platform/soc/201000000.gpu/power/runtime_status
for e in "$@"; do for c in stencil stencil128 reload reload16 size; do
env $e timeout -k 2 10 /tmp/depth-vk --case $c > /tmp/e.log 2>&1
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do [ "$(cat $d)" = suspended ] && break; sleep 1; done
echo "[$e] $c: $(grep -a -E 'job=[012]' /tmp/e.log | sed -E 's/.*job=([012]) result=([A-Z]+) bad=([0-9]+).*/\2 \3/; s/MISMATCH/M/; s/EXACT/ok/' | tr '\n' ';') ones $(grep -a -m1 '^ones' /tmp/e.log | cut -c6-40)"
done; done
