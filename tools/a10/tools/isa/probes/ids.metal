#include <metal_stdlib>
using namespace metal;
kernel void tid(device uint *o [[buffer(0)]], uint t [[thread_position_in_grid]]) { o[t] = 0x55u; }
kernel void tidv(device uint *o [[buffer(0)]], uint t [[thread_position_in_grid]]) { o[t] = t; }
kernel void tid0(device uint *o [[buffer(0)]], uint t [[thread_position_in_grid]]) { o[0] = t; }
kernel void lid0(device uint *o [[buffer(0)]], uint t [[thread_position_in_threadgroup]]) { o[0] = t; }
kernel void gid0(device uint *o [[buffer(0)]], uint t [[threadgroup_position_in_grid]]) { o[0] = t; }
kernel void tid2y(device uint *o [[buffer(0)]], uint2 t [[thread_position_in_grid]]) { o[0] = t.y; }
kernel void tid2x(device uint *o [[buffer(0)]], uint2 t [[thread_position_in_grid]]) { o[0] = t.x; }
kernel void tgs(device uint *o [[buffer(0)]], uint t [[threads_per_threadgroup]]) { o[0] = t; }
kernel void simd(device uint *o [[buffer(0)]], uint t [[thread_index_in_simdgroup]]) { o[0] = t; }
kernel void arg2(device uint *o [[buffer(0)]], device uint *p [[buffer(1)]], device uint *q [[buffer(2)]]) { o[0] = 1u; p[0] = 2u; q[0] = 3u; }
