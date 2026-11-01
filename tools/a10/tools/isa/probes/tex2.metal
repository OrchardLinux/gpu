#include <metal_stdlib>
using namespace metal;
struct V { float4 pos [[position]]; float2 uv; float2 uv2; };
vertex V vs_v(uint vid [[vertex_id]], const device float4 *in [[buffer(0)]]) { V o; o.pos = in[vid]; o.uv = in[vid+3].xy; o.uv2 = in[vid+3].zw; return o; }
// pair vs_v fs_t0
fragment float4 fs_t0(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { return t.sample(s, v.uv); }
// pair vs_v fs_t1
fragment float4 fs_t1(V v [[stage_in]], texture2d<float> t0 [[texture(0)]], texture2d<float> t [[texture(1)]], sampler s [[sampler(0)]]) { return t.sample(s, v.uv); }
// pair vs_v fs_s1
fragment float4 fs_s1(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s0 [[sampler(0)]], sampler s [[sampler(1)]]) { return t.sample(s, v.uv); }
// pair vs_v fs_f32
fragment float4 fs_f32(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { float4 c = t.sample(s, v.uv); return c * c.w + float4(v.uv2, 0, 0); }
// pair vs_v fs_two
fragment float4 fs_two(V v [[stage_in]], texture2d<float> t [[texture(0)]], texture2d<float> u [[texture(1)]], sampler s [[sampler(0)]]) { return t.sample(s, v.uv) * u.sample(s, v.uv2); }
// pair vs_v fs_math
fragment float4 fs_math(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { return t.sample(s, v.uv * 2.0 + 0.25); }
// pair vs_v fs_lod
fragment float4 fs_lod(V v [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { return t.sample(s, v.uv, level(0.0)); }
