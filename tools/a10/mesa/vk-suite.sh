#!/bin/sh
# vk-tri regression suite (device chroot)
export PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1
chmod +x /usr/local/bin/vk-tri
for e in X=1 TRI_LINEAR=1 TRI_SIZE=1536x2048 TRI_TEX=1 TRI_TEX=linear "TRI_TEX=1 TRI_FILTER=linear" TRI_DISCARD=1 TRI_COORD=1; do
	r=$(env $e timeout -k 5 30 /usr/local/bin/vk-tri 2>&1 | grep -E "^(PASS|FAIL)" | tail -1)
	echo "$e: ${r:-NO RESULT}"
done
