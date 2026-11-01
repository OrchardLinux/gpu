#include <metal_stdlib>
using namespace metal;
vertex float4 vs_p(uint vid [[vertex_id]], const device float4 *in [[buffer(0)]]) { return in[vid]; }
// pair vs_p fs_f32
fragment float4 fs_f32(float4 d [[color(0)]], constant float4 &c [[buffer(0)]]) { return d * c.x + c; }
// pair vs_p fs_x
fragment float4 fs_x(float4 d [[color(0)]], constant float4 &c [[buffer(0)]]) { return float4(d.x * c.y, d.y + c.z, d.z, d.w * c.x); }
// pair vs_p fs_ufp
fragment float4 fs_ufp(constant float4 &c [[buffer(0)]]) { return c * 2.0; }
