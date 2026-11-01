#include <metal_stdlib>
using namespace metal;
// Conditional discard: the compare forms before 6004, per condition
struct V { float4 pos [[position]]; float4 col; };
vertex V vs_v(uint vid [[vertex_id]], const device float4 *in [[buffer(0)]]) { V o; o.pos = in[vid]; o.col = in[vid+3]; return o; }
// pair vs_v fs_lt
fragment float4 fs_lt(V v [[stage_in]]) { if (v.col.y < v.col.x) discard_fragment(); return v.col; }
// pair vs_v fs_le
fragment float4 fs_le(V v [[stage_in]]) { if (v.col.y <= v.col.x) discard_fragment(); return v.col; }
// pair vs_v fs_gt
fragment float4 fs_gt(V v [[stage_in]]) { if (v.col.y > v.col.x) discard_fragment(); return v.col; }
// pair vs_v fs_ge
fragment float4 fs_ge(V v [[stage_in]]) { if (v.col.y >= v.col.x) discard_fragment(); return v.col; }
// pair vs_v fs_eq
fragment float4 fs_eq(V v [[stage_in]]) { if (v.col.y == v.col.x) discard_fragment(); return v.col; }
// pair vs_v fs_ne
fragment float4 fs_ne(V v [[stage_in]]) { if (v.col.y != v.col.x) discard_fragment(); return v.col; }
// pair vs_v fs_ine
fragment float4 fs_ine(V v [[stage_in]]) { if (as_type<uint>(v.col.y) != 0u) discard_fragment(); return v.col; }
// pair vs_v fs_iult
fragment float4 fs_iult(V v [[stage_in]]) { if (as_type<uint>(v.col.y) < as_type<uint>(v.col.x)) discard_fragment(); return v.col; }
