#include <metal_stdlib>
using namespace metal;
kernel void st_1357(device uint *o [[buffer(0)]]) { o[0] = 0x1357u; }
kernel void st_2468(device uint *o [[buffer(0)]]) { o[0] = 0x2468u; }
kernel void st_0(device uint *o [[buffer(0)]]) { o[0] = 0u; }
kernel void st_big(device uint *o [[buffer(0)]]) { o[0] = 0x12345678u; }
kernel void st_off1(device uint *o [[buffer(0)]]) { o[1] = 0x1357u; }
kernel void st_off5(device uint *o [[buffer(0)]]) { o[5] = 0x1357u; }
kernel void st_buf1(device uint *a [[buffer(0)]], device uint *o [[buffer(1)]]) { o[0] = 0x1357u; }
kernel void cp(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { o[0] = i[0]; }
kernel void add(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { o[0] = i[0] + i[1]; }
kernel void addi(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { o[0] = i[0] + 5u; }
kernel void sub(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { o[0] = i[0] - i[1]; }
kernel void mul(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { o[0] = i[0] * i[1]; }
kernel void andi(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { o[0] = i[0] & i[1]; }
kernel void ori(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { o[0] = i[0] | i[1]; }
kernel void xori(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { o[0] = i[0] ^ i[1]; }
kernel void shl(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { o[0] = i[0] << i[1]; }
kernel void fadd(device float *o [[buffer(0)]], device const float *i [[buffer(1)]]) { o[0] = i[0] + i[1]; }
kernel void fmul(device float *o [[buffer(0)]], device const float *i [[buffer(1)]]) { o[0] = i[0] * i[1]; }
kernel void ffma(device float *o [[buffer(0)]], device const float *i [[buffer(1)]]) { o[0] = fma(i[0], i[1], i[2]); }
kernel void tid(device uint *o [[buffer(0)]], uint t [[thread_position_in_grid]]) { o[t] = t; }
