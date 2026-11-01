#include <metal_stdlib>
using namespace metal;
// Fragment-shader f32 and integer ALU forms: each op's result stored to a
// device buffer so it stays 32-bit (fragment_ops in ISA.md)
struct V { float4 pos [[position]]; float4 a; float4 b; };
vertex V vs_v(uint vid [[vertex_id]], const device float4 *in [[buffer(0)]]) { V o; o.pos = in[vid]; o.a = in[vid + 3]; o.b = in[vid + 6]; return o; }
// pair vs_v fs_mul
fragment float4 fs_mul(V v [[stage_in]], device float *o [[buffer(1)]]) { o[0] = v.a.x * v.b.x; return float4(1.0); }
// pair vs_v fs_add
fragment float4 fs_add(V v [[stage_in]], device float *o [[buffer(1)]]) { o[0] = v.a.x + v.b.x; return float4(1.0); }
// pair vs_v fs_fma
fragment float4 fs_fma(V v [[stage_in]], device float *o [[buffer(1)]]) { o[0] = fma(v.a.x, v.b.x, v.a.y); return float4(1.0); }
// pair vs_v fs_rcp
fragment float4 fs_rcp(V v [[stage_in]], device float *o [[buffer(1)]]) { o[0] = 1.0 / v.a.x; return float4(1.0); }
// pair vs_v fs_floor
fragment float4 fs_floor(V v [[stage_in]], device float *o [[buffer(1)]]) { o[0] = floor(v.a.x); return float4(1.0); }
// pair vs_v fs_rsq
fragment float4 fs_rsq(V v [[stage_in]], device float *o [[buffer(1)]]) { o[0] = rsqrt(v.a.x); return float4(1.0); }
// pair vs_v fs_log
fragment float4 fs_log(V v [[stage_in]], device float *o [[buffer(1)]]) { o[0] = log2(v.a.x); return float4(1.0); }
// pair vs_v fs_exp
fragment float4 fs_exp(V v [[stage_in]], device float *o [[buffer(1)]]) { o[0] = exp2(v.a.x); return float4(1.0); }
// pair vs_v fs_sin
fragment float4 fs_sin(V v [[stage_in]], device float *o [[buffer(1)]]) { o[0] = sin(v.a.x); return float4(1.0); }
// pair vs_v fs_sel
fragment float4 fs_sel(V v [[stage_in]], device float *o [[buffer(1)]]) { o[0] = v.a.x < v.b.x ? v.a.y : v.b.y; return float4(1.0); }
// pair vs_v fs_iadd
fragment float4 fs_iadd(V v [[stage_in]], device int *o [[buffer(1)]]) { o[0] = as_type<int>(v.a.x) + as_type<int>(v.b.x); return float4(1.0); }
// pair vs_v fs_iaddimm
fragment float4 fs_iaddimm(V v [[stage_in]], device int *o [[buffer(1)]]) { o[0] = as_type<int>(v.a.x) + 5; return float4(1.0); }
// pair vs_v fs_shl
fragment float4 fs_shl(V v [[stage_in]], device int *o [[buffer(1)]]) { o[0] = as_type<int>(v.a.x) << as_type<int>(v.b.x); return float4(1.0); }
// pair vs_v fs_f2i
fragment float4 fs_f2i(V v [[stage_in]], device int *o [[buffer(1)]]) { o[0] = int(v.a.x); return float4(1.0); }
// pair vs_v fs_i2f
fragment float4 fs_i2f(V v [[stage_in]], device float *o [[buffer(1)]]) { o[0] = float(as_type<int>(v.a.x)); return float4(1.0); }
// pair vs_v fs_mulimm
fragment float4 fs_mulimm(V v [[stage_in]], device float *o [[buffer(1)]]) { o[0] = v.a.x * 3.0; return float4(1.0); }
// pair vs_v fs_max
fragment float4 fs_max(V v [[stage_in]], device float *o [[buffer(1)]]) { o[0] = max(v.a.x, v.b.x); return float4(1.0); }
