#include <metal_stdlib>
using namespace metal;
vertex float4 tri_vs(uint vid [[vertex_id]]) {
    float2 p[3] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(0.0, 0.5) };
    return float4(p[vid], 0.0, 1.0);
}
fragment float4 tri_fs() { return float4(0.25, 0.5, 0.75, 1.0); }
