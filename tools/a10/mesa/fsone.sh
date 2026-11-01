#!/bin/sh
# Run each fragment op test separately, reloading the GPU after a hang
# (device host side): fsone.sh [TEST...]
cd /run/sid/root/fsops
tests=${*:-$(ls *.spv | sed 's/\.spv$//')}
for t in $tests; do
	want=$(grep -o "TRI_FS_SPV=$t.spv TRI_WANT=0x[0-9a-f]*" run.sh | sed 's/.*TRI_WANT=//')
	r=$(chroot /run/sid sh -c "cd /root/fsops; PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1 TRI_VCOL=0.25,0.5,0.75,1.0 TRI_FS_SPV=$t.spv TRI_WANT=$want timeout -k 5 20 /usr/local/bin/vk-tri 2>&1")
	case "$r" in
	*PASS*) echo "$t: PASS";;
	*vkWaitForFences*) echo "$t: HANG"; sh /run/gpu-reload.sh >/dev/null;;
	*corner*) echo "$t: FAIL want $want got $(echo "$r" | grep corner | head -1 | sed 's/.*: //')";;
	*) echo "$t: ERROR $(echo "$r" | grep -v '^MESA\|^WARNING' | grep -i 'g9p\|error\|fail' | head -2 | tr '\n' ' ')";;
	esac
done
