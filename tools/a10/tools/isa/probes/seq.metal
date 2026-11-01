#include <metal_stdlib>
using namespace metal;
kernel void one(device uint *o [[buffer(0)]]) { o[0] = 0x11u; }
kernel void two(device uint *o [[buffer(0)]]) { o[0] = 0x11u; o[1] = 0x22u; }
kernel void three(device uint *o [[buffer(0)]]) { o[0] = 0x11u; o[1] = 0x22u; o[2] = 0x33u; }
kernel void two_bufs(device uint *o [[buffer(0)]], device uint *p [[buffer(1)]]) { o[0] = 0x11u; p[0] = 0x22u; }
kernel void off_far(device uint *o [[buffer(0)]]) { o[1000] = 0x11u; }
kernel void ushort_st(device ushort *o [[buffer(0)]]) { o[0] = 0x11; }
kernel void uchar_st(device uchar *o [[buffer(0)]]) { o[0] = 0x11; }
kernel void empty() {}
