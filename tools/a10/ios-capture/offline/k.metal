#include <metal_stdlib>
using namespace metal;
kernel void store_marker(device uint *out [[buffer(0)]]) { out[0] = 0x1357u; }
kernel void empty_kernel() {}
