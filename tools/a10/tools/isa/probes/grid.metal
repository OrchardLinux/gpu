#include <metal_stdlib>
using namespace metal;
kernel void grid(device uint4 *o [[buffer(0)]], uint2 t [[thread_position_in_grid]], uint2 l [[thread_position_in_threadgroup]], uint2 g [[threadgroup_position_in_grid]], uint2 n [[threads_per_threadgroup]], uint2 s [[threads_per_grid]]) { uint i = t.y * s.x + t.x; o[2 * i] = uint4(t.x, t.y, l.x, l.y); o[2 * i + 1] = uint4(g.x, g.y, n.x | n.y << 16, s.x | s.y << 16); }
kernel void lidx(device uint *o [[buffer(0)]], uint l [[thread_index_in_threadgroup]]) { o[l] = l; }
kernel void lidx0(device uint *o [[buffer(0)]], uint l [[thread_index_in_threadgroup]]) { o[0] = l; }
kernel void gidx0(device uint *o [[buffer(0)]], uint g [[threadgroup_position_in_grid]]) { o[g] = 7u; }
