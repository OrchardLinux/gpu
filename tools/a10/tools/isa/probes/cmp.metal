#include <metal_stdlib>
using namespace metal;
kernel void sel_ult(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0], b = i[1]; o[0] = a < b ? a : b; }
kernel void sel_ule(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0], b = i[1]; o[0] = a <= b ? a : b; }
kernel void sel_ugt(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0], b = i[1]; o[0] = a > b ? a : b; }
kernel void sel_eq(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0], b = i[1]; o[0] = a == b ? a : b; }
kernel void sel_ne(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0], b = i[1]; o[0] = a != b ? a : b; }
kernel void sel_slt(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { int a = int(i[0]), b = int(i[1]); o[0] = uint(a < b ? a : b); }
kernel void sel_flt(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { float a = as_type<float>(i[0]), b = as_type<float>(i[1]); o[0] = as_type<uint>(a < b ? a : b); }
kernel void sel_k(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0], b = i[1]; o[0] = a < b ? 0x11u : 0x22u; }
kernel void sel_abcd(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0], b = i[1], c = i[2], d = i[3]; o[0] = a < b ? c : d; }
kernel void cmp_bool(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0], b = i[1]; o[0] = uint(a < b); }
kernel void br_if(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0]; if (a == 7u) { o[0] = i[1]; o[1] = i[2]; } }
kernel void br_ifelse(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0]; if (a == 7u) { o[0] = i[1]; } else { o[1] = i[2]; } }
kernel void loop_n(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint n = i[0], s = 0; for (uint k = 0; k < n; k++) s += i[k + 1]; o[0] = s; }
kernel void loop_mul(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint n = i[0], s = 1; for (uint k = 0; k < n; k++) s *= 3u; o[0] = s; }
