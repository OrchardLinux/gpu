#include <metal_stdlib>
using namespace metal;
kernel void st(device uint *o [[buffer(0)]], uint g [[threadgroup_position_in_grid]]) { o[g] = g; }
kernel void st_tgdev(device uint *o [[buffer(0)]], uint g [[threadgroup_position_in_grid]]) { o[g] = g; threadgroup_barrier(mem_flags::mem_device); }
kernel void st_fence(device uint *o [[buffer(0)]], uint g [[threadgroup_position_in_grid]]) { o[g] = g; atomic_thread_fence(mem_flags::mem_device, memory_order_seq_cst, thread_scope_device); }
kernel void st_atomic(device atomic_uint *o [[buffer(0)]], uint g [[threadgroup_position_in_grid]]) { atomic_store_explicit(&o[g], g, memory_order_relaxed); }
kernel void st_simd(device uint *o [[buffer(0)]], uint g [[threadgroup_position_in_grid]]) { o[g] = g; simdgroup_barrier(mem_flags::mem_device); }
