#include <metal_stdlib>
using namespace metal;
kernel void flt(device uint *o [[buffer(0)]], device float *p [[buffer(1)]]) { float a = p[0], b = p[1]; o[0] = a < b ? 7u : 9u; }
kernel void fge(device uint *o [[buffer(0)]], device float *p [[buffer(1)]]) { float a = p[0], b = p[1]; o[0] = a >= b ? 7u : 9u; }
kernel void u2f(device float *o [[buffer(0)]], device uint *p [[buffer(1)]]) { o[0] = float(p[0]); }
kernel void i2f(device float *o [[buffer(0)]], device int *p [[buffer(1)]]) { o[0] = float(p[0]); }
kernel void f2u(device uint *o [[buffer(0)]], device float *p [[buffer(1)]]) { o[0] = uint(p[0]); }
kernel void f2i(device int *o [[buffer(0)]], device float *p [[buffer(1)]]) { o[0] = int(p[0]); }
kernel void fmn(device float *o [[buffer(0)]], device float *p [[buffer(1)]]) { o[0] = fmin(p[0], p[1]); }
kernel void fmx(device float *o [[buffer(0)]], device float *p [[buffer(1)]]) { o[0] = fmax(p[0], p[1]); }
kernel void fsub(device float *o [[buffer(0)]], device float *p [[buffer(1)]]) { o[0] = p[0] - p[1]; }
kernel void fneg(device float *o [[buffer(0)]], device float *p [[buffer(1)]]) { o[0] = -p[0] * p[1]; }
kernel void fabs_(device float *o [[buffer(0)]], device float *p [[buffer(1)]]) { o[0] = fabs(p[0]) * p[1]; }
kernel void ushr(device uint *o [[buffer(0)]], device uint *p [[buffer(1)]]) { o[0] = p[0] >> p[1]; }
kernel void ishl(device uint *o [[buffer(0)]], device uint *p [[buffer(1)]]) { o[0] = p[0] << p[1]; }
kernel void ushr4(device uint *o [[buffer(0)]], device uint *p [[buffer(1)]]) { o[0] = p[0] >> 4u; }
kernel void ishr(device int *o [[buffer(0)]], device int *p [[buffer(1)]]) { o[0] = p[0] >> p[1]; }
kernel void ult(device uint *o [[buffer(0)]], device uint *p [[buffer(1)]]) { o[0] = p[0] < p[1] ? 1u : 0u; }
kernel void fsel(device float *o [[buffer(0)]], device float *p [[buffer(1)]]) { o[0] = p[0] < p[1] ? p[2] : p[3]; }
