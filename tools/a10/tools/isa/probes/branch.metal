#include <metal_stdlib>
using namespace metal;
kernel void if_ueq(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0]; if (a == 7u) { o[0] = i[1]; } }
kernel void if_seq(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { int a = int(i[0]); if (a == 7) { o[0] = i[1]; } }
kernel void if_req(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0], b = i[2]; if (a == b) { o[0] = i[1]; } }
kernel void if_feq(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { float a = as_type<float>(i[0]); if (a == 7.0f) { o[0] = i[1]; } }
kernel void if_une(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0]; if (a != 7u) { o[0] = i[1]; } }
kernel void if_sne(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { int a = int(i[0]); if (a != 7) { o[0] = i[1]; } }
kernel void if_rne(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0], b = i[2]; if (a != b) { o[0] = i[1]; } }
kernel void if_fne(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { float a = as_type<float>(i[0]); if (a != 7.0f) { o[0] = i[1]; } }
kernel void if_ult(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0]; if (a < 7u) { o[0] = i[1]; } }
kernel void if_slt(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { int a = int(i[0]); if (a < 7) { o[0] = i[1]; } }
kernel void if_rlt(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0], b = i[2]; if (a < b) { o[0] = i[1]; } }
kernel void if_flt(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { float a = as_type<float>(i[0]); if (a < 7.0f) { o[0] = i[1]; } }
kernel void if_ule(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0]; if (a <= 7u) { o[0] = i[1]; } }
kernel void if_sle(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { int a = int(i[0]); if (a <= 7) { o[0] = i[1]; } }
kernel void if_rle(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0], b = i[2]; if (a <= b) { o[0] = i[1]; } }
kernel void if_fle(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { float a = as_type<float>(i[0]); if (a <= 7.0f) { o[0] = i[1]; } }
kernel void if_ugt(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0]; if (a > 7u) { o[0] = i[1]; } }
kernel void if_sgt(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { int a = int(i[0]); if (a > 7) { o[0] = i[1]; } }
kernel void if_rgt(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0], b = i[2]; if (a > b) { o[0] = i[1]; } }
kernel void if_fgt(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { float a = as_type<float>(i[0]); if (a > 7.0f) { o[0] = i[1]; } }
kernel void if_uge(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0]; if (a >= 7u) { o[0] = i[1]; } }
kernel void if_sge(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { int a = int(i[0]); if (a >= 7) { o[0] = i[1]; } }
kernel void if_rge(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0], b = i[2]; if (a >= b) { o[0] = i[1]; } }
kernel void if_fge(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { float a = as_type<float>(i[0]); if (a >= 7.0f) { o[0] = i[1]; } }
kernel void if_k0(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0]; if (a == 0u) { o[0] = i[1]; } }
kernel void if_k1(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0]; if (a == 1u) { o[0] = i[1]; } }
kernel void if_k2(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0]; if (a == 2u) { o[0] = i[1]; } }
kernel void if_k4(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0]; if (a == 4u) { o[0] = i[1]; } }
kernel void if_k8(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0]; if (a == 8u) { o[0] = i[1]; } }
kernel void if_k16(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0]; if (a == 16u) { o[0] = i[1]; } }
kernel void if_k32(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0]; if (a == 32u) { o[0] = i[1]; } }
kernel void if_k63(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0]; if (a == 63u) { o[0] = i[1]; } }
kernel void if_k64(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0]; if (a == 64u) { o[0] = i[1]; } }
kernel void if_k100(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0]; if (a == 100u) { o[0] = i[1]; } }
kernel void if_k1000(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0]; if (a == 1000u) { o[0] = i[1]; } }
kernel void if_k65536(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0]; if (a == 65536u) { o[0] = i[1]; } }
kernel void if_nest(device uint *o [[buffer(0)]], device const uint *i [[buffer(1)]]) { uint a = i[0], b = i[2]; if (a == 7u) { if (b == 9u) { o[0] = i[1]; } o[1] = a; } }
