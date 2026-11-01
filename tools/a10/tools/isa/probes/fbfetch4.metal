#include <metal_stdlib>
using namespace metal;
struct V { float4 pos [[position]]; float4 col; };
vertex V vs(uint i [[vertex_id]], const device float4 *p [[buffer(0)]]) { V o; o.pos = p[i]; o.col = p[i+3]; return o; }
fragment float4 g4(V in [[stage_in]], float4 d [[color(0)]]) { return float4(sin(d.x), sin(d.y), sin(d.z), sin(d.w)); }
fragment float4 gw(V in [[stage_in]], float4 d [[color(0)]]) { return float4(sin(d.w), 0, 0, 1); }
fragment float4 gz(V in [[stage_in]], float4 d [[color(0)]]) { return float4(sin(d.z), 0, 0, 1); }
fragment float4 gy(V in [[stage_in]], float4 d [[color(0)]]) { return float4(sin(d.y), 0, 0, 1); }
