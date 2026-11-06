set -e
cd /zls; which glslangValidator glslang gcc cc 2>/dev/null; ls /usr/include/vulkan/vulkan.h
G=$(which glslangValidator || which glslang)
$G -V --vn spv_color_frag -o /tmp/color.frag.h color.frag >/dev/null
$G -V --vn spv_color_vert -o /tmp/color.vert.h color.vert >/dev/null
gcc -O2 -I/tmp -o /zls/depth-vk depth-vk.c -lvulkan -lm 2>&1 | head -12
ls -la /zls/depth-vk
