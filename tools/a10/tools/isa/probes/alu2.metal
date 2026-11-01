#include <metal_stdlib>
using namespace metal;
kernel void add_0_1(device uint *o [[buffer(0)]], device const uint4 *i [[buffer(1)]]) { uint4 v = i[0], w = i[1]; uint a[8] = {v.x, v.y, v.z, v.w, w.x, w.y, w.z, w.w}; o[0] = a[0] + a[1]; }
kernel void add_0_3(device uint *o [[buffer(0)]], device const uint4 *i [[buffer(1)]]) { uint4 v = i[0], w = i[1]; uint a[8] = {v.x, v.y, v.z, v.w, w.x, w.y, w.z, w.w}; o[0] = a[0] + a[3]; }
kernel void add_0_6(device uint *o [[buffer(0)]], device const uint4 *i [[buffer(1)]]) { uint4 v = i[0], w = i[1]; uint a[8] = {v.x, v.y, v.z, v.w, w.x, w.y, w.z, w.w}; o[0] = a[0] + a[6]; }
kernel void add_1_0(device uint *o [[buffer(0)]], device const uint4 *i [[buffer(1)]]) { uint4 v = i[0], w = i[1]; uint a[8] = {v.x, v.y, v.z, v.w, w.x, w.y, w.z, w.w}; o[0] = a[1] + a[0]; }
kernel void add_1_3(device uint *o [[buffer(0)]], device const uint4 *i [[buffer(1)]]) { uint4 v = i[0], w = i[1]; uint a[8] = {v.x, v.y, v.z, v.w, w.x, w.y, w.z, w.w}; o[0] = a[1] + a[3]; }
kernel void add_1_6(device uint *o [[buffer(0)]], device const uint4 *i [[buffer(1)]]) { uint4 v = i[0], w = i[1]; uint a[8] = {v.x, v.y, v.z, v.w, w.x, w.y, w.z, w.w}; o[0] = a[1] + a[6]; }
kernel void add_2_0(device uint *o [[buffer(0)]], device const uint4 *i [[buffer(1)]]) { uint4 v = i[0], w = i[1]; uint a[8] = {v.x, v.y, v.z, v.w, w.x, w.y, w.z, w.w}; o[0] = a[2] + a[0]; }
kernel void add_2_1(device uint *o [[buffer(0)]], device const uint4 *i [[buffer(1)]]) { uint4 v = i[0], w = i[1]; uint a[8] = {v.x, v.y, v.z, v.w, w.x, w.y, w.z, w.w}; o[0] = a[2] + a[1]; }
kernel void add_2_3(device uint *o [[buffer(0)]], device const uint4 *i [[buffer(1)]]) { uint4 v = i[0], w = i[1]; uint a[8] = {v.x, v.y, v.z, v.w, w.x, w.y, w.z, w.w}; o[0] = a[2] + a[3]; }
kernel void add_2_6(device uint *o [[buffer(0)]], device const uint4 *i [[buffer(1)]]) { uint4 v = i[0], w = i[1]; uint a[8] = {v.x, v.y, v.z, v.w, w.x, w.y, w.z, w.w}; o[0] = a[2] + a[6]; }
kernel void add_4_0(device uint *o [[buffer(0)]], device const uint4 *i [[buffer(1)]]) { uint4 v = i[0], w = i[1]; uint a[8] = {v.x, v.y, v.z, v.w, w.x, w.y, w.z, w.w}; o[0] = a[4] + a[0]; }
kernel void add_4_1(device uint *o [[buffer(0)]], device const uint4 *i [[buffer(1)]]) { uint4 v = i[0], w = i[1]; uint a[8] = {v.x, v.y, v.z, v.w, w.x, w.y, w.z, w.w}; o[0] = a[4] + a[1]; }
kernel void add_4_3(device uint *o [[buffer(0)]], device const uint4 *i [[buffer(1)]]) { uint4 v = i[0], w = i[1]; uint a[8] = {v.x, v.y, v.z, v.w, w.x, w.y, w.z, w.w}; o[0] = a[4] + a[3]; }
kernel void add_4_6(device uint *o [[buffer(0)]], device const uint4 *i [[buffer(1)]]) { uint4 v = i[0], w = i[1]; uint a[8] = {v.x, v.y, v.z, v.w, w.x, w.y, w.z, w.w}; o[0] = a[4] + a[6]; }
kernel void add_7_0(device uint *o [[buffer(0)]], device const uint4 *i [[buffer(1)]]) { uint4 v = i[0], w = i[1]; uint a[8] = {v.x, v.y, v.z, v.w, w.x, w.y, w.z, w.w}; o[0] = a[7] + a[0]; }
kernel void add_7_1(device uint *o [[buffer(0)]], device const uint4 *i [[buffer(1)]]) { uint4 v = i[0], w = i[1]; uint a[8] = {v.x, v.y, v.z, v.w, w.x, w.y, w.z, w.w}; o[0] = a[7] + a[1]; }
kernel void add_7_3(device uint *o [[buffer(0)]], device const uint4 *i [[buffer(1)]]) { uint4 v = i[0], w = i[1]; uint a[8] = {v.x, v.y, v.z, v.w, w.x, w.y, w.z, w.w}; o[0] = a[7] + a[3]; }
kernel void add_7_6(device uint *o [[buffer(0)]], device const uint4 *i [[buffer(1)]]) { uint4 v = i[0], w = i[1]; uint a[8] = {v.x, v.y, v.z, v.w, w.x, w.y, w.z, w.w}; o[0] = a[7] + a[6]; }
kernel void umin(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { o[0] = min(i[0], i[1]); }
kernel void fmin(device float *o [[buffer(0)]], device const float *i [[buffer(1)]]) { o[0] = min(i[0], i[1]); }
kernel void umax(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { o[0] = max(i[0], i[1]); }
kernel void fmax(device float *o [[buffer(0)]], device const float *i [[buffer(1)]]) { o[0] = max(i[0], i[1]); }
kernel void shr(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { o[0] = i[0] >> i[1]; }
kernel void ashr(device int *o [[buffer(0)]], device const int *i [[buffer(1)]]) { o[0] = i[0] >> i[1]; }
kernel void shlr(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { o[0] = i[0] << (i[1] & 31u); }
kernel void sel(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { o[0] = i[0] < i[1] ? i[2] : i[3]; }
kernel void fsel(device float *o [[buffer(0)]], device const float *i [[buffer(1)]]) { o[0] = i[0] < i[1] ? i[2] : i[3]; }
kernel void i2f(device float *o [[buffer(0)]], device const int *i [[buffer(1)]]) { o[0] = float(i[0]); }
kernel void f2i(device int *o [[buffer(0)]], device const float *i [[buffer(1)]]) { o[0] = int(i[0]); }
kernel void u2f(device float *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { o[0] = float(i[0]); }
kernel void fneg(device float *o [[buffer(0)]], device const float *i [[buffer(1)]]) { o[0] = -i[0]; }
kernel void fabs_(device float *o [[buffer(0)]], device const float *i [[buffer(1)]]) { o[0] = fabs(i[0]); }
kernel void frcp(device float *o [[buffer(0)]], device const float *i [[buffer(1)]]) { o[0] = 1.0f / i[0]; }
kernel void fsqrt(device float *o [[buffer(0)]], device const float *i [[buffer(1)]]) { o[0] = sqrt(i[0]); }
kernel void fexp2(device float *o [[buffer(0)]], device const float *i [[buffer(1)]]) { o[0] = exp2(i[0]); }
kernel void flog2(device float *o [[buffer(0)]], device const float *i [[buffer(1)]]) { o[0] = log2(i[0]); }
