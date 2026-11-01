#include <metal_stdlib>
using namespace metal;
// Conditional discard on integer compares (reg-reg)
struct V { float4 pos [[position]]; float4 col; };
vertex V vs_v(uint vid [[vertex_id]], const device float4 *in [[buffer(0)]]) { V o; o.pos = in[vid]; o.col = in[vid+3]; return o; }
// pair vs_v fs_ieq
fragment float4 fs_ieq(V v [[stage_in]]) { if (as_type<uint>(v.col.y) == as_type<uint>(v.col.x)) discard_fragment(); return v.col; }
// pair vs_v fs_ine
fragment float4 fs_ine(V v [[stage_in]]) { if (as_type<uint>(v.col.y) != as_type<uint>(v.col.x)) discard_fragment(); return v.col; }
// pair vs_v fs_iugt
fragment float4 fs_iugt(V v [[stage_in]]) { if (as_type<uint>(v.col.y) > as_type<uint>(v.col.x)) discard_fragment(); return v.col; }
// pair vs_v fs_islt
fragment float4 fs_islt(V v [[stage_in]]) { if (as_type<int>(v.col.y) < as_type<int>(v.col.x)) discard_fragment(); return v.col; }
