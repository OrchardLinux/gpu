# mx.sh CONFIG ENVSTR TEST...: one result per test, waits for GPU idle after each
cd ~/deqp/gles2; export PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1 MESA_LOADER_DRIVER_OVERRIDE=zink MESA_SHADER_CACHE_DISABLE=true EGL_PLATFORM=surfaceless ZINK_DEBUG=rp
d=/sys/devices/platform/soc/201000000.gpu/power/runtime_status
cfg=$1; envs=$2; shift 2
for t in "$@"; do
B=$(dmesg | grep -c "resetting the GPU")
r=$(env $envs G9P_DUMP=1 timeout -k 2 8 ./deqp-gles2 --deqp-case=dEQP-GLES2.functional.$t --deqp-surface-type=pbuffer --deqp-surface-width=64 --deqp-surface-height=64 --deqp-gl-config-name=$cfg --deqp-log-images=disable --deqp-log-shader-sources=disable --deqp-log-filename=/dev/null 2>&1 | grep -a -E '^  (Pass|Fail|NotSupp)|frag stream' | sed -E 's/^g9p: frag stream @0: ([0-9a-f]+ ){8}([0-9a-f]+).*/z\2/; s/^  //' | cut -c1-14 | tr '\n' ' ')
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do [ "$(cat $d)" = suspended ] && break; sleep 1; done
echo "resets+$(( $(dmesg | grep -c "resetting the GPU") - B )) [$r] $envs ${t##*.}"
done
