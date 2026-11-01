#include <metal_stdlib>
using namespace metal;
// Fragment uniform operands beyond dword 31: the operand's extension word
struct V { float4 pos [[position]]; float4 a; };
struct U { float4 a[40]; };
vertex V vs_v(uint vid [[vertex_id]], const device float4 *in [[buffer(0)]]) { V o; o.pos = in[vid]; o.a = in[vid + 3]; return o; }
// pair vs_v fs_u
fragment float4 fs_u(V v [[stage_in]], constant U &u [[buffer(0)]], device float *o [[buffer(1)]]) {
	o[0] = v.a.x * u.a[0].x; o[1] = v.a.x * u.a[1].y; o[2] = v.a.x * u.a[7].w; o[3] = v.a.x * u.a[8].x;
	o[4] = v.a.x * u.a[15].y; o[5] = v.a.x * u.a[16].z; o[6] = v.a.x * u.a[31].w; o[7] = v.a.x * u.a[39].w;
	return float4(1.0); }
