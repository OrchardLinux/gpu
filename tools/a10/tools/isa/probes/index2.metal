#include <metal_stdlib>
using namespace metal;
kernel void ix_ld(device uint *o [[buffer(0)]], device uint *p [[buffer(1)]], uint l [[thread_index_in_threadgroup]]) { uint a = p[0]; o[a] = l; }
kernel void ix_two(device uint *o [[buffer(0)]], device uint *p [[buffer(1)]], uint l [[thread_index_in_threadgroup]]) { uint a = p[0]; uint b = p[1]; o[a] = b; o[b] = a; }
kernel void ix_three(device uint *o [[buffer(0)]], device uint *p [[buffer(1)]], uint l [[thread_index_in_threadgroup]]) { uint a = p[0]; uint b = p[1]; uint c = p[2]; o[c] = a + b; o[a] = c; }
kernel void ix_b2(device uint *o [[buffer(0)]], device uint *p [[buffer(1)]], device uint *q [[buffer(2)]], uint l [[thread_index_in_threadgroup]]) { o[l] = p[l] + q[l]; }
