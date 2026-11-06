# zs.sh TEST ENV... : for each ZOR value, written bytes and resets; waits for idle
cd ~/deqp/gles2; export PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1 MESA_LOADER_DRIVER_OVERRIDE=zink MESA_SHADER_CACHE_DISABLE=true EGL_PLATFORM=surfaceless ZINK_DEBUG=rp G9P_T_DUMPZ=1 G9P_T_FILL=1
d=/sys/devices/platform/soc/201000000.gpu/power/runtime_status
t=$1; base=$2; shift 2
for z in "$@"; do
B=$(dmesg | grep -c "resetting the GPU")
env $base G9P_T_ZOR=$z timeout -k 2 8 ./deqp-gles2 --deqp-case=dEQP-GLES2.functional.$t --deqp-surface-type=pbuffer --deqp-surface-width=64 --deqp-surface-height=64 --deqp-gl-config-name=rgba8888d0s0ms0 --deqp-log-images=disable --deqp-log-shader-sources=disable --deqp-log-filename=/dev/null > /tmp/z.log 2>&1
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do [ "$(cat $d)" = suspended ] && break; sleep 1; done
echo "ZOR=$z resets+$(( $(dmesg | grep -c "resetting the GPU") - B )) $(grep -a -E '^  (Pass|Fail) ' /tmp/z.log | head -1 | cut -c3-7) $(grep -a -oE 'sentinel a5 [0-9]+ ff [0-9]+ of [0-9]+' /tmp/z.log | head -1) | $(grep -a '^dumpz runs' /tmp/z.log | head -1 | cut -c12-70)"
done
