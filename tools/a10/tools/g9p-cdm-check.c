// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * Host check for g9p-cdm.h: the encoder reproduces the words of the device
 * experiments (COMPUTE.md) and of the captured iPadOS programs.
 *
 *   cc -Wall -I tools -o /tmp/g9p-cdm-check tools/g9p-cdm-check.c && /tmp/g9p-cdm-check
 */
#include <stdio.h>
#include "g9p-cdm.h"
static int bad;
#define EQ(a, b) do { if ((uint32_t)(a) != (uint32_t)(b)) { printf("%s = %#x, want %#x\n", #a, (uint32_t)(a), (uint32_t)(b)); bad++; } } while (0)
int main(void)
{
	uint32_t w[33], k[4]; uint16_t e[33];
	struct g9p_pass_end_programs p = { 0x2400, 0x2000, 0x2300, 0x2700 };
	struct g9p_cdm_record r;
	EQ(g9p_pds_dout(G9P_DOUTD, 0, G9P_PDS_DATA, 4, 0), 0xf0001000);
	EQ(g9p_pds_dout(G9P_DOUTD, 1, G9P_PDS_DATA, 6, G9P_PDS_END), 0xf4001808);
	EQ(g9p_pds_dout(G9P_DOUTW, 0, G9P_PDS_TEMPS, 2, 0), 0xf0000a01);
	EQ(g9p_pds_dout(G9P_DOUTU, 0, G9P_PDS_DATA, 0, G9P_PDS_END | G9P_PDS_CC), 0xfc000002);
	EQ(g9p_pds_dout(G9P_DOUTW, 0, G9P_PDS_TEMPS, 4, G9P_PDS_END), 0xf4001201);
	EQ(g9p_pds_dout(G9P_DOUTW, 1, G9P_PDS_TEMPS, 5, G9P_PDS_END), 0xf4001609);
	EQ(g9p_pds_dout(G9P_DOUTD, 0, G9P_PDS_DATA, 2, 0), 0xf0000800);
	EQ(g9p_pds_dout(G9P_DOUTU, 2, G9P_PDS_DATA, 0, G9P_PDS_END), 0xf4000012);
	EQ(g9p_pds_dout(G9P_DOUTC, 0, G9P_PDS_DATA, 0, 0), 0xf0000005);
	EQ(g9p_pds_bra_not_if1(4), 0xc2c00004);
	r = g9p_cdm_dma_task(G9P_CDM_DATA_BLOCKS(2), 0x900, 0x3e00);
	EQ(r.w[0], 4); EQ(r.w[1], 0x902); EQ(r.w[2], 0x3e00); EQ(r.w[6], 0x40000001); EQ(r.w[7], 0);
	EQ(G9P_CDM_KERNEL_SIZES | G9P_CDM_ANY_CLUSTER | G9P_CDM_FENCE | G9P_CDM_DATA_BLOCKS(1), 0x2103);
	EQ(G9P_CDM_KERNEL_SIZES | G9P_CDM_ANY_CLUSTER | G9P_CDM_FENCE | G9P_CDM_DATA_BLOCKS(2), 0x2107);
	r = g9p_cdm_kernel(0x2107, 0x800, 0x3f00, 64, 1, 1, 64, 1);
	EQ(r.w[3], 63); EQ(r.w[6], 1); EQ(r.w[7], 63 << 20);
	r = g9p_cdm_kernel(0x2107, 0x800, 0x3f00, 256, 1, 1, 16, 1);
	EQ(r.w[6], 0x80000001); EQ(r.w[7], 15 << 20);
	g9p_cdm_end_pass(w, &p);
	{ const uint32_t want[33] = {
		2, 0x2002, 0x2400, 0, 0, 0, 0x40000000, 0,
		0xc0000003, 0x2704, 0x2300, 0, 0, 0, 0x40000000, 0,
		3, 0x2004, 0x2400, 0, 0, 0, 0x40000000, 0,
		0xc0000003, 0x2704, 0x2300, 0, 0, 0, 0x40000000, 0, 0x80000000 };
	  for (int i = 0; i < 33; i++) EQ(w[i], want[i]); }
	g9p_pds_kick_program(k); EQ(k[0], 0xc2c00002); EQ(k[1], 0xd3000000); EQ(k[2], 0xfc000002); EQ(k[3], 0xd3000000);
	g9p_pds_fence_program(k); EQ(k[2], 0xf0000005);
	g9p_usc_empty_kernel(e); EQ(e[1], 0x0140); EQ(e[31], 0xc000); EQ(e[32], 0x8000);
	printf(bad ? "%d mismatches\n" : "all match\n", bad);
	return !!bad;
}
