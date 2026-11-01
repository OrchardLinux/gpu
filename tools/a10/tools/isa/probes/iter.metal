#include <metal_stdlib>
using namespace metal;
struct V { float4 pos [[position]]; float a; float b; float2 c; float4 d; float e; };
vertex V vs_v(uint vid [[vertex_id]], const device float4 *in [[buffer(0)]]) { V o; o.pos = in[vid]; o.a = in[vid+3].x; o.b = in[vid+4].x; o.c = in[vid+5].xy; o.d = in[vid+6]; o.e = in[vid+7].y; return o; }
// pair vs_v fs_a
fragment float4 fs_a(V v [[stage_in]]) { return float4(v.a, 0, 0, 1) * 3.0; }
// pair vs_v fs_b
fragment float4 fs_b(V v [[stage_in]]) { return float4(v.b, 0, 0, 1) * 3.0; }
// pair vs_v fs_c
fragment float4 fs_c(V v [[stage_in]]) { return float4(v.c, 0, 1) * 3.0; }
// pair vs_v fs_d
fragment float4 fs_d(V v [[stage_in]]) { return v.d * 3.0; }
// pair vs_v fs_e
fragment float4 fs_e(V v [[stage_in]]) { return float4(v.e, 0, 0, 1) * 3.0; }
// pair vs_v fs_all
fragment float4 fs_all(V v [[stage_in]]) { return float4(v.a, v.b, v.c.x + v.c.y, v.e) * v.d; }
