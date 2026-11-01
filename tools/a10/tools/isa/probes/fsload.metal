#include <metal_stdlib>
using namespace metal;
// Fragment-shader memory loads: from a device/constant buffer at a computed index
struct V { float4 pos [[position]]; float4 a; };
vertex V vs_v(uint vid [[vertex_id]], const device float4 *in [[buffer(0)]]) { V o; o.pos = in[vid]; o.a = in[vid + 3]; return o; }
// pair vs_v fs_dev
fragment float4 fs_dev(V v [[stage_in]], const device float *b [[buffer(0)]]) { return float4(b[int(v.a.x)], 0, 0, 1); }
// pair vs_v fs_dev4
fragment float4 fs_dev4(V v [[stage_in]], const device float4 *b [[buffer(0)]]) { return b[int(v.a.x)]; }
// pair vs_v fs_const
fragment float4 fs_const(V v [[stage_in]], constant float4 *b [[buffer(0)]]) { return b[int(v.a.x)]; }
// pair vs_v fs_fixed
fragment float4 fs_fixed(V v [[stage_in]], const device float4 *b [[buffer(0)]]) { return b[3] * v.a; }
