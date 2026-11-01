#include <metal_stdlib>
using namespace metal;
kernel void tg_rw(device uint *o [[buffer(0)]], uint l [[thread_index_in_threadgroup]]) { threadgroup uint t[64]; t[l] = l * 3u; threadgroup_barrier(mem_flags::mem_threadgroup); o[l] = t[63u - l]; }
kernel void tg_st(device uint *o [[buffer(0)]], uint l [[thread_index_in_threadgroup]]) { threadgroup uint t[64]; t[l] = 5u; threadgroup_barrier(mem_flags::mem_threadgroup); o[0] = t[1]; }
kernel void tg_big(device uint *o [[buffer(0)]], uint l [[thread_index_in_threadgroup]]) { threadgroup uint t[1024]; t[l] = 5u; threadgroup_barrier(mem_flags::mem_threadgroup); o[0] = t[1000]; }
kernel void gid_tg(device uint *o [[buffer(0)]], uint g [[threadgroup_position_in_grid]], uint l [[thread_index_in_threadgroup]]) { threadgroup uint t[4]; t[l & 3u] = g; threadgroup_barrier(mem_flags::mem_threadgroup); o[g] = t[0]; }
kernel void gid3(device uint *o [[buffer(0)]], uint3 g [[threadgroup_position_in_grid]]) { o[0] = g.z; }
kernel void cst(device uint *o [[buffer(0)]], constant uint *c [[buffer(1)]]) { o[0] = c[3]; }
kernel void gidv(device uint *o [[buffer(0)]], uint g [[threadgroup_position_in_grid]]) { o[g] = g; }
kernel void tidg(device uint *o [[buffer(0)]], uint t [[thread_position_in_grid]]) { o[t] = t; }
