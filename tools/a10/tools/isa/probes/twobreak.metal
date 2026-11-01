#include <metal_stdlib>
using namespace metal;
kernel void tb(device uint *o [[buffer(0)]], uint i [[thread_index_in_threadgroup]]) { uint k = 0u; for (; k < 100u; k++) { if (k * k >= i) break; if (k == 9u) break; } o[i] = k; }
