#include <metal_stdlib>
using namespace metal;
struct V { float4 pos [[position]]; float4 col; };
vertex V vs(uint i [[vertex_id]], const device float4 *p [[buffer(0)]]) { V o; o.pos = p[i]; o.col = p[i+3]; return o; }
fragment float4 fs(V in [[stage_in]]) { return in.col; }
// explore-blend.py blend.metal fs [blending_enabled=true ...]: the blend Apple appends
