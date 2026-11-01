#include <metal_stdlib>
using namespace metal;
vertex float4 vs_p(uint vid [[vertex_id]], const device float4 *in [[buffer(0)]]) { return in[vid]; }
// pair vs_p fs_xy
fragment float4 fs_xy(float4 p [[position]]) { return float4(p.x * 0.01, p.y * 0.01, 0.0, 1.0); }
// pair vs_p fs_x
fragment float4 fs_x(float4 p [[position]]) { return float4(p.x * 0.01, 0.0, 0.0, 1.0); }
// pair vs_p fs_y
fragment float4 fs_y(float4 p [[position]]) { return float4(0.0, p.y * 0.01, 0.0, 1.0); }
// pair vs_p fs_zw
fragment float4 fs_zw(float4 p [[position]]) { return float4(p.z, p.w * 0.5, 0.0, 1.0); }
// pair vs_p fs_xf
fragment float4 fs_xf(float4 p [[position]], constant float &k [[buffer(0)]]) { return float4(p.x * k, p.y * k, p.x + p.y, 1.0); }
