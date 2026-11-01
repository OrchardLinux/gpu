// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * A triangle on the Apple A10 GPU from nothing but our own encodings: every
 * buffer, program, PPP state block, VDM stream word and render register is
 * built here (RENDER.md "Own programs", "A triangle from scratch"). It is
 * what Mesa's G9P render path has to produce, in one file, so that each
 * piece can be checked on hardware before it is moved into the driver.
 *
 * Code-heap layout: one 64 KiB buffer mapped at both the PDS and the USC
 * heap base, so offsets are the same in both (USC programs 64-byte aligned,
 * PDS programs 16-byte aligned; a kick bundle is its data at +0 and its
 * code at +0x20, as PPP's shader base and PDS_BGRND0 expect).
 *
 * Build (static, arm64): tools/build-pvr-compute-test.sh pvr-tri
 * Run: pvr-tri [OUT.raw] [/dev/dri/renderD128]
 *   TRI_COLOR=r,g,b,a  fragment colour (default 0.5,0.25,1,1)
 *   TRI_CLEAR=r,g,b,a  clear colour (default 0,0,0,1)
 *   TRI_W=w            clip-space w of every vertex (default 1)
 *   TRI_VARY=n         n (1, 2) vec4 colour varyings; the fragment shader
 *                      outputs varying TRI_READ (default n - 1) through
 *                      the iterate W1 high byte TRI_ITER (hex, with W2
 *                      0x0080 unless TRI_ITER_NOW2 is set)
 *   TRI_TEX=1          sample a 4x4 texture at varying 0's (x, y) instead
 *                      (implies TRI_VARY=1)
 *   TRI_VS_HEX=FILE    vertex shader code as hex words (e.g. Mesa's G9P_DUMP
 *                      output), reading an interleaved vertex buffer (x, y,
 *                      r, g, b, a; stride 24) from common-store dwords 0-1;
 *                      implies TRI_VARY=1. TRI_VS_TEMPS: its kick word 1.
 *   TRI_FS_HEX=FILE    fragment shader code as hex words; TRI_FS_TEMPS as above
 *   TRI_PASS=N         the draw's ISP pass type (1: translucent, for a
 *                      fragment shader reading the tile, 211c 2800)
 *   TRI_FS32=FORM,R    the colour as f32 move-immediates into rR.. (W1 base
 *                      FORM), then TRI_FS_ALU / TRI_FS_MULH ops on it (see
 *                      fs_program(); ISA.md "Fragment register bank");
 *                      TRI_FS_PRE=HEX,... words put first
 *   TRI_PDS_STATE0=HEX the draw's PDS_STATE0 word (default 0x20020001)
 *   TRI_NODRAW=1       no INDEX_LIST (a render of the clear only)
 *   TRI_ISP_CTL=HEX    fragment ISP_CTL (default 0x21000f); TRI_TE_PSG=HEX
 *                      geometry TE_PSG (default 0x20000)
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#include "drm/pvr_drm.h"
#include "g9p-cdm.h"

#define PAGE		0x4000ull
#define GENERAL		heaps[DRM_PVR_HEAP_GENERAL].base
#define DATA		(GENERAL + 0x100000000ull)	/* our buffers */
#define TARGET		(GENERAL + 0x100100000ull)	/* 64x64 RGBA8 render target */
#define RT		(GENERAL + 0x200000000ull)	/* HWRT buffers, free list */
#define FL_PAGES	1024u
#define W		64u
#define H		64u

struct bo {
	uint32_t handle;
	uint8_t *map;
	uint64_t addr, size;
};

static int fd;
static uint32_t vm;
static struct drm_pvr_heap heaps[DRM_PVR_HEAP_COUNT];

static void die(const char *what)
{
	fprintf(stderr, "%s: %s\n", what, strerror(errno));
	exit(1);
}

static void bo_create(struct bo *bo, uint64_t addr, uint64_t size, uint64_t flags)
{
	struct drm_pvr_ioctl_create_bo_args create = { .size = size, .flags = flags };
	struct drm_pvr_ioctl_get_bo_mmap_offset_args off = { 0 };
	struct drm_pvr_ioctl_vm_map_args map = { 0 };

	if (ioctl(fd, DRM_IOCTL_PVR_CREATE_BO, &create))
		die("CREATE_BO");
	bo->map = NULL;
	if (flags & DRM_PVR_BO_ALLOW_CPU_USERSPACE_ACCESS) {
		off.handle = create.handle;
		if (ioctl(fd, DRM_IOCTL_PVR_GET_BO_MMAP_OFFSET, &off))
			die("GET_BO_MMAP_OFFSET");
		bo->map = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, off.offset);
		if (bo->map == MAP_FAILED)
			die("mmap");
		memset(bo->map, 0, size);
	}
	map.vm_context_handle = vm;
	map.device_addr = addr;
	map.handle = create.handle;
	map.size = size;
	if (ioctl(fd, DRM_IOCTL_PVR_VM_MAP, &map))
		die("VM_MAP");
	bo->handle = create.handle;
	bo->addr = addr;
	bo->size = size;
}

/* --- Code heap ----------------------------------------------------------- */

/* USC programs */
#define USC_FS		0x0400u	/* up to 0x1000 */
#define USC_VS		0x0800u	/* up to 0x0c00 */
#define USC_CLEAR	0x0200u
#define USC_EOT		0x0280u
#define USC_VDM_END	0x0300u	/* register 0x470's program */
/* PDS programs and data */
#define PDS_FS		0x1000u	/* kick bundle: data, code at +0x20 */
#define PDS_HALT	0x1040u	/* texture/uniform and varying programs: none */
#define PDS_VS_CODE	0x1080u
#define PDS_VS_DATA	0x10c0u
#define PDS_DMA_CODE	0x1100u
#define PDS_DMA_DATA	0x1140u
#define PDS_BG		0x1180u	/* kick bundle */
#define PDS_BG_DMA	0x11c0u
#define PDS_BG_DATA	0x11e0u
#define PDS_EOT_CODE	0x1200u
#define PDS_EOT_DATA	0x1240u
#define PDS_VDM_END	0x1280u	/* kick bundle (register 0x470) */
#define PDS_CTX_CODE	0x12c0u	/* context store/resume: HALT */
#define PDS_CTX_DATA	0x12d0u
#define PDS_STREAM_OUT	0x1300u	/* data (16 bytes), HALT at +0x10 */
#define PDS_VARYING	0x1400u	/* DOUTI data, code after it */
#define PDS_TEX_CODE	0x1480u	/* texture + sampler DMA (TEXUNICODEBASE) */
#define PDS_TEX_DMA_DATA 0x14c0u	/* its data (UNIFORMDATABASE) */

/* Data buffer offsets */
#define D_VERTICES	0x0000u
#define D_COLOURS	0x0040u	/* 2 x 3 vertices x vec4 */
#define D_VS_UNIFORMS	0x0100u
#define D_CLEAR		0x0200u
#define D_IMAGE		0x0240u
#define D_PPP		0x0400u
#define D_STREAM	0x0800u
#define D_CTX_STATE	0x1000u
#define D_TEXELS	0x1800u	/* 4x4 x 4 bytes */
#define D_TEX_STATE	0x1900u	/* texture state (8 dwords), sampler (2) at +0x20 */

static uint8_t *code;
static unsigned int n_vary;	/* TRI_VARY */
static int tex;			/* TRI_TEX */

static void put_code(uint32_t off, const void *p, uint32_t size)
{
	memcpy(code + off, p, size);
}

struct usc {
	uint16_t w[256];
	unsigned int n;
};

static void emit(struct usc *c, const uint16_t *w, unsigned int n)
{
	memcpy(c->w + c->n, w, 2 * n);
	c->n += n;
}
#define EMIT(c, ...) do { const uint16_t w_[] = { __VA_ARGS__ }; emit(c, w_, sizeof(w_) / 2); } while (0)

/* A jump to the next 64-byte block, `c000` padding up to it (ISA.md "Program frame") */
static void jump_to_block(struct usc *c)
{
	unsigned int off = ((2 * c->n + 6 + 63) & ~63u) - 2 * c->n;

	EMIT(c, 0x0100, (off & 0xfefe) | 0x0100 | (off >> 8 & 1), 0x0000);
	while (c->n % 32)
		EMIT(c, 0xc000);
}

/* 32-bit move-immediate; @w1_base 0x0300 (32-bit form) or 0x0100 (fragment outputs) */
static void mov_imm(struct usc *c, uint16_t w1_base, unsigned int dst, uint32_t imm)
{
	uint16_t w3 = 0x0120 | ((imm >> 6) & 7) << 1 | ((imm >> 10) & 1) << 4 |
		      ((imm >> 14) & 1) << 6 | ((imm >> 15) & 1) << 7 | ((imm >> 11) & 7) << 12;

	if (imm >> 16)
		EMIT(c, 0x0198 | ((imm >> 9) & 1) << 13, w1_base | 2 * dst, 0x0101 | (imm & 0x3f) << 1,
		     w3 | 1 | ((imm >> 24) & 1) << 15,
		     0x0100 | ((imm >> 16) & 0xff) | ((imm >> 25) & 0x7f) << 9, 0x0154, 0x0038);
	else
		EMIT(c, 0x0198 | ((imm >> 9) & 1) << 13, w1_base | 2 * dst, 0x0101 | (imm & 0x3f) << 1,
		     w3, 0x0154, 0x0038);
}

static uint32_t f2u(float f)
{
	uint32_t u;

	memcpy(&u, &f, 4);
	return u;
}

/* IEEE half from float (normal range, round to nearest) */
static uint16_t half(float f)
{
	uint32_t u = f2u(f);
	int e = (int)((u >> 23) & 0xff) - 127 + 15;

	if (e <= 0)
		return (u >> 16) & 0x8000;
	return ((u >> 16) & 0x8000) | e << 10 | (((u >> 13) + ((u >> 12) & 1)) & 0x3ff);
}

static void put_usc(uint32_t off, struct usc *c)
{
	put_code(off, c->w, 2 * c->n);
}

/* Code from a file of hex words (TRI_VS_HEX, TRI_FS_HEX); 0 if not set */
static int load_hex(const char *env, uint32_t off)
{
	const char *path = getenv(env);
	struct usc c = { .n = 0 };
	unsigned int w;
	FILE *f;

	if (!path)
		return 0;
	f = fopen(path, "r");
	if (!f)
		die(path);
	while (c.n < 256 && fscanf(f, "%x", &w) == 1)
		c.w[c.n++] = w;
	fclose(f);
	put_usc(off, &c);
	printf("%s: %u words at %#x\n", path, c.n, off);
	return 1;
}

/*
 * f16 half @h (of r0-r1) = f32 r[@src] * 1.0: a float multiply with an f16
 * immediate operand writing a half register (ISA.md "Fragment outputs")
 */
static void to_half(struct usc *c, unsigned int h, unsigned int src)
{
	EMIT(c, 0x0189, 0x0100 | h, 0x0101 | src << 10, 0x7130, 0x0b48, 0x0070);
}

/*
 * Fragment shader: the colour as packed halves in r0-r1, `211c 0800`, end.
 * TRI_FS32=1: the colour as f32 in r2-r5 first, converted with to_half().
 */
static void fs_program(const float col[4])
{
	struct usc c = { .n = 0 };
	unsigned int i;

	const unsigned int tex_base = getenv("TRI_TEX_W2BASE") ? atoi(getenv("TRI_TEX_W2BASE")) :
				      getenv("TRI_TEX_BASE") ? atoi(getenv("TRI_TEX_BASE")) : 0;
	const unsigned int tex_samp = getenv("TRI_TEX_SAMP") ? atoi(getenv("TRI_TEX_SAMP")) : tex_base + 8;

	/* TRI_FS_PRE=HEX,...: words to put first */
	if (getenv("TRI_FS_PRE")) {
		char *pre = strdup(getenv("TRI_FS_PRE")), *tok, *save = NULL;

		for (tok = strtok_r(pre, ",", &save); tok; tok = strtok_r(NULL, ",", &save))
			c.w[c.n++] = strtoul(tok, NULL, 16);
		free(pre);
	}

	if (getenv("TRI_FS_COORD")) {
		/*
		 * Fragment position: `211c 6800` writes the pixel's integer x, y
		 * as halves 0-1 (r0); u2f from a half source (`0199`, W2 0x0101 |
		 * 0x14 | half << 10) into r2/r3, + 0.5, / 64 (x 1/64 = fmul), out
		 */
		/* TRI_FS_COORD=CONVERT_W0,X_SRC,Y_SRC (hex; default 0199,0,1) */
		unsigned int cw0 = 0x0199, xs = 0, ys = 1;

		sscanf(getenv("TRI_FS_COORD"), "%x,%x,%x", &cw0, &xs, &ys);
		EMIT(&c, 0x211c, 0x6800);
		EMIT(&c, 0x004d);
		EMIT(&c, cw0, 0x0104, 0x0101 | 0x14 | xs << 10, 0x0120, 0x0468);
		EMIT(&c, cw0, 0x0106, 0x0101 | 0x14 | ys << 10, 0x0120, 0x0468);
		mov_imm(&c, 0x0100, 4, f2u(0.5f));
		mov_imm(&c, 0x0100, 5, f2u(1.0f / 64));
		mov_imm(&c, 0x0100, 6, 0);
		mov_imm(&c, 0x0100, 7, f2u(1.0f));
		for (i = 2; i < 4; i++) {
			EMIT(&c, 0x3199, 0x0100 | 2 * i, 0x0100 | i << 2 | 4 << 10, 0x0044);
			EMIT(&c, 0x3199, 0x0100 | 2 * i, 0x0100 | i << 2 | 5 << 10, 0x0048);
		}
		to_half(&c, 0, 2);
		to_half(&c, 1, 3);
		to_half(&c, 2, 6);
		to_half(&c, 3, 7);
	} else if (tex) {
		/*
		 * Iterate varying 0's x, y (f32, r0-r1), then sample with the
		 * texture state in common-store dwords 0-7 and the sampler in
		 * 8-9 into the colour halves (both forms as Apple's `fs_tex`)
		 */
		if (getenv("TRI_TEX_F32")) {
			/*
			 * General form: coordinates iterated into r2-r3 (f32), the
			 * sample into f32 r4-r7 (W0 f51a; W1 = coordinate register
			 * << 9 | 0x0100 | 2 x destination; W2 = 0x8100 | state
			 * dword << 8 | sampler dword), converted to the output
			 */
			/* TRI_TEX_F32=ITER_W1,ITER_W2,SAMPLE_W0,SAMPLE_W1,HALF (hex) */
			unsigned int iw1 = 0x0304, iw2 = 0x0080, sw0 = 0xf51a, sw1 = 0x0508, hv = 0;

			sscanf(getenv("TRI_TEX_F32"), "%x,%x,%x,%x,%x", &iw1, &iw2, &sw0, &sw1, &hv);
			EMIT(&c, 0x1308, iw1, iw2);
			if (!(iw2 & 0x8000))
				EMIT(&c, 0x004d);
			/* TRI_TEX_STAGE=1: copy the coordinates to r0-r1 (r + 0) first */
			if (getenv("TRI_TEX_STAGE")) {
				unsigned int src = (iw1 & 0x7e) >> 1, stage_form = strtoul(getenv("TRI_TEX_STAGE"), NULL, 16);

				EMIT(&c, 0x1199, stage_form, 0x0101 | src << 10, 0x0120, 0x09a1, 0x0070);
				EMIT(&c, 0x1199, stage_form | 2, 0x0101 | (src + 1) << 10, 0x0120, 0x09a1, 0x0070);
			}
			EMIT(&c, sw0, sw1, 0x8100 | tex_base << 8 | tex_samp, 0x0700, 0x0200);
			EMIT(&c, 0x004d);
			if (!hv)
				for (i = 0; i < 4; i++)
					to_half(&c, i, ((sw1 & 0x7e) >> 1) + i);
		} else {
			EMIT(&c, 0x1308, 0x0300, 0x8000);
			EMIT(&c, 0xf518, 0x0100, 0x8100 | tex_base << 8 | tex_samp, 0x0700, 0x0200);
			EMIT(&c, 0x004d);
		}
	} else if (n_vary) {
		unsigned int read = getenv("TRI_READ") ? atoi(getenv("TRI_READ")) : n_vary - 1;
		unsigned int hi = getenv("TRI_ITER") ? strtoul(getenv("TRI_ITER"), NULL, 16) :
			      (read ? 0x0b : 0x03);

		/* iterate a perspective-correct vec4 as f32 into r4-r7, wait */
		if (getenv("TRI_ITER_NOW2"))
			EMIT(&c, 0x0308, (hi & ~1u) << 8 | 2 * 4);
		else
			EMIT(&c, 0x0308, (hi | 1) << 8 | 2 * 4, 0x0080);
		EMIT(&c, 0x004d);
		for (i = 0; i < 4; i++)
			to_half(&c, i, 4 + i);
	} else if (getenv("TRI_FS32")) {
		/* TRI_FS32=W1BASE,FIRST: register form and first register */
		unsigned int form = 0x0100, first = 2;

		sscanf(getenv("TRI_FS32"), "%x,%u", &form, &first);
		for (i = 0; i < 4; i++)
			mov_imm(&c, form, first + i, f2u(col[i]));
		/*
		 * TRI_FS_ALU=W1BASE: each channel times 2 (an f32 move to r6) and
		 * then times 0.5 with the compute two-source form, the result
		 * written with that W1 form
		 */
		if (getenv("TRI_FS_ALU")) {
			unsigned int alu = strtoul(getenv("TRI_FS_ALU"), NULL, 16);
			/* TRI_FS_W0=W0: the instruction's first word (compute: 3199) */
			unsigned int w0 = getenv("TRI_FS_W0") ? strtoul(getenv("TRI_FS_W0"), NULL, 16) : 0x3199;
			/* TRI_FS_OP=W3: the operation word (compute fmul: 0048) */
			unsigned int op = getenv("TRI_FS_OP") ? strtoul(getenv("TRI_FS_OP"), NULL, 16) : 0x0048;

			mov_imm(&c, 0x0100, 6, f2u(2.0f));
			mov_imm(&c, 0x0100, 7, f2u(0.5f));
			/* TRI_FS_SRC=BITS: or'ed into the source word */
			unsigned int src = getenv("TRI_FS_SRC") ? strtoul(getenv("TRI_FS_SRC"), NULL, 16) : 0;

			/* TRI_FS_ALU_ONCE=1: only the times 0.5 (the pair is an identity) */
			for (i = 0; i < 4; i++) {
				if (!getenv("TRI_FS_ALU_ONCE"))
					EMIT(&c, w0, alu | 2 * (first + i),
					     src | 0x0100 | (first + i) << 2 | 6 << 10, op);
				EMIT(&c, w0, alu | 2 * (first + i),
				     src | 0x0100 | (first + i) << 2 | 7 << 10, op);
			}
		}
		/*
		 * TRI_FS_MULH=W0,W4: each channel times the f16 immediate 0.5 in the
		 * immediate form, f32 in and out (Apple: 0199 01dd 8901 5130 0949 0070)
		 */
		if (getenv("TRI_FS_MULH")) {
			unsigned int hw0 = 0x0199, hw4 = 0x0948;

			sscanf(getenv("TRI_FS_MULH"), "%x,%x", &hw0, &hw4);
			for (i = 0; i < 4; i++)
				EMIT(&c, hw0, 0x0100 | 2 * (first + i), 0x0101 | (first + i) << 10, 0x7120,
				     hw4, 0x0070);
		}
		for (i = 0; i < 4; i++)
			to_half(&c, i, first + i);
	} else {
		mov_imm(&c, 0x0100, 0, half(col[0]) | (uint32_t)half(col[1]) << 16);
		mov_imm(&c, 0x0100, 1, half(col[2]) | (uint32_t)half(col[3]) << 16);
	}
	EMIT(&c, 0x211c, 0x0800, 0x8000);
	put_usc(USC_FS, &c);
}

/*
 * Vertex shader: (x, y) from the vertex buffer (address in common-store
 * dwords 0-1) at the vertex index in r0, z 0, w @w; outputs 0-3, the last
 * write in place of the end word.
 */
static void vs_program(float w)
{
	struct usc c = { .n = 0 };

	unsigned int v;

	EMIT(&c, 0x1189, 0x0304, 0x0181, 0x4100, 0x01a1, 0x0600 | 3 << 13);	/* r2:r3 = u0 + r0 * 8 */
	EMIT(&c, 5 << 11 | 0x0310, (1 | 2 << 2) << 8 | 4 << 1, 0x8800);	/* r4, r5 = *(r2:r3) */
	EMIT(&c, 0x004d);
	mov_imm(&c, 0x0300, 6, 0);
	mov_imm(&c, 0x0300, 7, f2u(w));
	EMIT(&c, 0x151e, 0x0108, 0x0000, 0x151e, 0x010a, 0x0001, 0x151e, 0x010c, 0x0002);
	if (n_vary) {
		EMIT(&c, 0x151e, 0x010e, 0x0003);
		EMIT(&c, 0x3199, 0x0302, 0x0100, 0x00a1);	/* r1 = r0 + r0 */
	}
	/* Varying v: vec4 at u(2 + 2v) + r1 * 8 (stride 16), outputs 4 + 4v .. 7 + 4v */
	for (v = 0; v < n_vary; v++) {
		unsigned int slot = 4 + 4 * v;

		EMIT(&c, 0x1189, 0x0304, 0x0581 | 4 * (2 + 2 * v), 0x4100, 0x01a1, 0x0600 | 3 << 13);
		EMIT(&c, 7 << 11 | 0x0310, (1 | 2 << 2) << 8 | 4 << 1, 0x8800);	/* r4-r7 */
		EMIT(&c, 0x004d);
		EMIT(&c, 0x151e, 0x0108, slot, 0x151e, 0x010a, slot + 1, 0x151e, 0x010c, slot + 2);
		if (v + 1 < n_vary)
			EMIT(&c, 0x151e, 0x010e, slot + 3);
	}
	jump_to_block(&c);
	EMIT(&c, 0x155e, 0xc10e, n_vary ? 3 + 4 * n_vary : 3);
	put_usc(USC_VS, &c);
}

/* Clear shader: 4 x f32 uniform -> f16 halves 0-3, colour output */
static void clear_program(void)
{
	struct usc c = { .n = 0 };
	unsigned int h;

	for (h = 0; h < 4; h++)
		EMIT(&c, 0x018a, 0x0100 | h, 0x0101, 0x01a0, 0x0101 | 4 * h, 0x4140, 0x0104, 0x00b0);
	EMIT(&c, 0x211c, 0x0800, 0x8000);
	put_usc(USC_CLEAR, &c);
}

/* End-of-tile shader: r0 = 0, PBE emit with the image state in the common store */
static void eot_program(void)
{
	struct usc c = { .n = 0 };

	mov_imm(&c, 0x0100, 0, 0);
	EMIT(&c, 0x051c, 0x5100, 0x0800);
	jump_to_block(&c);
	EMIT(&c, 0x8000);
	put_usc(USC_EOT, &c);
}

/* Register 0x470's program: a jump to `015e a000` (observed, meaning open) */
static void vdm_end_program(void)
{
	struct usc c = { .n = 0 };

	jump_to_block(&c);
	EMIT(&c, 0x015e, 0xa000);
	put_usc(USC_VDM_END, &c);
}

/* A kick bundle: data {USC offset, 0x10} at @off, DOUTU + HALT at @off + 0x20 */
static void pds_kick(uint32_t off, uint32_t usc, uint32_t flags)
{
	uint32_t data[2], prog[2] = { g9p_pds_dout(G9P_DOUTU, 0, G9P_PDS_DATA, 0, G9P_PDS_END | flags),
				      g9p_pds_halt() };

	g9p_pds_kick_data(data, usc);
	put_code(off, data, sizeof(data));
	put_code(off + 0x20, prog, sizeof(prog));
}

/* DOUTD control word: last, common store, destination dword, dwords */
static uint32_t doutd_ctrl(unsigned int dest, unsigned int dwords)
{
	return 1u << 31 | 1u << 28 | dest << 13 | dwords;
}

/* A one-DMA program at @code_off with its data {@src, control} at @data_off */
static void pds_dma(uint32_t code_off, uint32_t data_off, uint64_t src, unsigned int dwords)
{
	uint32_t data[4] = { (uint32_t)src, (uint32_t)(src >> 32), doutd_ctrl(0, dwords), 0 };
	uint32_t prog[2] = { g9p_pds_dout(G9P_DOUTD, 0, G9P_PDS_DATA, 2, G9P_PDS_END),
			     g9p_pds_halt() };

	put_code(data_off, data, sizeof(data));
	put_code(code_off, prog, sizeof(prog));
}

static void pds_programs(uint64_t data_base)
{
	const uint32_t halt = g9p_pds_halt();
	const uint32_t vs[3] = {
		g9p_pds_dout(G9P_DOUTW, 0, G9P_PDS_TEMPS, 2, 0),	/* vertex index -> r0 */
		g9p_pds_dout(G9P_DOUTU, 0, G9P_PDS_DATA, 0, G9P_PDS_END | G9P_PDS_CC),
		g9p_pds_halt(),
	};
	const uint32_t vs_data[4] = { USC_VS, getenv("TRI_VS_TEMPS") ?
					     strtoul(getenv("TRI_VS_TEMPS"), NULL, 16) : 0x10,
				      0x80000000u, 0 };
	const uint32_t eot[3] = {
		g9p_pds_dout(G9P_DOUTD, 0, G9P_PDS_DATA, 2, 0),		/* image state */
		g9p_pds_dout(G9P_DOUTU, 2, G9P_PDS_DATA, 0, G9P_PDS_END),
		g9p_pds_halt(),
	};
	const uint64_t image = data_base + D_IMAGE;
	const uint32_t eot_data[8] = { (uint32_t)image, (uint32_t)(image >> 32), doutd_ctrl(0, 7), 0,
				       USC_EOT, 0x10, 0, 0 };

	pds_kick(PDS_FS, USC_FS, 0);
	if (getenv("TRI_FS_TEMPS")) {	/* the fragment kick's second data word (0x10) */
		uint32_t t = strtoul(getenv("TRI_FS_TEMPS"), NULL, 16);

		put_code(PDS_FS + 4, &t, 4);
	}
	put_code(PDS_HALT, &halt, 4);
	put_code(PDS_VS_CODE, vs, sizeof(vs));
	put_code(PDS_VS_DATA, vs_data, sizeof(vs_data));
	pds_dma(PDS_DMA_CODE, PDS_DMA_DATA, data_base + D_VS_UNIFORMS, 2 + 2 * n_vary);
	if (n_vary) {
		/*
		 * DOUTI (RENDER.md "Varyings and textures"): first the W iterate,
		 * then per perspective-correct vec4 varying v: word 0 = 0x030d0000
		 * | location in both low bytes (2 + 8v: halves, after the 4
		 * components of each earlier one), word 1 = perspective (bit 22)
		 * | destination (2v, units of 2 components) << 23 | last << 31.
		 */
		uint32_t vdata[2 * 3] = { 0x03000000, 0 }, vcode[4];
		unsigned int v, n = 0, size = (8 * (n_vary + 1) + 15) / 16 * 16;

		for (v = 0; v < n_vary; v++) {
			unsigned int loc = 2 + 8 * v;

			/* TRI_TEX: varying 0 as a vec2 (x, y), as the tex capture's uv */
			vdata[2 + 2 * v] = (tex && !getenv("TRI_TEX_VEC4") ? 0x03050000 : 0x030d0000) |
					   loc << 8 | loc;
			vdata[3 + 2 * v] = 0x00400000 | (2 * v) << 23 | (v + 1 == n_vary ? 1u << 31 : 0);
		}
		for (v = 0; v <= n_vary; v++)
			vcode[n++] = g9p_pds_dout(4, v, G9P_PDS_DATA, 0, v == n_vary ? G9P_PDS_END : 0);
		vcode[n++] = g9p_pds_halt();
		put_code(PDS_VARYING, vdata, 8 * (n_vary + 1));
		put_code(PDS_VARYING + size, vcode, 4 * n);
	}
	if (tex) {
		/*
		 * Texture state (8 dwords) to common-store dwords 0-7, the sampler
		 * (2) to 8-9: DOUTD controls 0x10000008 and 0x90010002, as captured
		 */
		const uint64_t state = data_base + D_TEX_STATE, sampler = state + 0x20;
		/* TRI_TEX_BASE=N: the state at common-store dword N, the sampler at N + 8 */
		const unsigned int base = getenv("TRI_TEX_BASE") ? atoi(getenv("TRI_TEX_BASE")) : 0;
		/* TRI_TEX_SAMP=N: the sampler's dword (default base + 8) */
		const unsigned int samp = getenv("TRI_TEX_SAMP") ? atoi(getenv("TRI_TEX_SAMP")) : base + 8;
		const uint32_t tdata[8] = { (uint32_t)state, (uint32_t)(state >> 32),
					    (uint32_t)sampler, (uint32_t)(sampler >> 32),
					    1u << 28 | base << 13 | 8, 0,
					    getenv("TRI_TEX_DUP") ? 1u << 28 | samp << 13 | 2 : doutd_ctrl(samp, 2),
					    doutd_ctrl(0, 8) };
		/*
		 * TRI_TEX_DUP=1: a third DMA of the state to dword 0 too;
		 * TRI_TEX_W2BASE=N: the sample's state field (default base)
		 */
		const int dup = getenv("TRI_TEX_DUP") != NULL;
		const uint32_t tcode[4] = {
			g9p_pds_dout(G9P_DOUTD, 0, G9P_PDS_DATA, 4, 0),
			g9p_pds_dout(G9P_DOUTD, 1, G9P_PDS_DATA, 6, dup ? 0 : G9P_PDS_END),
			dup ? g9p_pds_dout(G9P_DOUTD, 0, G9P_PDS_DATA, 7, G9P_PDS_END) : g9p_pds_halt(),
			g9p_pds_halt(),
		};

		put_code(PDS_TEX_DMA_DATA, tdata, sizeof(tdata));
		put_code(PDS_TEX_CODE, tcode, sizeof(tcode));
	}
	pds_kick(PDS_BG, USC_CLEAR, 0);
	pds_dma(PDS_BG_DMA, PDS_BG_DATA, data_base + D_CLEAR, 4);
	put_code(PDS_EOT_CODE, eot, sizeof(eot));
	put_code(PDS_EOT_DATA, eot_data, sizeof(eot_data));
	pds_kick(PDS_VDM_END, USC_VDM_END, 0);
	put_code(PDS_CTX_CODE, &halt, 4);
	put_code(PDS_STREAM_OUT + 0x10, &halt, 4);
}

/* --- Data: vertices, image state, PPP state, VDM stream ------------------ */

/*
 * Image state of the render target (RENDER.md "Texture descriptors"):
 * width - 1 in bits 27-40, height - 1 in bits 41-54, the address >> 1 in
 * dwords 2-3 with bit 63 set; the low bits of dword 0 (`0x0305050a`:
 * format, twiddled) as captured for BGRA8.
 */
static void image_state(uint32_t *w, uint64_t addr)
{
	memset(w, 0, 7 * 4);
	w[0] = 0x0305050au | (W - 1) << 27;
	w[1] = (W - 1) >> 5 | (H - 1) << 9;
	w[2] = (uint32_t)(addr >> 1);
	w[3] = 0x80000000u | (uint32_t)(addr >> 33);
}

/* PPP blocks as in Mesa's csbgen/rogue/ppp.xml (RENDER.md "Own programs") */
struct ppp {
	uint32_t off, n;
};

static uint32_t *stream_word;

static void vdm(uint32_t w)
{
	*stream_word++ = w;
}

static void vdm_ppp(uint8_t *data, uint64_t base, uint32_t *at, const uint32_t *words, uint32_t n)
{
	uint64_t addr = base + *at;

	memcpy(data + *at, words, 4 * n);
	*at += (4 * n + 15) & ~15u;
	vdm(n << 8 | (uint32_t)(addr >> 32));	/* PPP_STATE: word count, address 39:32 */
	vdm((uint32_t)addr);
}

static void build_stream(uint8_t *data, uint64_t base)
{
	/* varying words 0-2: f32_linear = the varyings' components */
	const uint32_t varying[4] = { 0x001c0000, 4 * n_vary, 0, 0 };
	/*
	 * SIZEINFO1: uniform size 1, PDS varying data in 16-byte units, USC
	 * varying size (2 for one vec4 as captured; 4 for two: a guess)
	 */
	const uint32_t vary_units = (8 * (n_vary + 1) + 15) / 16;
	const uint32_t pds[6] = { 0xc0, PDS_FS, tex ? PDS_TEX_CODE : PDS_HALT,
				  (tex ? 0x01000000 : 0x00800000) |
				  (n_vary ? vary_units << 10 | (2 * n_vary) << 4 : 0),
				  /* SIZEINFO2: USC shared size, 64-byte units */
				  tex ? 3u << 23 : 0,
				  n_vary ? PDS_VARYING : PDS_HALT };
	const uint32_t uniform_base[2] = { 0x200, PDS_TEX_DMA_DATA };	/* UNIFORMDATABASE */
	const uint32_t outsel[2] = { 0x00020000, (4 + 4 * n_vary) << 24 | 0x00010000 };	/* vertex size, rhw */
	/* TRI_PASS=N: ISPA/BA pass type (1 translucent: shaders reading the tile) */
	const uint32_t pass = getenv("TRI_PASS") ? strtoul(getenv("TRI_PASS"), NULL, 0) << 24 : 0;
	const uint32_t isp[6] = { 0x1f, 0x03c40000, 0x003e0f00 | pass, 0x0e000000, 0x00100f00 | pass, 0 };
	const uint32_t viewport[9] = {
		0xc00, 0x80000001, 0x00000001,	/* region clip */
		f2u(W / 2.0f), f2u(W / 2.0f), f2u(H / 2.0f), f2u(-(H / 2.0f)), 0, f2u(1.0f),
	};
	const uint32_t ctrl[3] = { 0x00210000, 0x1e3ce508, 0x4a0 };	/* wclamp 1e-20, PPP_CTRL */
	const uint32_t dbsc[2] = { 0x20, 0 };
	const uint32_t stream_out[4] = { 0x00c00000, 1, 0x4022, PDS_STREAM_OUT };
	const uint32_t terminate[3] = { 0x02000000, (W / 32 - 1) << 18 | (H / 32 - 1), 0 };
	uint32_t at = D_PPP;

	stream_word = (uint32_t *)(data + D_STREAM);
	/* VDM_STATE: vertex PDS code, 4 outputs, USC sizes (as captured) */
	vdm(0x44002f80);
	vdm(PDS_VS_CODE);
	vdm(4 + 4 * n_vary);	/* vertex output dwords */
	/* TRI_VDM5=HEX: the sizes word (as captured 0x1081) */
	vdm(getenv("TRI_VDM5") ? strtoul(getenv("TRI_VDM5"), NULL, 16) : 0x1081);
	vdm_ppp(data, base, &at, varying, 4);
	/* PDS_STATE: the vertex-buffer DMA into the common store */
	vdm(getenv("TRI_PDS_STATE0") ? strtoul(getenv("TRI_PDS_STATE0"), NULL, 16) : 0x20020001);
	vdm(PDS_DMA_DATA);
	vdm(PDS_DMA_CODE);
	vdm(0x48002f80);	/* VDM_STATE: vertex PDS data */
	vdm(PDS_VS_DATA);
	vdm_ppp(data, base, &at, pds, 6);
	if (tex)
		vdm_ppp(data, base, &at, uniform_base, 2);
	vdm_ppp(data, base, &at, outsel, 2);
	vdm_ppp(data, base, &at, isp, 6);
	vdm_ppp(data, base, &at, viewport, 9);
	vdm_ppp(data, base, &at, ctrl, 3);
	vdm_ppp(data, base, &at, dbsc, 2);
	vdm_ppp(data, base, &at, stream_out, 4);
	/* INDEX_LIST: triangle list, 3 vertices, no index buffer */
	if (!getenv("TRI_NODRAW")) {
		vdm(0x6e440600);
		vdm(3);
		vdm(0);
		vdm(0);
		vdm(0xaa);
	}
	vdm_ppp(data, base, &at, terminate, 3);
	vdm(0xc0000000);	/* STREAM_TERMINATE */
}

/* --- Job streams (kernel UAPI, Apple extension) --------------------------- */

struct stream {
	uint8_t buf[2048];
	uint32_t len;
};

static void put(struct stream *s, const void *p, uint32_t size, uint32_t align)
{
	s->len = (s->len + align - 1) & ~(align - 1);
	memcpy(s->buf + s->len, p, size);
	s->len += size;
}

static void put32(struct stream *s, uint32_t v) { put(s, &v, 4, 4); }
static void put64(struct stream *s, uint64_t v) { put(s, &v, 8, 8); }
static void put_array(struct stream *s, const void *p, uint32_t size) { put(s, p, size, 8); }

static void stream_begin(struct stream *s)
{
	memset(s, 0, sizeof(*s));
	s->len = 8;
}

static void stream_main_end(struct stream *s)
{
	*(uint32_t *)s->buf = s->len;
}

#define EXTHDR_APPLE	(1u << 29 | 1u)

/* A PDS program pair as the context store/resume registers take it */
static uint64_t ctx_pds_size(uint64_t sizes, uint32_t data)
{
	return (uint64_t)data << 32 | sizes;
}

static void geom_stream(struct stream *s, uint64_t data_base)
{
	const uint64_t store[3] = { 0x0003000524001002ull, PDS_CTX_CODE,
				    ctx_pds_size(0x4820, PDS_CTX_DATA) };
	const uint64_t resume[3] = { 0x0003002121001002ull, PDS_CTX_CODE,
				     ctx_pds_size(0x4820, PDS_CTX_DATA) };
	const uint64_t pds_state[6] = { ctx_pds_size(0x20000001, PDS_CTX_DATA | 5), PDS_CTX_CODE,
					ctx_pds_size(0x20000001, PDS_CTX_DATA | 1), PDS_CTX_CODE,
					0, 0 };
	const uint64_t ctx_state[2] = { data_base + D_CTX_STATE + 0x200, data_base + D_CTX_STATE };
	const uint64_t cluster[6] = { 0 };

	stream_begin(s);
	put64(s, data_base + D_STREAM);	/* vdm_ctrl_stream_base */
	put64(s, 0);			/* tpu_border_colour_table */
	put32(s, 2);			/* ppp_ctrl */
	put32(s, getenv("TRI_TE_PSG") ? strtoul(getenv("TRI_TE_PSG"), NULL, 16) : 0x20000);	/* te_psg */
	put32(s, 0);
	put32(s, 0);
	stream_main_end(s);
	put32(s, EXTHDR_APPLE);
	put64(s, 0x1e3ce508);		/* 0xc90 */
	put_array(s, ctx_state, sizeof(ctx_state));
	put_array(s, store, sizeof(store));
	put_array(s, resume, sizeof(resume));
	put64(s, PDS_VDM_END);		/* 0x470 */
	put64(s, 0);			/* 0x418 */
	put_array(s, pds_state, sizeof(pds_state));
	put_array(s, cluster, sizeof(cluster));
	put32(s, 0x88);			/* 0xc78 */
}

static void frag_stream(struct stream *s)
{
	static const uint64_t pbe_words[8 * 3], bgnd3[3];
	static const uint32_t clear_regs[8];
	const uint64_t bgnd[4] = { (uint64_t)PDS_BG_DMA << 32 | PDS_BG, 0, PDS_BG_DATA,
				   0x0080000000800000ull };
	static const uint32_t line[6] = { 0x3b89309c, 0x3b89309c, 0x3cddb3d9, 0x3cddb3d9,
					  0x44800000, 0x3b89309c };
	uint64_t cluster0[6] = { 0 }, cluster1[6];
	unsigned int i;

	for (i = 0; i < 6; i++)
		cluster1[i] = 0x1d3;
	stream_begin(s);
	for (i = 0; i < 6; i++)
		put64(s, 0);		/* ISP scissor/dbias/oclqry/zls bases */
	put_array(s, pbe_words, sizeof(pbe_words));
	put64(s, 0);
	put_array(s, bgnd3, sizeof(bgnd3));
	put_array(s, bgnd3, sizeof(bgnd3));
	put_array(s, clear_regs, sizeof(clear_regs));
	put32(s, 0);
	put32(s, 0x3f800000);		/* isp_bgobjdepth */
	put32(s, 0x300);		/* isp_bgobjvals */
	put32(s, 0);
	put32(s, getenv("TRI_ISP_CTL") ? strtoul(getenv("TRI_ISP_CTL"), NULL, 16) : 0x21000f);	/* isp_ctl */
	put32(s, 0x402);		/* event_pixel_pds_info */
	put32(s, 0);
	put32(s, PDS_EOT_DATA);		/* event_pixel_pds_data */
	put32(s, 0);
	put32(s, 0);
	stream_main_end(s);
	put32(s, EXTHDR_APPLE);
	put64(s, 0x88);			/* 0xfa8 */
	put_array(s, bgnd, sizeof(bgnd));
	put_array(s, cluster0, sizeof(cluster0));
	put_array(s, cluster1, sizeof(cluster1));
	put64(s, 0);			/* 0xfd0 */
	put32(s, PDS_EOT_CODE);		/* 0x618 end-of-tile PDS code */
	put32(s, 0x14);			/* 0xf28 ISP_RGN */
	put32(s, 0x1f);			/* 0x6d0 */
	put32(s, 0x408);		/* 0x3e00 */
	put32(s, 4);			/* 0xfd8 */
	put32(s, 0xf9);			/* 0x4070 */
	put_array(s, line, sizeof(line));
}

/* Target pixel index: Morton order, y bit first (RENDER.md "Resized render") */
static unsigned int morton(unsigned int x, unsigned int y)
{
	unsigned int i, m = 0;

	for (i = 0; i < 6; i++)
		m |= ((y >> i) & 1) << (2 * i) | ((x >> i) & 1) << (2 * i + 1);
	return m;
}

static int parse4(const char *env, float *v)
{
	const char *s = getenv(env);

	return s && sscanf(s, "%f,%f,%f,%f", &v[0], &v[1], &v[2], &v[3]) == 4;
}

int main(int argc, char **argv)
{
	struct drm_pvr_ioctl_create_vm_context_args vm_args = { 0 };
	struct drm_pvr_ioctl_create_free_list_args fl = { 0 };
	struct drm_pvr_ioctl_create_hwrt_dataset_args hwrt = { 0 };
	struct drm_pvr_ioctl_create_context_args ctx = { 0 };
	struct drm_pvr_ioctl_submit_jobs_args submit = { 0 };
	struct drm_pvr_job jobs[2];
	struct bo code_bo[2], data, target, rgn, tpc, mlist, mtile, vheap, rtc, fl_bo;
	struct stream geom, frag;
	float col[4] = { 0.5f, 0.25f, 1.0f, 1.0f }, clear[4] = { 0, 0, 0, 1 };
	const float vertices[6] = { -0.5f, -0.5f, 0.5f, -0.5f, 0.0f, 0.5f };
	uint32_t *pixels, expect_clear, expect_tri;
	unsigned int i, n_clear = 0, n_tri = 0, n_other;
	struct timespec t0, t1;
	double ms;
	FILE *out;

	parse4("TRI_COLOR", col);
	n_vary = getenv("TRI_VARY") ? atoi(getenv("TRI_VARY")) : 0;
	if (getenv("TRI_VS_HEX"))
		n_vary = 1;
	tex = getenv("TRI_TEX") != NULL;
	if (tex)
		n_vary = 1;
	if (n_vary > 2)
		n_vary = 2;
	parse4("TRI_CLEAR", clear);
	fd = open(argc > 2 ? argv[2] : "/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
	if (fd < 0)
		die("open");
	if (ioctl(fd, DRM_IOCTL_PVR_CREATE_VM_CONTEXT, &vm_args))
		die("CREATE_VM_CONTEXT");
	vm = vm_args.handle;
	{
		struct drm_pvr_dev_query_heap_info info = {
			.heaps = { .stride = sizeof(heaps[0]), .count = DRM_PVR_HEAP_COUNT,
				   .array = (uintptr_t)heaps },
		};
		struct drm_pvr_ioctl_dev_query_args q = {
			.type = DRM_PVR_DEV_QUERY_HEAP_INFO_GET,
			.pointer = (uintptr_t)&info,
			.size = sizeof(info),
		};

		if (ioctl(fd, DRM_IOCTL_PVR_DEV_QUERY, &q))
			die("DEV_QUERY heap info");
	}

	/* The code heap: one buffer at both bases, written once, copied */
	code = calloc(1, 0x10000);
	if (!code)
		die("calloc");
	bo_create(&data, DATA, 0x10000, DRM_PVR_BO_ALLOW_CPU_USERSPACE_ACCESS |
					    DRM_PVR_BO_BYPASS_DEVICE_CACHE);
	bo_create(&target, TARGET, W * H * 4, DRM_PVR_BO_ALLOW_CPU_USERSPACE_ACCESS |
					     DRM_PVR_BO_BYPASS_DEVICE_CACHE);
	pixels = (uint32_t *)target.map;
	memset(pixels, 0x55, W * H * 4);

	fs_program(col);
	vs_program(getenv("TRI_W") ? strtof(getenv("TRI_W"), NULL) : 1.0f);
	load_hex("TRI_VS_HEX", USC_VS);
	load_hex("TRI_FS_HEX", USC_FS);
	clear_program();
	eot_program();
	vdm_end_program();
	pds_programs(data.addr);
	for (i = 0; i < 2; i++) {
		bo_create(&code_bo[i], heaps[i ? DRM_PVR_HEAP_USC_CODE : DRM_PVR_HEAP_PDS_CODE_DATA].base,
			  0x10000, DRM_PVR_BO_ALLOW_CPU_USERSPACE_ACCESS |
				   DRM_PVR_BO_BYPASS_DEVICE_CACHE);
		memcpy(code_bo[i].map, code, 0x10000);
	}

	memcpy(data.map + D_VERTICES, vertices, sizeof(vertices));
	{
		/* varying 0: red, green, blue; varying 1: cyan, magenta, yellow */
		static const float colours[2][3][4] = {
			{ { 1, 0, 0, 1 }, { 0, 1, 0, 1 }, { 0, 0, 1, 1 } },
			{ { 0, 1, 1, 1 }, { 1, 0, 1, 1 }, { 1, 1, 0, 1 } },
		};
		uint64_t vb[3] = { data.addr + D_VERTICES, data.addr + D_COLOURS,
				   data.addr + D_COLOURS + sizeof(colours[0]) };

		memcpy(data.map + D_COLOURS, colours, sizeof(colours));
		memcpy(data.map + D_VS_UNIFORMS, vb, sizeof(vb));
		if (getenv("TRI_VS_HEX")) {
			/* interleaved: x, y, r, g, b, a */
			float *v = (float *)(data.map + D_COLOURS + 0x100);

			for (i = 0; i < 3; i++) {
				v[6 * i] = vertices[2 * i];
				v[6 * i + 1] = vertices[2 * i + 1];
				memcpy(&v[6 * i + 2], colours[0][i], 16);
			}
			vb[0] = data.addr + D_COLOURS + 0x100;
			memcpy(data.map + D_VS_UNIFORMS, vb, 8);
		}
	}
	if (tex) {
		/*
		 * Texel (x, y) = 0xff000000 | x * 0x40 << 16 | y * 0x40 << 8 | 0x80,
		 * stored twiddled (Morton order, y bit first, as the render target);
		 * texture state as the tex capture's (`0x0344050a` base, 4x4,
		 * address >> 1), the sampler words as captured (nearest)
		 */
		uint32_t *texels = (uint32_t *)(data.map + D_TEXELS), *t;
		uint64_t a = data.addr + D_TEXELS;
		unsigned int x, y;

		for (y = 0; y < 4; y++)
			for (x = 0; x < 4; x++)
				texels[morton(x, y)] = 0xff000080u | (x * 0x40) << 16 | (y * 0x40) << 8;
		t = (uint32_t *)(data.map + D_TEX_STATE);
		t[0] = 0x0344050au | 3u << 27;
		t[1] = 3u << 9;
		t[2] = (uint32_t)(a >> 1);
		t[3] = (uint32_t)(a >> 33);
		t[8] = 0x000e0000;
		t[9] = 0x00c00780;
		/* TRI_SAMPLER=W0,W1 (hex): the sampler words */
		if (getenv("TRI_SAMPLER"))
			sscanf(getenv("TRI_SAMPLER"), "%x,%x", &t[8], &t[9]);
	}
	memcpy(data.map + D_CLEAR, clear, sizeof(clear));
	image_state((uint32_t *)(data.map + D_IMAGE), target.addr);
	build_stream(data.map, data.addr);

	bo_create(&mlist, RT + 0x000000, 0x10000, DRM_PVR_BO_BYPASS_DEVICE_CACHE);
	bo_create(&mtile, RT + 0x010000, 0x10000, DRM_PVR_BO_BYPASS_DEVICE_CACHE);
	bo_create(&vheap, RT + 0x020000, 0x10000, DRM_PVR_BO_BYPASS_DEVICE_CACHE);
	bo_create(&rtc, RT + 0x030000, 0x10000, DRM_PVR_BO_BYPASS_DEVICE_CACHE);
	bo_create(&rgn, RT + 0x040000, 0x40000, DRM_PVR_BO_BYPASS_DEVICE_CACHE);
	bo_create(&tpc, RT + 0x080000, 0x40000, DRM_PVR_BO_BYPASS_DEVICE_CACHE);
	bo_create(&fl_bo, RT + 0x0c0000, PAGE, DRM_PVR_BO_PM_FW_PROTECT);
	fl.free_list_gpu_addr = fl_bo.addr;
	fl.initial_num_pages = FL_PAGES;
	fl.max_num_pages = FL_PAGES;
	fl.vm_context_handle = vm;
	if (ioctl(fd, DRM_IOCTL_PVR_CREATE_FREE_LIST, &fl))
		die("CREATE_FREE_LIST");
	hwrt.geom_data_args.tpc_dev_addr = tpc.addr;
	hwrt.geom_data_args.tpc_size = tpc.size;
	hwrt.geom_data_args.tpc_stride = 1;
	hwrt.geom_data_args.vheap_table_dev_addr = vheap.addr;
	hwrt.geom_data_args.rtc_dev_addr = rtc.addr;
	for (i = 0; i < 2; i++) {
		hwrt.rt_data_args[i].pm_mlist_dev_addr = mlist.addr;
		hwrt.rt_data_args[i].macrotile_array_dev_addr = mtile.addr;
		hwrt.rt_data_args[i].region_header_dev_addr = rgn.addr;
		hwrt.free_list_handles[i] = fl.handle;
	}
	hwrt.width = W;
	hwrt.height = H;
	hwrt.samples = 1;
	hwrt.layers = 1;
	hwrt.region_header_size = rgn.size;
	if (ioctl(fd, DRM_IOCTL_PVR_CREATE_HWRT_DATASET, &hwrt))
		die("CREATE_HWRT_DATASET");
	ctx.type = DRM_PVR_CTX_TYPE_RENDER;
	ctx.priority = DRM_PVR_CTX_PRIORITY_NORMAL;
	ctx.vm_context_handle = vm;
	if (ioctl(fd, DRM_IOCTL_PVR_CREATE_CONTEXT, &ctx))
		die("CREATE_CONTEXT");

	geom_stream(&geom, data.addr);
	frag_stream(&frag);
	memset(jobs, 0, sizeof(jobs));
	jobs[0].type = DRM_PVR_JOB_TYPE_GEOMETRY;
	jobs[0].flags = DRM_PVR_SUBMIT_JOB_GEOM_CMD_FIRST | DRM_PVR_SUBMIT_JOB_GEOM_CMD_LAST;
	jobs[0].cmd_stream = (uintptr_t)geom.buf;
	jobs[0].cmd_stream_len = geom.len;
	jobs[1].type = DRM_PVR_JOB_TYPE_FRAGMENT;
	jobs[1].cmd_stream = (uintptr_t)frag.buf;
	jobs[1].cmd_stream_len = frag.len;
	for (i = 0; i < 2; i++) {
		jobs[i].context_handle = ctx.handle;
		jobs[i].hwrt.set_handle = hwrt.handle;
		jobs[i].sync_ops.stride = sizeof(struct drm_pvr_sync_op);
	}
	submit.jobs.stride = sizeof(jobs[0]);
	submit.jobs.count = 2;
	submit.jobs.array = (uintptr_t)jobs;

	/* BGRA8 target: 0xAARRGGBB of the rounded unorm values */
	expect_clear = (uint32_t)(clear[3] * 255 + 0.5f) << 24 | (uint32_t)(clear[0] * 255 + 0.5f) << 16 |
		       (uint32_t)(clear[1] * 255 + 0.5f) << 8 | (uint32_t)(clear[2] * 255 + 0.5f);
	expect_tri = (uint32_t)(col[3] * 255 + 0.5f) << 24 | (uint32_t)(col[0] * 255 + 0.5f) << 16 |
		     (uint32_t)(col[1] * 255 + 0.5f) << 8 | (uint32_t)(col[2] * 255 + 0.5f);
	clock_gettime(CLOCK_MONOTONIC, &t0);
	if (ioctl(fd, DRM_IOCTL_PVR_SUBMIT_JOBS, &submit))
		die("SUBMIT_JOBS");
	do {
		n_clear = n_tri = 0;
		for (i = 0; i < W * H; i++) {
			n_clear += pixels[i] == expect_clear;
			n_tri += pixels[i] == expect_tri;
		}
		n_other = W * H - n_clear - n_tri;
		clock_gettime(CLOCK_MONOTONIC, &t1);
		ms = (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6;
	} while (n_clear + n_tri < W * H && ms < 3000);

	for (i = 0; i < W * H; i++)
		if (pixels[i] != expect_clear && pixels[i] != expect_tri) {
			printf("first other pixel: %u: %#010x\n", i, pixels[i]);
			break;
		}
	printf("target: %u clear (%#010x), %u triangle (%#010x), %u other after %.1f ms: %s\n",
	       n_clear, expect_clear, n_tri, expect_tri, n_other, ms,
	       n_clear == 3584 && n_tri == 512 ? "PASS" : "FAIL");
	if (argc > 1 && (out = fopen(argv[1], "wb"))) {
		fwrite(pixels, 4, W * H, out);
		fclose(out);
	}
	if (getenv("TRI_FS_COORD")) {
		/* triangle pixels: red = (x + 0.5) / 64, green = (y + 0.5) / 64 */
		static const unsigned int at[3][2] = { { 19, 46 }, { 45, 46 }, { 32, 19 } };

		for (i = 0; i < 3; i++) {
			uint32_t p = pixels[morton(at[i][0], at[i][1])];

			printf("pixel (%u,%u): %#010x (want r %02x g %02x)\n", at[i][0], at[i][1], p,
			       (unsigned int)((at[i][0] + 0.5f) / 64 * 255 + 0.5f),
			       (unsigned int)((at[i][1] + 0.5f) / 64 * 255 + 0.5f));
		}
	}
	if (tex) {
		/* distinct colours inside the triangle: 16 at most when nearest */
		uint32_t seen[512];
		unsigned int n_seen = 0, j;

		for (i = 0; i < W * H; i++) {
			if (pixels[i] == expect_clear)
				continue;
			for (j = 0; j < n_seen && seen[j] != pixels[i]; j++)
				;
			if (j == n_seen && n_seen < 512)
				seen[n_seen++] = pixels[i];
		}
		printf("texture: %u distinct colours\n", n_seen);
	}
	if (n_vary) {
		/* near the vertices (screen (16,48), (48,48), (32,16)) */
		static const unsigned int at[3][2] = { { 19, 46 }, { 45, 46 }, { 32, 19 } };

		for (i = 0; i < 3; i++)
			printf("pixel (%u,%u): %#010x\n", at[i][0], at[i][1],
			       pixels[morton(at[i][0], at[i][1])]);
		return n_clear == 3584 ? 0 : 1;
	}
	return n_clear == 3584 && n_tri == 512 ? 0 : 1;
}
