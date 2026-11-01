#include <metal_stdlib>
using namespace metal;
struct V { float4 pos [[position]]; float4 col; float2 uv; };
vertex V vs_plain(uint vid [[vertex_id]], const device float4 *in [[buffer(0)]]) { V o; o.pos = in[vid]; o.col = in[vid + 3]; o.uv = in[vid + 6].xy; return o; }
// pair vs_plain fs_const
fragment float4 fs_const() { return float4(0.25, 0.5, 0.75, 1.0); }
// pair vs_plain fs_col
fragment float4 fs_col(V v [[stage_in]]) { return v.col; }
// pair vs_plain fs_uv
fragment float4 fs_uv(V v [[stage_in]]) { return float4(v.uv, 0.0, 1.0); }
// pair vs_plain fs_tex
fragment float4 fs_tex(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { return t.sample(s, v.uv); }
// pair vs_plain fs_coord
fragment float4 fs_coord(float4 p [[position]]) { return float4(p.x * 0.01, p.y * 0.01, 0.0, 1.0); }
