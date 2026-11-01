#include <metal_stdlib>
using namespace metal;
kernel void gid2(device uint *o [[buffer(0)]], uint2 g [[threadgroup_position_in_grid]]) { uint i = g.y * 16u + g.x; o[i] = i; }
kernel void gid3(device uint *o [[buffer(0)]], uint3 g [[threadgroup_position_in_grid]]) { uint i = (g.z * 4u + g.y) * 16u + g.x; o[i] = i; }
