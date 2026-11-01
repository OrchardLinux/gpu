#include <metal_stdlib>
using namespace metal;
// Fragment-shader control flow: divergent if/else, a select, a loop
struct V { float4 pos [[position]]; float4 a; };
vertex V vs_v(uint vid [[vertex_id]], const device float4 *in [[buffer(0)]]) { V o; o.pos = in[vid]; o.a = in[vid + 3]; return o; }
// pair vs_v fs_if
fragment float4 fs_if(V v [[stage_in]], device float *o [[buffer(1)]]) { float r; if (v.a.x < v.a.y) { r = sin(v.a.z); } else { r = cos(v.a.w); } o[0] = r; return float4(1.0); }
// pair vs_v fs_csel
fragment float4 fs_csel(V v [[stage_in]], device float *o [[buffer(1)]]) { o[0] = v.a.x < v.a.y ? v.a.z : v.a.w; return float4(1.0); }
// pair vs_v fs_loop
fragment float4 fs_loop(V v [[stage_in]], device float *o [[buffer(1)]]) { float r = 0; for (int k = 0; k < int(v.a.x); k++) r += v.a.y; o[0] = r; return float4(1.0); }
// pair vs_v fs_ifcol
fragment float4 fs_ifcol(V v [[stage_in]]) { float4 c = v.a; if (v.a.x < 0.5) { c = c * c.w + 0.25; } return c; }
