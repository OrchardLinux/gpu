// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * Userspace compute test for the Apple A10 powervr variant: experiment 68
 * (store 0x1357 from a native applegpu_g9p shader) through the powervr UAPI
 * only, the way Mesa would submit it. Buffers live in powervr's heaps, whose
 * bases come from DRM_PVR_DEV_QUERY_HEAP_INFO_GET:
 *
 *   PDS heap  +0x0       PDS programs and data, argument table
 *   USC heap  +0x0       USC code (store_marker at +0x40)
 *   general   +0x10000  CDM control stream
 *             +0x14000  CDM context-state buffer
 *             +0x18000  output, initialized to 0xabadbeef
 *
 * With USC.bin, the kernel's code comes from that file instead (e.g. from
 * tools/isa/g9p.py), and the test checks out[INDEX] == VALUE. Jobs are built
 * with tools/g9p-cdm.h, end with iPadOS's end-of-pass records and are waited
 * for on their fence (syncobj). Environment:
 *
 *   GRID=GROUPS,SIZE   GROUPS workgroups of SIZE threads (GROUPS_Y, GROUPS_Z
 *                      for 2D/3D); the PDS program writes the workgroup ID
 *                      into threadgroup word 0 (PDS_GID: its control word,
 *                      PDS_D5: a second one in data dword 5)
 *   SEQ=N              check out[k] == k for k < N instead
 *   USC_AT=OFFSET      kernel code at this offset of the USC page (0x40)
 *   DUMP=N, DUMP_STATE print out[0..N) / the CDM context-state buffer
 *   RESUBMIT           submit the job twice
 *   Raw overrides for decoding: KERNEL_K0, KERNEL_K1, CDM_K6, CDM_K7, BIND_K0,
 *   BIND_VAL, BIND_CTRL2, BIND_FILL, BIND_D16, PDS_CODE=w0,w1,...
 *   End-of-pass experiments: NO_TAIL, TAIL_APPLE_K1=MASK (records keeping
 *   their K1 flag, default 0xf), TAIL_APPLE_K1V=v0,v1,v2,v3, TAIL_FENCE_K0,
 *   SPIN_USC=FILE (fenced kernel code, e.g. driver shader 38),
 *   TAIL_APPLE_FLUSH=FILE (iPadOS's constants + flush record, FLUSH_ADDR)
 *   NO_FENCE_WAIT      poll out[INDEX] instead of waiting for the fence
 *
 * Build (static, arm64): see tools/build-pvr-compute-test.sh
 * Run: pvr-compute-test [/dev/dri/renderD128 [USC.bin INDEX VALUE]]
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

#define PAGE		0x4000u
#define PDS_HEAP	heaps[DRM_PVR_HEAP_PDS_CODE_DATA].base
#define USC_HEAP	heaps[DRM_PVR_HEAP_USC_CODE].base
#define GENERAL		heaps[DRM_PVR_HEAP_GENERAL].base

struct bo {
	uint32_t handle;
	uint8_t *map;
	uint64_t addr;
};

static int fd;
static uint32_t vm;
static struct drm_pvr_heap heaps[DRM_PVR_HEAP_COUNT];

static void die(const char *what)
{
	fprintf(stderr, "%s: %s\n", what, strerror(errno));
	exit(1);
}

static void bo_create(struct bo *bo, uint64_t addr)
{
	struct drm_pvr_ioctl_create_bo_args create = {
		.size = PAGE,
		.flags = DRM_PVR_BO_ALLOW_CPU_USERSPACE_ACCESS | DRM_PVR_BO_BYPASS_DEVICE_CACHE,
	};
	struct drm_pvr_ioctl_get_bo_mmap_offset_args off = { 0 };
	struct drm_pvr_ioctl_vm_map_args map = { 0 };

	if (ioctl(fd, DRM_IOCTL_PVR_CREATE_BO, &create))
		die("CREATE_BO");
	off.handle = create.handle;
	if (ioctl(fd, DRM_IOCTL_PVR_GET_BO_MMAP_OFFSET, &off))
		die("GET_BO_MMAP_OFFSET");
	bo->map = mmap(NULL, PAGE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, off.offset);
	if (bo->map == MAP_FAILED)
		die("mmap");
	memset(bo->map, 0, PAGE);
	map.vm_context_handle = vm;
	map.device_addr = addr;
	map.handle = create.handle;
	map.size = PAGE;
	if (ioctl(fd, DRM_IOCTL_PVR_VM_MAP, &map))
		die("VM_MAP");
	bo->handle = create.handle;
	bo->addr = addr;
}

static void w32(struct bo *bo, uint32_t off, uint32_t v)
{
	*(volatile uint32_t *)(bo->map + off) = v;
}

static void w64(struct bo *bo, uint32_t off, uint64_t v)
{
	w32(bo, off, (uint32_t)v);
	w32(bo, off + 4, (uint32_t)(v >> 32));
}

int main(int argc, char **argv)
{
	/* out[0] = 0x1357, tools/isa/g9p.py store_kernel(0x1357) (ISA.md encodings) */
	static const uint16_t usc_store_marker[] = {
		0x1181, 0x8189, 0x4100, 0xacb7,		/* entry, one buffer binding */
		0x01c8, 0x0302, 0x0101, 0x0120, 0x46d1,	/* execution-mask stack in r1 */
		0x2198, 0x0300, 0x012f, 0x212a,		/* r0 = 0x1357 */
		0x0154, 0x0038,
		0x0900, 0x010c, 0x0000,			/* no lane active: skip the store */
		0x2312, 0x0180, 0x8000,			/* buffer 0 [0] = r0 (u32) */
		0x21c8, 0x0302, 0x0184, 0x46d2,		/* pop the mask stack */
		0x0100, 0x010e, 0x0000,			/* jump to the end word */
		0xc000, 0xc000, 0xc000, 0xc000,		/* padding: end starts a 64-byte block */
		0x8000,					/* end */
	};
	/*
	 * PDS page layout: binding data 0x900 and code 0x3e00, kernel data
	 * 0x800 and code 0x3f00, argument table 0x1000; end-of-pass programs:
	 * kick data 0x2000 (fenced kernel's with SPIN_USC: 0x2010), fence code
	 * 0x2300, kick code 0x2400, constants record 0x2500/0x2580/0x2600, fence
	 * data 0x2700 (zero, as on iPadOS). USC page: kernel at usc_at, empty
	 * kernel 0x3000, SPIN_USC 0x3400, TAIL_APPLE_FLUSH 0x3800.
	 */
	const struct g9p_pass_end_programs pass_end = {
		.kick_code = 0x2400, .kick_data = 0x2000,
		.fence_code = 0x2300, .fence_data = 0x2700,
	};
	struct g9p_cdm_record rec[2];
	uint32_t groups[3] = { 1, 1, 1 }, kernel_k0, pds_kernel[8], n_pds;
	uint32_t tail[8 + 33], tail_words, w[4];
	uint16_t empty[33];
	int grid = !!getenv("GRID");
	struct drm_pvr_ioctl_create_vm_context_args vm_args = { 0 };
	struct drm_pvr_ioctl_create_context_args ctx = { 0 };
	struct drm_pvr_ioctl_submit_jobs_args submit = { 0 };
	struct drm_pvr_job job = { 0 };
	struct drm_syncobj_create syncobj = { 0 };
	struct drm_pvr_sync_op sync_op = { 0 };
	struct bo pds, usc, stream, state, out;
	uint8_t cmd[36] = { 0 };
	struct timespec t0, t1;
	uint32_t i, value, index = 0, expect = 0x1357, usc_at = 0x40, seq = 0, grid_size = 1;
	FILE *code = NULL;
	double ms;

	fd = open(argc > 1 ? argv[1] : "/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
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


	if (grid) {
		unsigned int size = 1;

		sscanf(getenv("GRID"), "%u,%u", &groups[0], &size);
		grid_size = size;
	}
	if (getenv("GROUPS_Y"))
		groups[1] = strtoul(getenv("GROUPS_Y"), NULL, 0);
	if (getenv("GROUPS_Z"))
		groups[2] = strtoul(getenv("GROUPS_Z"), NULL, 0);
	if (getenv("SEQ"))
		seq = strtoul(getenv("SEQ"), NULL, 0);
	if (getenv("USC_AT"))
		usc_at = strtoul(getenv("USC_AT"), NULL, 0) & (PAGE - 64);

	/*
	 * Record 0: the buffer binding, a DMA task (2 data blocks, all
	 * clusters). Record 1: the kernel. With GRID, its PDS program writes
	 * the workgroup ID into threadgroup word 0 (more data: 2 blocks) and
	 * word 6 allocates threadgroup memory; without, it is iPadOS's
	 * one-thread kernel task.
	 */
	kernel_k0 = G9P_CDM_KERNEL_SIZES | G9P_CDM_ANY_CLUSTER | G9P_CDM_FENCE |
		    G9P_CDM_DATA_BLOCKS(grid ? 2 : 1);
	if (getenv("KERNEL_K0"))
		kernel_k0 = strtoul(getenv("KERNEL_K0"), NULL, 0);
	rec[0] = g9p_cdm_dma_task(G9P_CDM_DATA_BLOCKS(2), 0x900, 0x3e00);
	if (getenv("BIND_K0"))
		rec[0].w[0] = strtoul(getenv("BIND_K0"), NULL, 0);
	if (grid)
		rec[1] = g9p_cdm_kernel(kernel_k0, 0x800, 0x3f00, groups[0], groups[1], groups[2],
					grid_size, 1);
	else
		rec[1] = g9p_cdm_task(kernel_k0, 0x800, 0, 0x3f00);
	if (getenv("KERNEL_K1"))
		rec[1].w[1] = strtoul(getenv("KERNEL_K1"), NULL, 0);
	/* raw kernel record words 6 and 7, for decoding them */
	if (getenv("CDM_K6"))
		rec[1].w[6] = strtoul(getenv("CDM_K6"), NULL, 0);
	if (getenv("CDM_K7"))
		rec[1].w[7] = strtoul(getenv("CDM_K7"), NULL, 0);

	bo_create(&pds, PDS_HEAP);
	bo_create(&usc, USC_HEAP);
	bo_create(&stream, GENERAL + 0x10000);
	bo_create(&state, GENERAL + 0x14000);
	bo_create(&out, GENERAL + 0x18000);

	/*
	 * Argument table entry {buffer, unused, thread count in both halves}.
	 * Binding task: DOUTD 2 dwords (buffer) to common-store dword 0, then
	 * DOUTD 1 dword (thread count) to dword 2, the last DMA (ctrl dwords
	 * 4 and 6: Rogue DOUTD control words).
	 */
	w64(&pds, 0x1000, out.addr);
	w32(&pds, 0x1010, getenv("BIND_VAL") ? strtoul(getenv("BIND_VAL"), NULL, 0) :
			  grid_size | grid_size << 16);
	w64(&pds, 0x900, pds.addr + 0x1000);
	w64(&pds, 0x908, pds.addr + 0x1010);
	w32(&pds, 0x910, 0x10000002);
	if (getenv("BIND_FILL"))		/* argument dwords 3..16 = their index */
		for (i = 3; i <= 16; i++)
			w32(&pds, 0x1010 + 4 * (i - 2), i);
	if (getenv("BIND_D16"))		/* argument dword 16, for wider binding loads */
		w32(&pds, 0x1010 + 4 * 14, strtoul(getenv("BIND_D16"), NULL, 0));
	w32(&pds, 0x918, getenv("BIND_CTRL2") ? strtoul(getenv("BIND_CTRL2"), NULL, 0) :
			 0x90004001);
	w32(&pds, 0x3e00, g9p_pds_dout(G9P_DOUTD, 0, G9P_PDS_DATA, 4, 0));
	w32(&pds, 0x3e04, g9p_pds_dout(G9P_DOUTD, 1, G9P_PDS_DATA, 6, G9P_PDS_END));
	w32(&pds, 0x3e08, g9p_pds_halt());

	/*
	 * Kernel task data: DOUTU source {USC offset, 0x10}, then the DOUTW
	 * control word writing the local ID (temps q0) to r0 (dword 2) and,
	 * with GRID, the one writing the workgroup ID to threadgroup word 0
	 * (dword 4, PDS_GID overrides; PDS_D5 a second one in dword 5).
	 */
	g9p_pds_kick_data(w, usc_at);
	w32(&pds, 0x800, w[0]);
	/* KICK_D1: the DOUTU's second data word (0x10 as on iPadOS) */
	w32(&pds, 0x804, getenv("KICK_D1") ? strtoul(getenv("KICK_D1"), NULL, 0) : w[1]);
	w32(&pds, 0x808, 0x80000000);
	n_pds = 0;
	pds_kernel[n_pds++] = g9p_pds_bra_not_if1(grid ? 4 : 2);
	if (grid) {
		/* IF1, once per workgroup: DOUTW temps q0 (workgroup ID), END */
		pds_kernel[n_pds++] = g9p_pds_dout(G9P_DOUTW, 0, G9P_PDS_TEMPS, 4, G9P_PDS_END);
		pds_kernel[n_pds++] = g9p_pds_halt();
		w32(&pds, 0x810, getenv("PDS_GID") ? strtoul(getenv("PDS_GID"), NULL, 0) :
				 0x90000000);
		if (getenv("PDS_D5"))
			w32(&pds, 0x814, strtoul(getenv("PDS_D5"), NULL, 0));
	}
	pds_kernel[n_pds++] = g9p_pds_halt();
	pds_kernel[n_pds++] = g9p_pds_dout(G9P_DOUTW, 0, G9P_PDS_TEMPS, 2, 0);
	pds_kernel[n_pds++] = g9p_pds_dout(G9P_DOUTU, 0, G9P_PDS_DATA, 0,
					   G9P_PDS_END | G9P_PDS_CC);
	pds_kernel[n_pds++] = g9p_pds_halt();
	for (i = 0; i < n_pds; i++)
		w32(&pds, 0x3f00 + 4 * i, pds_kernel[i]);
	if (getenv("PDS_CODE")) {
		/* PDS_CODE=w0,w1,...: the kernel task's code words */
		char *p = getenv("PDS_CODE");

		for (i = 0; *p && i < 16; i++) {
			w32(&pds, 0x3f00 + 4 * i, strtoul(p, &p, 0));
			if (*p == ',')
				p++;
		}
	}

	if (argc > 4) {
		size_t n;

		code = fopen(argv[2], "rb");
		if (!code)
			die(argv[2]);
		n = fread(usc.map + usc_at, 1, PAGE - usc_at, code);
		fclose(code);
		index = strtoul(argv[3], NULL, 0);
		expect = strtoul(argv[4], NULL, 0);
		printf("USC code: %zu bytes from %s at +%#x, expecting out[%u] = %#x\n", n, argv[2],
		       usc_at, index, expect);
	} else {
		for (i = 0; i < sizeof(usc_store_marker) / 2; i++)
			*(volatile uint16_t *)(usc.map + usc_at + 2 * i) = usc_store_marker[i];
	}

	/* End of pass: iPadOS's barrier (g9p_cdm_end_pass), NO_TAIL: none */
	g9p_usc_empty_kernel(empty);
	for (i = 0; i < 33; i++)
		*(volatile uint16_t *)(usc.map + 0x3000 + 2 * i) = empty[i];
	g9p_pds_kick_data(w, 0x3000);
	w32(&pds, pass_end.kick_data, w[0]);
	w32(&pds, pass_end.kick_data + 4, w[1]);
	g9p_pds_kick_program(w);
	for (i = 0; i < 4; i++)
		w32(&pds, pass_end.kick_code + 4 * i, w[i]);
	g9p_pds_fence_program(w);
	for (i = 0; i < 4; i++)
		w32(&pds, pass_end.fence_code + 4 * i, w[i]);
	g9p_cdm_end_pass(tail + 8, &pass_end);
	tail_words = 33;
	if (getenv("TAIL_APPLE_K1") || getenv("TAIL_APPLE_K1V")) {
		/*
		 * TAIL_APPLE_K1=MASK keeps the K1 flags only on the records in MASK
		 * (default 0xf: all), TAIL_APPLE_K1V=v0,v1,v2,v3 sets their values
		 */
		uint32_t mask = getenv("TAIL_APPLE_K1") ?
				strtoul(getenv("TAIL_APPLE_K1"), NULL, 0) : 0xf;
		int v[4] = { -1, -1, -1, -1 };
		uint32_t k;

		if (getenv("TAIL_APPLE_K1V"))
			sscanf(getenv("TAIL_APPLE_K1V"), "%i,%i,%i,%i", &v[0], &v[1], &v[2], &v[3]);
		for (k = 0; k < 4; k++) {
			uint32_t *k1 = &tail[8 + 8 * k + 1];

			if (v[k] >= 0)
				*k1 = (*k1 & ~0xfu) | v[k];
			if (!(mask >> k & 1))
				*k1 &= ~0xfu;
		}
	}
	if (getenv("TAIL_FENCE_K0"))	/* K0 of the fenced kernel record */
		tail[8 + 16] = strtoul(getenv("TAIL_FENCE_K0"), NULL, 0);
	if (getenv("SPIN_USC")) {
		/* SPIN_USC=FILE: the fenced kernel runs this code (+0x3400) */
		FILE *f = fopen(getenv("SPIN_USC"), "rb");

		if (!f)
			die(getenv("SPIN_USC"));
		if (!fread(usc.map + 0x3400, 1, 0x400, f))
			die("SPIN_USC read");
		fclose(f);
		g9p_pds_kick_data(w, 0x3400);
		w32(&pds, 0x2010, w[0]);
		w32(&pds, 0x2014, w[1]);
		tail[8 + 17] = (tail[8 + 17] & 0xfu) | 0x2010;
	}
	if (getenv("TAIL_APPLE_FLUSH")) {
		/*
		 * iPadOS's first end-of-pass record (EncodeShaderConstantsPDSProgram):
		 * DOUTD 4 constant dwords into the common store, then kick the flush
		 * kernel (FILE, captured from USC 0x14280) at +0x3800. Constants:
		 * zero as on iPadOS (FLUSH_ADDR overrides).
		 */
		FILE *f = fopen(getenv("TAIL_APPLE_FLUSH"), "rb");
		struct g9p_cdm_record r = g9p_cdm_dma_task(G9P_CDM_DATA_BLOCKS(2), 0x2500, 0x2580);

		if (!f || !fread(usc.map + 0x3800, 1, 0x80, f))
			die("TAIL_APPLE_FLUSH");
		fclose(f);
		r.w[1] |= 0xa;		/* iPadOS's flags on this record */
		w64(&pds, 0x2600, getenv("FLUSH_ADDR") ? strtoull(getenv("FLUSH_ADDR"), NULL, 0) : 0);
		w32(&pds, 0x2608, 0);
		w32(&pds, 0x260c, 0);
		w64(&pds, 0x2500, pds.addr + 0x2600);
		w32(&pds, 0x2508, 0x90000004);	/* last, 4 dwords to common-store dword 0 */
		g9p_pds_kick_data(w, 0x3800);
		w32(&pds, 0x2510, w[0]);
		w32(&pds, 0x2514, w[1]);
		w32(&pds, 0x2580, g9p_pds_dout(G9P_DOUTD, 0, G9P_PDS_DATA, 2, 0));
		w32(&pds, 0x2584, g9p_pds_dout(G9P_DOUTU, 2, G9P_PDS_DATA, 0, G9P_PDS_END));
		w32(&pds, 0x2588, g9p_pds_halt());
		for (i = 0; i < 8; i++)
			tail[i] = r.w[i];
	}
	if (getenv("NO_TAIL")) {
		tail[8] = G9P_CDM_TERMINATE;
		tail_words = 1;
	}
	for (i = 0; i < 8; i++) {
		w32(&stream, 4 * i, rec[0].w[i]);
		w32(&stream, 4 * (8 + i), rec[1].w[i]);
	}
	for (i = 0; i < tail_words; i++)
		w32(&stream, 4 * (16 + i), tail[8 + i]);
	if (getenv("TAIL_APPLE_FLUSH")) {
		for (i = 0; i < 8; i++)
			w32(&stream, 4 * (16 + i), tail[i]);
		for (i = 0; i < tail_words; i++)
			w32(&stream, 4 * (24 + i), tail[8 + i]);
	}
	for (i = 0; i < PAGE / 4; i++)
		w32(&out, 4 * i, 0xabadbeef);

	ctx.type = DRM_PVR_CTX_TYPE_COMPUTE;
	ctx.priority = DRM_PVR_CTX_PRIORITY_NORMAL;
	ctx.vm_context_handle = vm;
	if (ioctl(fd, DRM_IOCTL_PVR_CREATE_CONTEXT, &ctx))
		die("CREATE_CONTEXT");

	/*
	 * Compute command stream for this device's features: {u32 main length,
	 * u32 0}, tpu_border_colour_table, cdm_ctrl_stream_base,
	 * cdm_context_state_base_addr (u64 each), cdm_resume_pds1 (u32).
	 */
	*(uint32_t *)(cmd + 0) = sizeof(cmd);
	*(uint64_t *)(cmd + 16) = stream.addr;
	*(uint64_t *)(cmd + 24) = state.addr;
	job.type = DRM_PVR_JOB_TYPE_COMPUTE;
	job.context_handle = ctx.handle;
	job.cmd_stream = (uintptr_t)cmd;
	job.cmd_stream_len = sizeof(cmd);
	/* powervr validates the stride even for an empty sync-op array */
	job.sync_ops.stride = sizeof(struct drm_pvr_sync_op);
	if (!getenv("NO_FENCE_WAIT")) {
		/* signal a syncobj when the job completes and wait on it */
		if (ioctl(fd, DRM_IOCTL_SYNCOBJ_CREATE, &syncobj))
			die("SYNCOBJ_CREATE");
		sync_op.handle = syncobj.handle;
		sync_op.flags = DRM_PVR_SYNC_OP_FLAG_HANDLE_TYPE_SYNCOBJ |
				DRM_PVR_SYNC_OP_FLAG_SIGNAL;
		job.sync_ops.count = 1;
		job.sync_ops.array = (uintptr_t)&sync_op;
	}
	submit.jobs.stride = sizeof(job);
	submit.jobs.count = 1;
	submit.jobs.array = (uintptr_t)&job;

	clock_gettime(CLOCK_MONOTONIC, &t0);
	if (ioctl(fd, DRM_IOCTL_PVR_SUBMIT_JOBS, &submit))
		die("SUBMIT_JOBS");
	if (!getenv("NO_FENCE_WAIT")) {
		struct drm_syncobj_wait wait = {
			.handles = (uintptr_t)&syncobj.handle,
			.count_handles = 1,
			.timeout_nsec = t0.tv_sec * 1000000000ll + t0.tv_nsec + 10000000000ll,
		};

		if (ioctl(fd, DRM_IOCTL_SYNCOBJ_WAIT, &wait))
			printf("fence: not signalled (%s)\n", strerror(errno));
		clock_gettime(CLOCK_MONOTONIC, &t1);
		printf("fence: %.1f ms\n", (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6);
	}
	do {
		value = *(volatile uint32_t *)(out.map + 4 * index);
		clock_gettime(CLOCK_MONOTONIC, &t1);
		ms = (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6;
	} while (value == 0xabadbeef && ms < 3000);
	if (getenv("RESUBMIT")) {
		/* a second identical job: does it bring out the first one's writes? */
		if (ioctl(fd, DRM_IOCTL_PVR_SUBMIT_JOBS, &submit))
			die("SUBMIT_JOBS");
		usleep(100000);
	}

	if (getenv("DUMP_STATE")) {
		/* the CDM context-state buffer: non-zero after a context store */
		usleep(10000);
		printf("state:");
		for (i = 0; i < 16; i++)
			printf(" %x", *(volatile uint32_t *)(state.map + 4 * i));
		printf("\n");
	}
	if (getenv("DUMP")) {
		uint32_t n = strtoul(getenv("DUMP"), NULL, 0);

		usleep(10000);
		for (i = 0; i < n; i++)
			printf("%s%x", i % 16 ? " " : i ? "\n" : "",
			       *(volatile uint32_t *)(out.map + 4 * i));
		printf("\n");
	}
	if (seq) {
		uint32_t bad = 0, first = 0;

		/* the last element is written last only by chance; wait a bit */
		usleep(10000);
		for (i = 0; i < seq; i++)
			if (*(volatile uint32_t *)(out.map + 4 * i) != i && !bad++)
				first = i;
		printf("seq %u: %u wrong (first out[%u] = %#x), out[%u] = %#x: %s\n", seq, bad,
		       first, *(volatile uint32_t *)(out.map + 4 * first), seq,
		       *(volatile uint32_t *)(out.map + 4 * seq), bad ? "FAIL" : "PASS");
		return bad ? 1 : 0;
	}
	printf("out[%u] = %#x, out[0] = %#x, out[1] = %#x after %.1f ms: %s\n", index, value,
	       *(volatile uint32_t *)out.map, *(volatile uint32_t *)(out.map + 4), ms,
	       value == expect ? "PASS" : "FAIL");
	return value == expect ? 0 : 1;
}
