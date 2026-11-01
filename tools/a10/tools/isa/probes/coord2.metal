#include <metal_stdlib>
using namespace metal;
vertex float4 vs_p(uint vid [[vertex_id]], const device float4 *in [[buffer(0)]]) { return in[vid]; }
// pair vs_p fs_fx
fragment float4 fs_fx(float4 p [[position]], device float *o [[buffer(1)]]) { o[0] = p.x; return float4(1.0); }
// pair vs_p fs_fxy
fragment float4 fs_fxy(float4 p [[position]], device float *o [[buffer(1)]]) { o[0] = p.x; o[1] = p.y; return float4(1.0); }
// pair vs_p fs_h2f
fragment half4 fs_h2f(half4 c [[color(0)]], device float *o [[buffer(1)]]) { o[0] = float(c.x); return half4(1.0h); }
