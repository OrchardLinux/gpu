// SPDX-License-Identifier: MIT
// Generated-by: LLM
// a8-passcap's shaders (iOS 12, Metal 2.1): one triangle per pass; the fragment stage varies only where the pass
// needs it (MRT, integer target, texture sample forms the A8 Mesa refuses).
#include <metal_stdlib>
using namespace metal;

struct VOut {
    float4 pos [[position]];
    float2 uv;
};

// the same triangle as metal-triangle: no vertex buffer
vertex VOut v_tri(uint vid [[vertex_id]])
{
    const float2 p[3] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(0.0, 0.5) };
    VOut o;
    o.pos = float4(p[vid], 0.25, 1.0);
    o.uv = p[vid] + 0.5;
    return o;
}

fragment float4 f_solid(VOut in [[stage_in]]) { return float4(1.0, 0.25, 0.0, 1.0); }

fragment uint4 f_solid_u(VOut in [[stage_in]]) { return uint4(255, 64, 0, 255); }

struct Mrt2 {
    float4 c0 [[color(0)]];
    float4 c1 [[color(1)]];
};
fragment Mrt2 f_mrt2(VOut in [[stage_in]])
{
    Mrt2 o;
    o.c0 = float4(1.0, 0.25, 0.0, 1.0);
    o.c1 = float4(0.0, 0.5, 1.0, 1.0);
    return o;
}

// the plain 2D sample (the form the A8 Mesa builds): the texture-state words of an RGBA8 and an ASTC 4x4 texture
fragment float4 f_tex(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]])
{
    return t.sample(s, in.uv);
}

// sample forms the A8 Mesa refuses (g5p_usc.c CHECKs): explicit LOD, bias, gradient, gather, array, cube
fragment float4 f_tex_lod(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]])
{
    return t.sample(s, in.uv, level(1.0));
}
fragment float4 f_tex_bias(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]])
{
    return t.sample(s, in.uv, bias(0.5));
}
fragment float4 f_tex_grad(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]])
{
    return t.sample(s, in.uv, gradient2d(float2(0.01, 0.0), float2(0.0, 0.01)));
}
fragment float4 f_tex_gather(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]])
{
    return t.gather(s, in.uv);
}
fragment float4 f_tex_array(VOut in [[stage_in]], texture2d_array<float> t [[texture(0)]], sampler s [[sampler(0)]])
{
    return t.sample(s, in.uv, 1);
}
fragment float4 f_tex_cube(VOut in [[stage_in]], texturecube<float> t [[texture(0)]], sampler s [[sampler(0)]])
{
    return t.sample(s, float3(in.uv * 2.0 - 1.0, 1.0));
}
fragment float4 f_tex_offset(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]])
{
    return t.sample(s, in.uv, int2(1, -1));
}

// round 2 (see a8/n102/SHADERS.md): the forms the A8 Mesa still refuses for want of a witness
struct FragBytes {
    float lod, bias, layer_f;
    uint layer_u;
};
// round 12 (update 55): a cube sample feeding arithmetic (multiply, then add), not straight to the output;
// k.bias = 0.5 and k.lod = 1.0 come from a buffer, so the compiler cannot fold them: out = face * 0.5 + 0.25
fragment float4 f_tex_cube_mul(VOut in [[stage_in]], texturecube<float> t [[texture(0)]], sampler s [[sampler(0)]],
                               constant FragBytes &k [[buffer(0)]])
{
    return t.sample(s, float3(in.uv * 2.0 - 1.0, 1.0)) * k.bias + k.lod * 0.25;
}
fragment float4 f_tex2(VOut in [[stage_in]], texture2d<float> t0 [[texture(0)]], texture2d<float> t1 [[texture(1)]],
                       sampler s [[sampler(0)]])
{
    return t0.sample(s, in.uv) * t1.sample(s, in.uv.yx);
}
fragment float4 f_tex_lod_buf(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]],
                              constant FragBytes &k [[buffer(0)]])
{
    return t.sample(s, in.uv, level(k.lod));
}
fragment float4 f_tex_bias_buf(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]],
                               constant FragBytes &k [[buffer(0)]])
{
    return t.sample(s, in.uv, bias(k.bias));
}
fragment float4 f_tex_grad_asym(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]])
{
    return t.sample(s, in.uv, gradient2d(float2(0.01, 0.02), float2(0.03, 0.04)));
}
fragment float4 f_tex_array_buf(VOut in [[stage_in]], texture2d_array<float> t [[texture(0)]], sampler s [[sampler(0)]],
                                constant FragBytes &k [[buffer(0)]])
{
    return t.sample(s, in.uv, k.layer_u);
}
fragment float4 f_tex_lod_var(VOut in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]])
{
    return t.sample(s, in.uv, level(in.uv.x * 4.0));
}

// round 3 (see a8/n102/SHADERS.md)
fragment float4 f_tex_read(VOut in [[stage_in]], texture2d<float> t [[texture(0)]])
{
    return t.read(uint2(in.pos.xy));
}
struct Mrt3 {
    float4 c0 [[color(0)]];
    float4 c1 [[color(1)]];
    float4 c2 [[color(2)]];
};
fragment Mrt3 f_mrt3(VOut in [[stage_in]])
{
    Mrt3 o;
    o.c0 = float4(1.0, 0.25, 0.0, 1.0);
    o.c1 = float4(0.0, 0.5, 1.0, 1.0);
    o.c2 = float4(0.25, 1.0, 0.5, 1.0);
    return o;
}
struct Mrt4 {
    float4 c0 [[color(0)]];
    float4 c1 [[color(1)]];
    float4 c2 [[color(2)]];
    float4 c3 [[color(3)]];
};
fragment Mrt4 f_mrt4(VOut in [[stage_in]])
{
    Mrt4 o;
    o.c0 = float4(1.0, 0.25, 0.0, 1.0);
    o.c1 = float4(0.0, 0.5, 1.0, 1.0);
    o.c2 = float4(0.25, 1.0, 0.5, 1.0);
    o.c3 = float4(0.75, 0.0, 0.25, 1.0);
    return o;
}
struct VIter {
    float4 pos [[position]];
    float2 uv;
    float4 fl [[flat]];
    float2 np [[center_no_perspective]];
    float2 cen [[centroid_perspective]];
};
// the triangle with w != 1 at one vertex, so perspective and no-perspective iterations differ
vertex VIter v_iter(uint vid [[vertex_id]])
{
    const float2 p[3] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(0.0, 0.5) };
    const float w = vid == 2 ? 2.0 : 1.0;
    VIter o;
    o.pos = float4(p[vid] * w, 0.25 * w, w);
    o.uv = p[vid] + 0.5;
    o.fl = float4(0.25 * float(vid), 0.5, 0.75, 1.0);
    o.np = p[vid] + 0.5;
    o.cen = p[vid].yx + 0.5;
    return o;
}
fragment float4 f_iter(VIter in [[stage_in]])
{
    return float4(in.fl.x + in.np.x * 0.5, in.np.y, in.cen.x, saturate(in.uv.x * 2.0));
}
// pr_big: full-screen triangles, each a little nearer than the last (LESS passes every one)
vertex VOut v_big(uint vid [[vertex_id]])
{
    const float2 p[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    const uint t = vid / 3;
    VOut o;
    o.pos = float4(p[vid % 3], 0.45 - float(t) * (0.4 / 30000.0), 1.0); /* nearer than the 0.5 clear */
    o.uv = p[vid % 3] * 0.5 + 0.5;
    return o;
}

// round 4 (see a8/n102/SHADERS.md): how the A8 samples 2-7 textures with one shared sampler
// and with a sampler per texture (where the sampler states go once byte 6's nibble cannot reach them). Each texture
// is one solid colour (a8-passcap kSolid), so the target's centre names the image each channel came from.
#define T(i) texture2d<float> t##i [[texture(i)]]
fragment float4 f_tex2s(VOut in [[stage_in]], T(0), T(1), sampler s0 [[sampler(0)]], sampler s1 [[sampler(1)]])
{
    return float4(t0.sample(s0, in.uv).r, t1.sample(s1, in.uv).g, t0.sample(s0, in.uv).b, 1.0);
}
fragment float4 f_tex3s(VOut in [[stage_in]], T(0), T(1), T(2), sampler s0 [[sampler(0)]], sampler s1 [[sampler(1)]],
                        sampler s2 [[sampler(2)]])
{
    return float4(t0.sample(s0, in.uv).r, t1.sample(s1, in.uv).g, t2.sample(s2, in.uv).b, 1.0);
}
fragment float4 f_tex4(VOut in [[stage_in]], T(0), T(1), T(2), T(3), sampler s [[sampler(0)]])
{
    return float4(t0.sample(s, in.uv).r, t1.sample(s, in.uv).g, t2.sample(s, in.uv).b, t3.sample(s, in.uv).r);
}
fragment float4 f_tex4s(VOut in [[stage_in]], T(0), T(1), T(2), T(3), sampler s0 [[sampler(0)]],
                        sampler s1 [[sampler(1)]], sampler s2 [[sampler(2)]], sampler s3 [[sampler(3)]])
{
    return float4(t0.sample(s0, in.uv).r, t1.sample(s1, in.uv).g, t2.sample(s2, in.uv).b, t3.sample(s3, in.uv).r);
}
fragment float4 f_tex5(VOut in [[stage_in]], T(0), T(1), T(2), T(3), T(4), sampler s [[sampler(0)]])
{
    return float4(t0.sample(s, in.uv).r, t1.sample(s, in.uv).g * 0.5 + t3.sample(s, in.uv).g * 0.5,
                  t2.sample(s, in.uv).b, t4.sample(s, in.uv).r);
}
fragment float4 f_tex5s(VOut in [[stage_in]], T(0), T(1), T(2), T(3), T(4), sampler s0 [[sampler(0)]],
                        sampler s1 [[sampler(1)]], sampler s2 [[sampler(2)]], sampler s3 [[sampler(3)]],
                        sampler s4 [[sampler(4)]])
{
    return float4(t0.sample(s0, in.uv).r, t1.sample(s1, in.uv).g * 0.5 + t3.sample(s3, in.uv).g * 0.5,
                  t2.sample(s2, in.uv).b, t4.sample(s4, in.uv).r);
}
fragment float4 f_tex7(VOut in [[stage_in]], T(0), T(1), T(2), T(3), T(4), T(5), T(6), sampler s [[sampler(0)]])
{
    return float4(t0.sample(s, in.uv).r, (t1.sample(s, in.uv).g + t3.sample(s, in.uv).g + t5.sample(s, in.uv).g) / 3.0,
                  (t2.sample(s, in.uv).b + t6.sample(s, in.uv).b) * 0.5, t4.sample(s, in.uv).r);
}
/* round 5: seven textures, seven samplers (sampler slots 7..13: byte 5 07 for slots 12 and 13) */
fragment float4 f_tex7s(VOut in [[stage_in]], T(0), T(1), T(2), T(3), T(4), T(5), T(6), sampler s0 [[sampler(0)]],
                        sampler s1 [[sampler(1)]], sampler s2 [[sampler(2)]], sampler s3 [[sampler(3)]],
                        sampler s4 [[sampler(4)]], sampler s5 [[sampler(5)]], sampler s6 [[sampler(6)]])
{
    return float4(t0.sample(s0, in.uv).r, (t1.sample(s1, in.uv).g + t3.sample(s3, in.uv).g + t5.sample(s5, in.uv).g) / 3.0,
                  (t2.sample(s2, in.uv).b + t6.sample(s6, in.uv).b) * 0.5, t4.sample(s4, in.uv).r);
}

// round 7: WebRender's GL path (texelFetch in the vertex and fragment stages, integer data textures)
fragment float4 f_read_f32(VOut in [[stage_in]], texture2d<float> t [[texture(0)]])
{
    return t.read(uint2(in.pos.xy) % 4) / 16.0;
}
fragment float4 f_read_i32(VOut in [[stage_in]], texture2d<int> t [[texture(0)]])
{
    return float4(t.read(uint2(in.pos.xy) % 4)) / 64.0;
}
struct VCol {
    float4 pos [[position]];
    float4 col;
};
vertex VCol v_read_f32(uint vid [[vertex_id]], texture2d<float> t [[texture(0)]])
{
    const float2 p[3] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(0.0, 0.5) };
    VCol o;
    const float4 d = t.read(uint2(vid + 1, 2));
    o.pos = float4(p[vid] * (d.w / 7.0), 0.25, 1.0);
    o.col = d / 16.0;
    return o;
}
vertex VCol v_read_i32(uint vid [[vertex_id]], texture2d<int> t [[texture(0)]])
{
    const float2 p[3] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(0.0, 0.5) };
    VCol o;
    const int4 d = t.read(uint2(vid + 1, 2));
    o.pos = float4(p[vid] * (float(d.w) / 21.0), 0.25, 1.0);
    o.col = float4(d) / 64.0;
    return o;
}
// round 10: vertex reads whose position does not depend on the read (round 9's v_read passes drew nothing at the
// centre: a read of 0 collapses their triangle); the colour is the read itself
vertex VCol v_read2_f32(uint vid [[vertex_id]], texture2d<float> t [[texture(0)]])
{
    const float2 p[3] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(0.0, 0.5) };
    VCol o;
    o.pos = float4(p[vid], 0.25, 1.0);
    o.col = t.read(uint2(1, 2)) / 16.0;
    return o;
}
vertex VCol v_read2_i32(uint vid [[vertex_id]], texture2d<int> t [[texture(0)]])
{
    const float2 p[3] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(0.0, 0.5) };
    VCol o;
    o.pos = float4(p[vid], 0.25, 1.0);
    o.col = float4(t.read(uint2(1, 2))) / 64.0;
    return o;
}
vertex VCol v_read2_bgra(uint vid [[vertex_id]], texture2d<float> t [[texture(0)]])
{
    const float2 p[3] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(0.0, 0.5) };
    VCol o;
    o.pos = float4(p[vid], 0.25, 1.0);
    o.col = t.read(uint2(32, 32));
    return o;
}
vertex VCol v_sample(uint vid [[vertex_id]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]])
{
    const float2 p[3] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(0.0, 0.5) };
    VCol o;
    o.pos = float4(p[vid], 0.25, 1.0);
    o.col = t.sample(s, p[vid] + 0.5, level(0.0));
    return o;
}
fragment float4 f_vcolor(VCol in [[stage_in]])
{
    return in.col;
}
