#include <metal_stdlib>
using namespace metal;
kernel void br_flt(device uint *o [[buffer(0)]], device float *p [[buffer(1)]]) { if (p[0] < p[1]) o[0] = 7u; }
kernel void br_fle(device uint *o [[buffer(0)]], device float *p [[buffer(1)]]) { if (p[0] <= p[1]) o[0] = 7u; }
kernel void br_feq(device uint *o [[buffer(0)]], device float *p [[buffer(1)]]) { if (p[0] == p[1]) o[0] = 7u; }
kernel void br_fgt(device uint *o [[buffer(0)]], device float *p [[buffer(1)]]) { if (p[0] > p[1]) o[0] = 7u; }
kernel void br_ult(device uint *o [[buffer(0)]], device uint *p [[buffer(1)]]) { if (p[0] < p[1]) o[0] = 7u; }
kernel void br_ieq(device uint *o [[buffer(0)]], device uint *p [[buffer(1)]]) { if (p[0] == p[1]) o[0] = 7u; }
