#include <metal_stdlib>
using namespace metal;
kernel void t_floor(device float *o [[buffer(0)]], device float *p [[buffer(1)]]) { o[0] = floor(p[0]); }
kernel void t_sin(device float *o [[buffer(0)]], device float *p [[buffer(1)]]) { o[0] = precise::sin(p[0]); }
kernel void t_fsin(device float *o [[buffer(0)]], device float *p [[buffer(1)]]) { o[0] = fast::sin(p[0]); }
kernel void t_fcos(device float *o [[buffer(0)]], device float *p [[buffer(1)]]) { o[0] = fast::cos(p[0]); }
kernel void t_exp2(device float *o [[buffer(0)]], device float *p [[buffer(1)]]) { o[0] = fast::exp2(p[0]); }
kernel void t_log2(device float *o [[buffer(0)]], device float *p [[buffer(1)]]) { o[0] = fast::log2(p[0]); }
kernel void t_rsqrt(device float *o [[buffer(0)]], device float *p [[buffer(1)]]) { o[0] = fast::rsqrt(p[0]); }
kernel void t_sqrt(device float *o [[buffer(0)]], device float *p [[buffer(1)]]) { o[0] = fast::sqrt(p[0]); }
kernel void t_rcp(device float *o [[buffer(0)]], device float *p [[buffer(1)]]) { o[0] = fast::divide(1.0f, p[0]); }
kernel void t_fract(device float *o [[buffer(0)]], device float *p [[buffer(1)]]) { o[0] = fract(p[0]); }
kernel void t_sign(device float *o [[buffer(0)]], device float *p [[buffer(1)]]) { o[0] = sign(p[0]); }
