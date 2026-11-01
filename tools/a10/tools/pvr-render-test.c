// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * Userspace render test for the Apple A10 powervr variant: the iPadOS
 * triangle (apple/gpu-tri.bin, tools/tri-blob.py) rendered through the powervr
 * UAPI only, the way Mesa would submit it: buffers mapped with VM_MAP, a free
 * list and HWRT dataset, a render context, and one SUBMIT_JOBS with a
 * geometry and a fragment job carrying the Apple stream extension.
 *
 * The capture's buffers live at GPU 0x1_000xxxxx, below powervr's heaps, so
 * they are moved to the general heap (keeping their low 32 bits; the heap
 * layout comes from DRM_PVR_DEV_QUERY_HEAP_INFO_GET) and the addresses in
 * them relocated: 64-bit pointers, VDM stream words carrying address bits
 * 32-39 in their low byte before bits 0-31, PDS DMA words carrying them after,
 * and image descriptors (address >> 1, bit 63 set).
 * Code-heap regions are offsets from the PDS and USC bases and are mapped at
 * both, unchanged.
 *
 * Build (static, arm64): tools/build-pvr-compute-test.sh pvr-render-test
 * Run: pvr-render-test [OUT.bin] [/dev/dri/renderD128]
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
#define IOS_DATA	0x100000000ull	/* the capture's data window */
#define RELOC		(heaps[DRM_PVR_HEAP_GENERAL].base - IOS_DATA)
#define PDS_HEAP	heaps[DRM_PVR_HEAP_PDS_CODE_DATA].base
#define USC_HEAP	heaps[DRM_PVR_HEAP_USC_CODE].base
#define IOS_RECORD	0x200004000ull	/* R9, the userspace record: not GPU-read */
#define IOS_STREAM	0x100040000ull	/* R10, VDM control stream */
#define IOS_IMAGES	0x100064000ull	/* R13, image descriptors */
#define IOS_TEXTURES	0x100100000ull	/* R18, texture + sampler descriptors (tex capture) */
#define IOS_TARGET	0x100014000ull	/* R4, 64x64 RGBA8 render target */
#define RT		(heaps[DRM_PVR_HEAP_GENERAL].base + 0x200000000ull)	/* HWRT buffers, free list */
#define FL_PAGES	1024u

struct bo {
	uint32_t handle;
	uint8_t *map;
	uint64_t addr, size;
};

struct region {
	uint64_t gpu;
	uint32_t size, code;
	uint8_t *data;
	struct bo bo[2];
};

static int fd;
static uint32_t vm;
static struct drm_pvr_heap heaps[DRM_PVR_HEAP_COUNT];
static struct region regions[32];
static unsigned int nregions;

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

static int ios_data(uint64_t addr)
{
	unsigned int i;

	for (i = 0; i < nregions; i++)
		if (!regions[i].code && regions[i].gpu != IOS_RECORD &&
		    addr >= regions[i].gpu && addr < regions[i].gpu + regions[i].size)
			return 1;
	return 0;
}

/* Move the capture's data addresses into the general heap */
static void relocate(struct region *r)
{
	uint32_t *w = (uint32_t *)r->data;
	unsigned int i, n = r->size / 4;

	for (i = 0; i + 1 < n; i++) {
		uint64_t addr;

		if (r->gpu == IOS_STREAM) {
			/* VDM words: address bits 32-39 in the low byte, then bits 0-31 */
			addr = (uint64_t)(w[i] & 0xff) << 32 | w[i + 1];
			if ((w[i] & 0xff) == 1 && ios_data(addr))
				w[i] = (w[i] & ~0xffu) | (uint32_t)((addr + RELOC) >> 32);
			continue;
		}
		/*
		 * Texture descriptor word 2: the texel address >> 1 (bits 1-32),
		 * word 3 assumed to continue it (0 in the capture: open).
		 */
		if (r->gpu == IOS_TEXTURES && i % 8 == 2 && w[i - 2] && ios_data((uint64_t)w[i] << 1)) {
			addr = (((uint64_t)w[i + 1] << 32 | w[i]) << 1) + RELOC;
			w[i] = (uint32_t)(addr >> 1);
			w[i + 1] = (uint32_t)(addr >> 33);
			i++;
			continue;
		}
		if (r->gpu == IOS_IMAGES && !(i & 1) && (w[i + 1] & 0x80000000)) {
			addr = ((uint64_t)(w[i + 1] & 0x7fffffff) << 32 | w[i]) << 1;
			if (ios_data(addr)) {
				addr = (addr + RELOC) >> 1;
				w[i] = (uint32_t)addr;
				w[i + 1] = 0x80000000 | (uint32_t)(addr >> 32);
				i++;
			}
			continue;
		}
		addr = (uint64_t)w[i + 1] << 32 | w[i];
		if (w[i + 1] == 1 && ios_data(addr)) {
			addr += RELOC;
			w[i] = (uint32_t)addr;
			w[i + 1] = (uint32_t)(addr >> 32);
			i++;
			continue;
		}
		/*
		 * PDS DMA words: address bits 0-31, then bits 32-39 in the low
		 * byte. Only in the PDS data regions: R2 also holds PDS code,
		 * whose DOUT instructions look alike.
		 */
		addr = (uint64_t)(w[i + 1] & 0xff) << 32 | w[i];
		if (r->code && r->gpu && w[i] && (w[i + 1] & 0xff) == 1 && ios_data(addr)) {
			w[i + 1] = (w[i + 1] & ~0xffu) | (uint32_t)((addr + RELOC) >> 32);
			i++;
		}
	}
}

static void load_capture(const char *path)
{
	FILE *f = fopen(path, "rb");
	uint32_t count, i;
	char magic[4];

	if (!f || fread(magic, 4, 1, f) != 1 || memcmp(magic, "TRI1", 4) ||
	    fread(&count, 4, 1, f) != 1)
		die(path);
	for (i = 0; i < count && i < 32; i++) {
		struct region *r = &regions[nregions];

		if (fread(&r->gpu, 8, 1, f) != 1 || fread(&r->size, 4, 1, f) != 1 ||
		    fread(&r->code, 4, 1, f) != 1)
			die("region header");
		r->data = malloc(r->size);
		if (!r->data || fread(r->data, r->size, 1, f) != 1)
			die("region data");
		nregions++;
	}
	fclose(f);
}

/* Command streams: fields in the kernel's stream order, naturally aligned */
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
	s->len = 8;	/* {u32 main length, u32 0} */
}

static void stream_main_end(struct stream *s)
{
	*(uint32_t *)s->buf = s->len;
}

/*
 * A 64-bit word of the capture's userspace record (R9), where iPadOS keeps
 * the register values of the pass: PDS program offsets move with the code
 * heap layout (one more shader block shifts them by 0x40), so they are read
 * from the capture instead of being fixed to the base one.
 */
static uint64_t rec64(uint32_t off)
{
	unsigned int i;

	for (i = 0; i < nregions; i++)
		if (regions[i].gpu == IOS_RECORD)
			return *(uint64_t *)(regions[i].data + off);
	die("no record region");
	return 0;
}

/* Extension header type 1: the Apple register block, which must be present */
#define EXTHDR_APPLE	(1u << 29 | 1u)

static void geom_stream(struct stream *s)
{
	/* Record +0x58/+0x70: {0x0003000524001002, 0x900, 0x0000091000004820} in base */
	const uint64_t store[3] = { rec64(0x58), rec64(0x60), rec64(0x68) };
	const uint64_t resume[3] = { rec64(0x70), rec64(0x78), rec64(0x80) };
	const uint64_t pds_state[6] = { rec64(0x98), rec64(0xa0), rec64(0xb0), rec64(0xb8), 0, 0 };
	uint64_t ctx_state[2] = { 0x10014e240ull + RELOC, 0x10014e040ull + RELOC };
	uint64_t cluster[6] = { 0 };

	stream_begin(s);
	put64(s, IOS_STREAM + RELOC);	/* vdm_ctrl_stream_base */
	put64(s, 0);			/* tpu_border_colour_table */
	put32(s, 2);			/* ppp_ctrl */
	put32(s, 0x20000);		/* te_psg: complete on terminate */
	put32(s, 0);			/* vdm_context_resume_task0_size */
	put32(s, 0);			/* view_idx */
	stream_main_end(s);
	put32(s, EXTHDR_APPLE);
	put64(s, 0x1e3ce508);		/* 0xc90 PDS_CTRL */
	put_array(s, ctx_state, sizeof(ctx_state));
	put_array(s, store, sizeof(store));
	put_array(s, resume, sizeof(resume));
	put64(s, rec64(0x30));		/* 0x470, 0x640 in base */
	put64(s, 0);			/* 0x418 */
	put_array(s, pds_state, sizeof(pds_state));
	put_array(s, cluster, sizeof(cluster));
	put32(s, 0x88);			/* 0xc78 */
}

static void frag_stream(struct stream *s)
{
	static const uint64_t pbe_words[8 * 3], bgnd3[3];
	static const uint32_t clear_regs[8];
	/* Record +0x280: {0x000026c000002740, 0, 0x3c030, 0x0080000000800000} in base */
	const uint64_t bgnd[4] = { rec64(0x280), rec64(0x288), rec64(0x290), rec64(0x298) };
	static const uint32_t line[6] = { 0x3b89309c, 0x3b89309c, 0x3cddb3d9, 0x3cddb3d9,
					  0x44800000, 0x3b89309c };
	uint64_t cluster0[6] = { 0 }, cluster1[6];
	unsigned int i;

	for (i = 0; i < 6; i++)
		cluster1[i] = 0x1d3;
	stream_begin(s);
	put64(s, 0);			/* isp_scissor_base */
	put64(s, 0);			/* isp_dbias_base */
	put64(s, 0);			/* isp_oclqry_base */
	put64(s, 0);			/* isp_zlsctl */
	put64(s, 0);			/* isp_zload_store_base */
	put64(s, 0);			/* isp_stencil_load_store_base */
	put_array(s, pbe_words, sizeof(pbe_words));
	put64(s, 0);			/* tpu_border_colour_table */
	put_array(s, bgnd3, sizeof(bgnd3));	/* pds_bgnd: see the extension */
	put_array(s, bgnd3, sizeof(bgnd3));	/* pds_pr_bgnd */
	put_array(s, clear_regs, sizeof(clear_regs));
	put32(s, 0);			/* usc_pixel_output_ctrl */
	put32(s, 0x3f800000);		/* isp_bgobjdepth */
	put32(s, 0x300);		/* isp_bgobjvals */
	put32(s, 0);			/* isp_aa */
	put32(s, 0x21000f);		/* isp_ctl */
	put32(s, (uint32_t)(rec64(0x2b8)));	/* event_pixel_pds_info, 0x402 */
	put32(s, 0);			/* view_idx */
	put32(s, (uint32_t)rec64(0x2b0));	/* event_pixel_pds_data, 0x3c040 */
	put32(s, 0);			/* zls_stride */
	put32(s, 0);			/* sls_stride */
	stream_main_end(s);
	put32(s, EXTHDR_APPLE);
	put64(s, 0x88);			/* 0xfa8 sample positions */
	put_array(s, bgnd, sizeof(bgnd));
	put_array(s, cluster0, sizeof(cluster0));
	put_array(s, cluster1, sizeof(cluster1));
	put64(s, 0);			/* 0xfd0 */
	put32(s, (uint32_t)(rec64(0x2b0) >> 32));	/* 0x618 end-of-tile PDS code, 0x2a40 */
	put32(s, 0x14);			/* 0xf28 ISP_RGN */
	put32(s, 0x1f);			/* 0x6d0 */
	put32(s, 0x408);		/* 0x3e00 */
	put32(s, 4);			/* 0xfd8 */
	put32(s, 0xf9);			/* 0x4070 */
	put_array(s, line, sizeof(line));
}

/* IEEE half from float (normal range, round to nearest) */
static uint16_t half(float f)
{
	uint32_t u;
	int e;

	memcpy(&u, &f, 4);
	e = (int)((u >> 23) & 0xff) - 127 + 15;
	if (e <= 0)
		return (u >> 16) & 0x8000;
	return ((u >> 16) & 0x8000) | e << 10 | (((u >> 13) + ((u >> 12) & 1)) & 0x3ff);
}

/* G9P 32-bit move-immediate into register @dst (ISA.md "Move immediate") */
static void mov_imm(uint16_t *w, unsigned dst, uint32_t imm)
{
	w[0] = 0x0198 | ((imm >> 9) & 1) << 13;
	/* FS_HALFFORM: W1 0x01xx as Apple's fragment code writes it */
	w[1] = (getenv("FS_HALFFORM") ? 0x0100 : 0x0300) | 2 * dst;
	w[2] = 0x0101 | (imm & 0x3f) << 1;
	w[3] = 0x0120 | ((imm >> 6) & 7) << 1 | ((imm >> 10) & 1) << 4 | ((imm >> 14) & 1) << 6 |
	       ((imm >> 15) & 1) << 7 | ((imm >> 11) & 7) << 12 | 1 | ((imm >> 24) & 1) << 15;
	w[4] = 0x0100 | ((imm >> 16) & 0xff) | ((imm >> 25) & 0x7f) << 9;
	w[5] = 0x0154;
	w[6] = 0x0038;
}

/*
 * FS_COLOR=r,g,b,a: replace the captured fragment shader's two colour moves
 * (packed halves into r0 and r1, then `211c 0800` writes them) with our own
 * encoding of another colour, in place (both are 7 words).
 */
static int patch_fs_color(uint8_t *usc, uint64_t size, const char *spec)
{
	static const uint16_t fs[] = {
		0x0198, 0x0100, 0x0101, 0x6131, 0x3900, 0x0154, 0x0038,
		0x2198, 0x0102, 0x0101, 0x7121, 0x3d00, 0x0154, 0x0038, 0x211c, 0x0800,
	};
	float c[4];
	uint64_t o;

	if (sscanf(spec, "%f,%f,%f,%f", &c[0], &c[1], &c[2], &c[3]) != 4)
		return 0;
	for (o = 0; o + sizeof(fs) <= size; o += 2) {
		if (memcmp(usc + o, fs, sizeof(fs)))
			continue;
		mov_imm((uint16_t *)(usc + o), 0, half(c[0]) | (uint32_t)half(c[1]) << 16);
		mov_imm((uint16_t *)(usc + o + 14), 1, half(c[2]) | (uint32_t)half(c[3]) << 16);
		return 1;
	}
	return 0;
}

/*
 * FS_CODE=w,w,...: the blend capture's fragment shader (it starts with the
 * tile read 211c 2800 004d) replaced in place by these 16-bit words, the
 * rest of its 128-byte block zeroed: our encodings inside iPadOS's job.
 */
static int patch_fs_code(uint8_t *usc, uint64_t size, const char *spec)
{
	static const uint16_t start[] = { 0x211c, 0x2800, 0x004d, 0x018a };
	uint16_t w[64] = { 0 };
	unsigned int n = 0;
	uint64_t o;

	while (*spec && n < 64) {
		w[n++] = (uint16_t)strtoul(spec, (char **)&spec, 16);
		spec += *spec == ',';
	}
	for (o = 0; o + 128 <= size; o += 2) {
		if (memcmp(usc + o, start, sizeof(start)))
			continue;
		memcpy(usc + o, w, 128);
		return n;
	}
	return 0;
}

/*
 * OWN=bg,eot,vs: replace the capture's device programs with our own
 * encodings, in place (RENDER.md "Own programs"). Code-heap offsets come
 * from the capture's record and PDS data, as the hardware finds them.
 */
static int own(const char *what)
{
	const char *list = getenv("OWN");
	size_t n = strlen(what);

	for (; list && *list; list += strcspn(list, ",") + !!list[strcspn(list, ",")])
		if (!strncmp(list, what, n) && (list[n] == ',' || !list[n] || list[n] == '='))
			return 1;
	return 0;
}

/* Both mappings (PDS and USC base) of code-heap offset @off */
static void code_write(uint32_t off, const void *p, uint32_t size)
{
	unsigned int i, k;

	for (i = 0; i < nregions; i++) {
		struct region *r = &regions[i];

		if (!r->code || off < r->gpu || off + size > r->gpu + r->size)
			continue;
		for (k = 0; k < 2; k++)
			memcpy(r->bo[k].map + off - r->gpu, p, size);
		return;
	}
	die("code offset outside the code heap");
}

static uint32_t code_read32(uint32_t off)
{
	unsigned int i;

	for (i = 0; i < nregions; i++)
		if (regions[i].code && off >= regions[i].gpu && off + 4 <= regions[i].gpu + regions[i].size)
			return *(uint32_t *)(regions[i].bo[0].map + off - regions[i].gpu);
	die("code offset outside the code heap");
	return 0;
}

struct usc {
	uint16_t w[160];
	unsigned int n;
};

static void emit(struct usc *c, const uint16_t *w, unsigned int n)
{
	memcpy(c->w + c->n, w, 2 * n);
	c->n += n;
}
#define EMIT(c, ...) do { const uint16_t w_[] = { __VA_ARGS__ }; emit(c, w_, sizeof(w_) / 2); } while (0)

/* A jump to the next 64-byte block, `c000` padding up to it */
static void jump_to_block(struct usc *c)
{
	unsigned int off = ((2 * c->n + 6 + 63) & ~63u) - 2 * c->n;

	EMIT(c, 0x0100, (off & 0xfefe) | 0x0100 | (off >> 8 & 1), 0x0000);
	while (c->n % 32)
		EMIT(c, 0xc000);
}

/*
 * Background (clear) shader: half h of the output = f16 of the f32 uniform
 * (common-store dword) u, for the 4 channels, then the colour output.
 * Conversion form as Apple's (`018a 01hh 0101 01a0 01uu 4140 0104 00b0`,
 * W1 low bits the half, W4 0x0101 | 4u the uniform dword).
 */
static void own_bg(void)
{
	uint32_t usc = code_read32((uint32_t)rec64(0x280));	/* PDS_BGRND0's kick data */
	struct usc c = { .n = 0 };
	unsigned int h;

	for (h = 0; h < 4; h++) {
		unsigned int u = own("bgswap") ? 3 - h : h;

		EMIT(&c, 0x018a, 0x0100 | h, 0x0101, 0x01a0, 0x0101 | 4 * u, 0x4140, 0x0104, 0x00b0);
	}
	EMIT(&c, 0x211c, 0x0800, 0x8000);
	code_write(usc, c.w, 2 * c.n);
	printf("own background shader at %#x%s\n", usc, own("bgswap") ? " (channels reversed)" : "");
}

/*
 * End-of-tile shader: r0 = 0 (Apple moves common-store dword 6 of the
 * image state, 0 in every capture), the PBE emit `051c 5100 0800`, end.
 */
static void own_eot(void)
{
	uint32_t data = (uint32_t)rec64(0x2b0);
	uint32_t usc = code_read32(data + 16);	/* DOUTU source q2 */
	struct usc c = { .n = 0 };

	if (own("eotu6"))
		EMIT(&c, 0x0188, 0x0100, 0x0181 | 4 * 6, 0x4100, 0x0128, 0x0039);
	else
		EMIT(&c, 0x0198, 0x0100, 0x0101, 0x0120, 0x0154, 0x0038);
	EMIT(&c, 0x051c, 0x5100, 0x0800);
	jump_to_block(&c);
	EMIT(&c, 0x8000);
	code_write(usc, c.w, 2 * c.n);
	printf("own end-of-tile shader at %#x\n", usc);
}

/*
 * Vertex shader: position (x, y) from the vertex buffer at index r0 (the
 * PDS writes the vertex index there), z 0, w 1; outputs `151e 01rr 00kk`,
 * the last one `155e c1rr 00kk` in place of the end word. The vertex
 * buffer's address goes into common-store dwords 0-1 (our DMA).
 */
static void own_vs(uint32_t vs_data, uint32_t vsu_data, uint64_t vsu_addr)
{
	uint32_t usc = code_read32(vs_data);
	uint32_t dma[4] = { (uint32_t)vsu_addr, (uint32_t)(vsu_addr >> 32), 0x90000002, 0 };
	struct usc c = { .n = 0 };

	EMIT(&c, 0x1189, 0x0304, 0x8000 | 0x0100 | 0x81, 0x4100, 0x01a1, 0x0600 | 3 << 13);
	EMIT(&c, 5 << 11 | 0x0310, (1 | 2 << 2) << 8 | 4 << 1, 0x8800);	/* r4, r5 = *(r2:r3) */
	EMIT(&c, 0x004d);
	EMIT(&c, 0x0198, 0x030c, 0x0101, 0x0120, 0x0154, 0x0038);	/* r6 = 0 */
	if (own("vsw2"))	/* w = 2: the triangle at half size, a check that ours runs */
		EMIT(&c, 0x0198, 0x030e, 0x0101, 0x0121, 0x4100, 0x0154, 0x0038);
	else	/* r7 = 1.0f */
		EMIT(&c, 0x0198, 0x030e, 0x0101, 0x8121, 0x3f80, 0x0154, 0x0038);
	EMIT(&c, 0x151e, 0x0108, 0x0000, 0x151e, 0x010a, 0x0001, 0x151e, 0x010c, 0x0002);
	jump_to_block(&c);
	EMIT(&c, 0x155e, 0xc10e, 0x0003);
	code_write(usc, c.w, 2 * c.n);
	code_write(vsu_data, dma, sizeof(dma));
	printf("own vertex shader at %#x, vertex buffer address via %#x\n", usc, vsu_data);
}

/* The draw's programs, from the VDM stream and its PPP state */
struct draw_programs {
	uint32_t vs_pds_code, vs_pds_data;	/* VDM_STATE: vertex kick */
	uint32_t dma_code, dma_data;		/* PDS_STATE: common-store DMA */
	uint32_t fs_pds;			/* PPP PDS shader base: data, code at +0x20 */
};

static const uint32_t *ios_words(uint64_t addr)
{
	unsigned int i;

	for (i = 0; i < nregions; i++)
		if (!regions[i].code && addr >= regions[i].gpu &&
		    addr < regions[i].gpu + regions[i].size)
			return (const uint32_t *)(regions[i].data + (addr - regions[i].gpu));
	return NULL;
}

/* The last of each block wins: the stream's blocks before them are skipped by links */
static void find_draw_programs(struct draw_programs *d)
{
	unsigned int i, j;

	memset(d, 0, sizeof(*d));
	for (i = 0; i < nregions; i++) {
		const uint32_t *w = (const uint32_t *)regions[i].data;

		if (regions[i].gpu != IOS_STREAM)
			continue;
		for (j = 0; j + 2 < regions[i].size / 4; j++) {
			if ((w[j] & 0xfc000000u) == 0x44000000u) {	/* VDM_STATE with code */
				d->vs_pds_code = w[j + 1] & ~0xfu;
			} else if ((w[j] & 0xf8000000u) == 0x48000000u) {	/* VDM_STATE, data */
				d->vs_pds_data = w[j + 1] & ~0xfu;
			} else if (w[j] >> 29 == 1) {	/* PDS_STATE */
				d->dma_data = w[j + 1] & ~0xfu;
				d->dma_code = w[j + 2] & ~0xfu;
			} else if (w[j] >> 29 == 0 && (w[j] >> 8 & 0xff) == 6) {
				/*
				 * PPP_STATE of 6 words: header 0xc0 = PDS state pointers 0
				 * and 1. The stream is relocated already (relocate()).
				 */
				const uint32_t *p = ios_words(((uint64_t)(w[j] & 0xff) << 32 | w[j + 1]) - RELOC);

				if (p && p[0] == 0xc0)
					d->fs_pds = p[1] & ~0xfu;
			}
		}
	}
}

/*
 * The PDS programs, from g9p-cdm.h's encoder: each is a DOUT or two and a
 * HALT (RENDER.md "Own programs" for the control words in their data).
 */
static void own_pds(const struct draw_programs *d)
{
	const uint32_t vs[3] = {
		g9p_pds_dout(G9P_DOUTW, 0, G9P_PDS_TEMPS, 2, 0),	/* vertex index -> r0 */
		g9p_pds_dout(G9P_DOUTU, 0, G9P_PDS_DATA, 0, G9P_PDS_END | G9P_PDS_CC),
		g9p_pds_halt(),
	};
	const uint32_t dma[2] = { g9p_pds_dout(G9P_DOUTD, 0, G9P_PDS_DATA, 2, G9P_PDS_END),
				  g9p_pds_halt() };
	const uint32_t kick[2] = { g9p_pds_dout(G9P_DOUTU, 0, G9P_PDS_DATA, 0, G9P_PDS_END),
				   g9p_pds_halt() };
	const uint32_t eot[3] = {
		g9p_pds_dout(G9P_DOUTD, 0, G9P_PDS_DATA, 2, 0),		/* image state */
		g9p_pds_dout(G9P_DOUTU, 2, G9P_PDS_DATA, 0, G9P_PDS_END),
		g9p_pds_halt(),
	};
	uint64_t bgnd0 = rec64(0x280);

	code_write(d->vs_pds_code, vs, sizeof(vs));
	code_write(d->dma_code, dma, sizeof(dma));
	code_write(d->fs_pds + 0x20, kick, sizeof(kick));
	code_write((uint32_t)bgnd0 + 0x20, kick, sizeof(kick));	/* PDS_BGRND0: kick */
	code_write((uint32_t)(bgnd0 >> 32), dma, sizeof(dma));	/* PDS_BGRND1: clear colour DMA */
	code_write((uint32_t)(rec64(0x2b0) >> 32), eot, sizeof(eot));
	printf("own PDS programs: vertex %#x, DMA %#x, fragment %#x, background %#x/%#x, "
	       "end of tile %#x\n", d->vs_pds_code, d->dma_code, d->fs_pds + 0x20,
	       (uint32_t)bgnd0 + 0x20, (uint32_t)(bgnd0 >> 32), (uint32_t)(rec64(0x2b0) >> 32));
}

int main(int argc, char **argv)
{
	struct drm_pvr_ioctl_create_vm_context_args vm_args = { 0 };
	struct drm_pvr_ioctl_create_free_list_args fl = { 0 };
	struct drm_pvr_ioctl_create_hwrt_dataset_args hwrt = { 0 };
	struct drm_pvr_ioctl_create_context_args ctx = { 0 };
	struct drm_pvr_ioctl_submit_jobs_args submit = { 0 };
	struct drm_pvr_job jobs[2];
	struct bo rgn, tpc, mlist, mtile, vheap, rtc, fl_bo;
	struct stream geom, frag;
	struct draw_programs draw;
	uint32_t *target = NULL;
	unsigned int i, k, clear = 0, other = 0;
	struct timespec t0, t1;
	double ms;
	FILE *out;

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
		printf("heaps: general %#llx, PDS %#llx, USC %#llx\n",
		       (unsigned long long)heaps[DRM_PVR_HEAP_GENERAL].base,
		       (unsigned long long)PDS_HEAP, (unsigned long long)USC_HEAP);
	}

	/* TRI_BLOB=PATH: another packed capture (tools/tri-blob.py), e.g. varyings */
	load_capture(getenv("TRI_BLOB") ? getenv("TRI_BLOB") : "/lib/firmware/apple/gpu-tri.bin");
	/* Code-heap regions hold PDS data with 64-bit pointers too */
	for (i = 0; i < nregions; i++)
		relocate(&regions[i]);
	for (i = 0; i < nregions; i++) {
		struct region *r = &regions[i];
		uint64_t size = (r->size + PAGE - 1) & ~(PAGE - 1);

		if (r->gpu == IOS_RECORD)
			continue;
		for (k = 0; k < (r->code ? 2 : 1); k++) {
			uint64_t addr = r->code ? (k ? USC_HEAP : PDS_HEAP) + r->gpu : r->gpu + RELOC;

			bo_create(&r->bo[k], addr, size, DRM_PVR_BO_ALLOW_CPU_USERSPACE_ACCESS |
							     DRM_PVR_BO_BYPASS_DEVICE_CACHE);
			memcpy(r->bo[k].map, r->data, r->size);
		}
		if (r->code && getenv("FS_COLOR") &&
		    patch_fs_color(r->bo[1].map, r->size, getenv("FS_COLOR")))
			printf("fragment colour: %s (our encoding)\n", getenv("FS_COLOR"));
		if (r->code && getenv("FS_CODE") &&
		    patch_fs_code(r->bo[1].map, r->size, getenv("FS_CODE")))
			printf("fragment shader: FS_CODE\n");
		if (r->gpu == IOS_TARGET)
			target = (uint32_t *)r->bo[0].map;
	}
	if (!target) {
		fprintf(stderr, "no render target region in the capture\n");
		return 1;
	}
	memset(target, 0x55, 64 * 64 * 4);

	if (own("bg"))
		own_bg();
	if (own("eot"))
		own_eot();
	find_draw_programs(&draw);
	if (own("pds"))
		own_pds(&draw);
	if (own("vs")) {
		static struct bo vsu;
		uint64_t vb;

		vb = code_read32(draw.dma_data) | (uint64_t)code_read32(draw.dma_data + 4) << 32;
		bo_create(&vsu, heaps[DRM_PVR_HEAP_GENERAL].base + 0x300000000ull, PAGE,
			  DRM_PVR_BO_ALLOW_CPU_USERSPACE_ACCESS | DRM_PVR_BO_BYPASS_DEVICE_CACHE);
		memcpy(vsu.map, &vb, 8);
		printf("vertex buffer %#llx\n", (unsigned long long)vb);
		own_vs(draw.vs_pds_data, draw.dma_data, vsu.addr);
	}

	/* Parameter-manager buffers and the free list (PM-only memory) */
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
	hwrt.width = 64;
	hwrt.height = 64;
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

	geom_stream(&geom);
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

	clock_gettime(CLOCK_MONOTONIC, &t0);
	if (ioctl(fd, DRM_IOCTL_PVR_SUBMIT_JOBS, &submit))
		die("SUBMIT_JOBS");
	do {
		clear = other = 0;
		for (i = 0; i < 64 * 64; i++) {
			if (target[i] == 0xff000000)
				clear++;
			else if (target[i] != 0x55555555)
				other++;
		}
		clock_gettime(CLOCK_MONOTONIC, &t1);
		ms = (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6;
	} while (clear + other < 64 * 64 && ms < 3000);

	for (i = 0; i < 64 * 64; i++)
		if (target[i] != 0xff000000 && target[i] != 0x55555555) {
			printf("triangle pixel: %#010x\n", target[i]);
			break;
		}
	printf("target: %u clear, %u triangle, %u untouched after %.1f ms: %s\n", clear, other,
	       64 * 64 - clear - other, ms,
	       clear == 3584 && other == 512 ? "PASS (matches iPadOS)" : "FAIL");
	if (argc > 1 && (out = fopen(argv[1], "wb"))) {
		fwrite(target, 4, 64 * 64, out);
		fclose(out);
	}
	return clear == 3584 && other == 512 ? 0 : 1;
}
