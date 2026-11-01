#include <metal_stdlib>
using namespace metal;
// Fragment uniform operands beyond dword 31: all 160 dwords of a buffer used
struct V { float4 pos [[position]]; float4 a; };
struct U { float4 a[40]; };
vertex V vs_v(uint vid [[vertex_id]], const device float4 *in [[buffer(0)]]) { V o; o.pos = in[vid]; o.a = in[vid + 3]; return o; }
// pair vs_v fs_big
fragment float4 fs_big(V v [[stage_in]], constant U &u [[buffer(0)]], device float4 *o [[buffer(1)]]) {
	o[0] = v.a * u.a[0];
	o[1] = v.a * u.a[1];
	o[2] = v.a * u.a[2];
	o[3] = v.a * u.a[3];
	o[4] = v.a * u.a[4];
	o[5] = v.a * u.a[5];
	o[6] = v.a * u.a[6];
	o[7] = v.a * u.a[7];
	o[8] = v.a * u.a[8];
	o[9] = v.a * u.a[9];
	o[10] = v.a * u.a[10];
	o[11] = v.a * u.a[11];
	o[12] = v.a * u.a[12];
	o[13] = v.a * u.a[13];
	o[14] = v.a * u.a[14];
	o[15] = v.a * u.a[15];
	o[16] = v.a * u.a[16];
	o[17] = v.a * u.a[17];
	o[18] = v.a * u.a[18];
	o[19] = v.a * u.a[19];
	o[20] = v.a * u.a[20];
	o[21] = v.a * u.a[21];
	o[22] = v.a * u.a[22];
	o[23] = v.a * u.a[23];
	o[24] = v.a * u.a[24];
	o[25] = v.a * u.a[25];
	o[26] = v.a * u.a[26];
	o[27] = v.a * u.a[27];
	o[28] = v.a * u.a[28];
	o[29] = v.a * u.a[29];
	o[30] = v.a * u.a[30];
	o[31] = v.a * u.a[31];
	o[32] = v.a * u.a[32];
	o[33] = v.a * u.a[33];
	o[34] = v.a * u.a[34];
	o[35] = v.a * u.a[35];
	o[36] = v.a * u.a[36];
	o[37] = v.a * u.a[37];
	o[38] = v.a * u.a[38];
	o[39] = v.a * u.a[39];
	return float4(1.0); }
