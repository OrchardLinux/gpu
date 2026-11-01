#include <metal_stdlib>
using namespace metal;
struct V { float4 pos [[position]]; float4 col; };
vertex V vs_v(uint vid [[vertex_id]], const device float4 *in [[buffer(0)]]) { V o; o.pos = in[vid]; o.col = in[vid+3]; return o; }
// pair vs_v fs_d
fragment float4 fs_d(V v [[stage_in]]) { if (v.col.x < 0.5) discard_fragment(); return float4(0.25, 0.5, 0.75, 1.0); }
// pair vs_v fs_d2
fragment float4 fs_d2(V v [[stage_in]]) { if (v.col.y > v.col.x) discard_fragment(); return v.col; }
// pair vs_v fs_all
fragment float4 fs_all(V v [[stage_in]]) { discard_fragment(); return v.col; }
