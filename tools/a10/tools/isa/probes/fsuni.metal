#include <metal_stdlib>
using namespace metal;
// Fragment-shader uniforms as f32 operands (constant buffer read through the common store)
struct V { float4 pos [[position]]; float4 a; };
struct U { float4 c; float4 d; };
vertex V vs_v(uint vid [[vertex_id]], const device float4 *in [[buffer(0)]]) { V o; o.pos = in[vid]; o.a = in[vid + 3]; return o; }
// pair vs_v fs_mul
fragment float4 fs_mul(V v [[stage_in]], constant U &u [[buffer(0)]], device float *o [[buffer(1)]]) { o[0] = v.a.x * u.c.y; return float4(1.0); }
// pair vs_v fs_add
fragment float4 fs_add(V v [[stage_in]], constant U &u [[buffer(0)]], device float *o [[buffer(1)]]) { o[0] = v.a.x + u.d.z; return float4(1.0); }
// pair vs_v fs_mov
fragment float4 fs_mov(V v [[stage_in]], constant U &u [[buffer(0)]], device float *o [[buffer(1)]]) { o[0] = v.a.x < 0.5 ? u.c.x : u.d.w; return float4(1.0); }
// pair vs_v fs_fma
fragment float4 fs_fma(V v [[stage_in]], constant U &u [[buffer(0)]], device float *o [[buffer(1)]]) { o[0] = fma(v.a.x, u.c.z, u.d.x); return float4(1.0); }
