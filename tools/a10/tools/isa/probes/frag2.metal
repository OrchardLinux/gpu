#include <metal_stdlib>
using namespace metal;
struct V { float4 pos [[position]]; float4 col; float2 uv; };
struct C { float4 c; };
vertex V vs_plain(uint vid [[vertex_id]], const device float4 *in [[buffer(0)]]) { V o; o.pos = in[vid]; o.col = in[vid + 3]; o.uv = in[vid + 6].xy; return o; }
// pair vs_plain fs_half
fragment float4 fs_half(V v [[stage_in]]) { return v.col * 0.5; }
// pair vs_plain fs_x
fragment float4 fs_x(V v [[stage_in]]) { return float4(v.col.x * v.col.y, v.col.z + 0.25, 0.0, 1.0); }
// pair vs_plain fs_buf
fragment float4 fs_buf(constant C &c [[buffer(0)]]) { return c.c; }
// pair vs_plain fs_buf2
fragment float4 fs_buf2(constant C &c [[buffer(0)]], V v [[stage_in]]) { return c.c * v.col.x; }
// pair vs_plain fs_one
fragment float4 fs_one(V v [[stage_in]]) { return float4(v.col.x, 0.0, 0.0, 1.0); }
