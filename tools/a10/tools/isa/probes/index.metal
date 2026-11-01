#include <metal_stdlib>
using namespace metal;
kernel void st_l(device uint *o [[buffer(0)]], uint l [[thread_index_in_threadgroup]]) { o[l] = 5u; }
kernel void st_l1(device uint *o [[buffer(0)]], uint l [[thread_index_in_threadgroup]]) { o[l + 1u] = 5u; }
kernel void st_l7(device uint *o [[buffer(0)]], uint l [[thread_index_in_threadgroup]]) { o[l + 7u] = 5u; }
kernel void st_ll(device uint *o [[buffer(0)]], uint l [[thread_index_in_threadgroup]]) { o[l] = l; }
kernel void st_2l(device uint *o [[buffer(0)]], uint l [[thread_index_in_threadgroup]]) { o[l * 2u] = 5u; }
kernel void st_b1(device uint *o [[buffer(0)]], device uint *p [[buffer(1)]], uint l [[thread_index_in_threadgroup]]) { p[l] = 5u; }
kernel void ld_l(device uint *o [[buffer(0)]], device uint *p [[buffer(1)]], uint l [[thread_index_in_threadgroup]]) { o[0] = p[l]; }
kernel void cp_l(device uint *o [[buffer(0)]], device uint *p [[buffer(1)]], uint l [[thread_index_in_threadgroup]]) { o[l] = p[l]; }
kernel void st_u8(device uchar *o [[buffer(0)]], uint l [[thread_index_in_threadgroup]]) { o[l] = 5; }
kernel void st_u16(device ushort *o [[buffer(0)]], uint l [[thread_index_in_threadgroup]]) { o[l] = 5; }
kernel void st_u64(device ulong *o [[buffer(0)]], uint l [[thread_index_in_threadgroup]]) { o[l] = 5; }
kernel void ptr(device uint *o [[buffer(0)]], device uint * device *pp [[buffer(1)]], uint l [[thread_index_in_threadgroup]]) { pp[0][l] = 5u; }
