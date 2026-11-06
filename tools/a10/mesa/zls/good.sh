cd ~/deqp/gles2; export PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1 MESA_LOADER_DRIVER_OVERRIDE=zink MESA_SHADER_CACHE_DISABLE=true EGL_PLATFORM=surfaceless ZINK_DEBUG=rp
for t in fbo.render.depth.tex2d_rgba_depth_component16 texture.vertex.cube.wrap.clamp_clamp fbo.render.stencil.tex2d_rgba_stencil_index8; do
B=$(dmesg | grep -c "resetting the GPU")
r=$(timeout -k 3 14 ./deqp-gles2 --deqp-case=dEQP-GLES2.functional.$t --deqp-surface-type=pbuffer --deqp-surface-width=256 --deqp-surface-height=256 --deqp-gl-config-name=rgba8888d24s8ms0 --deqp-log-images=disable --deqp-log-shader-sources=disable --deqp-log-filename=/dev/null 2>&1 | grep -a -E '^  (Pass|Fail)' | head -1 | cut -c3-22)
echo "$r|new resets $(( $(dmesg | grep -c "resetting the GPU") - B ))|$t"
done
