#include <metal_stdlib>
using namespace metal;
kernel void s_lt(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0], b = i[1], c = i[2], d = i[3]; o[0] = a < b ? c : d; }
kernel void s_gt(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0], b = i[1], c = i[2], d = i[3]; o[0] = a > b ? c : d; }
kernel void s_eq(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0], b = i[1], c = i[2], d = i[3]; o[0] = a == b ? c : d; }
kernel void s_slt(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { int a = int(i[0]), b = int(i[1]); uint c = i[2], d = i[3]; o[0] = a < b ? c : d; }
kernel void s_two(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0], b = i[1], c = i[2], d = i[3]; o[0] = a < b ? c : d; o[1] = a < b ? d : c; }
kernel void s_kd(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0], b = i[1], d = i[3]; o[0] = a < b ? 5u : d; }
kernel void s_ck(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0], b = i[1], c = i[2]; o[0] = a < b ? c : 5u; }
kernel void s_ak(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0], c = i[2], d = i[3]; o[0] = a < 9u ? c : d; }
kernel void s_dst(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0], b = i[1], c = i[2], d = i[3]; uint r = a < b ? c : d; o[0] = r + a; o[1] = b; }
kernel void cnt(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint n = i[0], s = 0; for (uint k = 0; k < n; k++) s += k; o[0] = s; }
kernel void wloop(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint x = i[0]; while (x > 1u) x = (x & 1u) ? 3u * x + 1u : x >> 1; o[0] = x; }
kernel void brk(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint n = i[0], s = 0; for (uint k = 0; k < 100u; k++) { if (i[k] == n) break; s += 1u; } o[0] = s; }
