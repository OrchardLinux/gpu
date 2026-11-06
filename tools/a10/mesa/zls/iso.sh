cd ~/deqp/gles2; export PVR_I_WANT_A_BROKEN_VULKAN_DRIVER=1 MESA_LOADER_DRIVER_OVERRIDE=zink MESA_SHADER_CACHE_DISABLE=true EGL_PLATFORM=surfaceless ZINK_DEBUG=rp
d=/sys/devices/platform/soc/201000000.gpu/power/runtime_status
for e in "$@"; do
o=""
for t in fragment_ops.random.0 fragment_ops.random.7 clipping.polygon.multiple_0 clipping.line.line_attrib_clip fbo.render.shared_depthbuffer.tex2d_rgba_depth_component16 fbo.render.stencil.tex2d_rgba_stencil_index8; do
r=$(env $e timeout -k 2 12 ./deqp-gles2 --deqp-case=dEQP-GLES2.functional.$t --deqp-surface-type=pbuffer --deqp-surface-width=256 --deqp-surface-height=256 --deqp-gl-config-name=rgba8888d24s8ms0 --deqp-log-images=disable --deqp-log-shader-sources=disable --deqp-log-filename=/dev/null 2>&1 | grep -a -m1 -E '^  (Pass|Fail)' | cut -c3-6); o="$o $r"; done
echo "[$e]$o"
done
echo "tests: random.0 random.7 poly_multiple_0 line_attrib shared_depth stencil"
