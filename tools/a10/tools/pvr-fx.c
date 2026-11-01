// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * GPU effect demo for the Apple A10 powervr variant: a compute kernel
 * renders an animated Julia set into a 768x1024 buffer every frame, through
 * the powervr UAPI with jobs built by g9p-cdm.h, and the CPU scales it 2x
 * onto the framebuffer (/dev/fb0, 1536x2048 XRGB8888).
 *
 * The kernel is USC code for applegpu_g9p, e.g. the offline-compiled
 * tools/fx.metal (see tools/isa/explore.py). Buffer layout it expects:
 * dwords 1-4 = {c.x, c.y, zoom, palette shift} as floats, pixels from dword
 * 16, one 32-bit pixel per thread, workgroups of 64 threads, 12 x 1024 of
 * them.
 *
 *   pvr-fx FX.bin [SECONDS]      (stops early when /run/fx.stop exists)
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/kd.h>
#include <math.h>
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
#define W		768u
#define H		1024u
#define FB_W		1536u
#define FB_H		2048u
#define FB_STRIDE	6144u
#define OUT_SIZE	((64 + 4 * W * H + PAGE - 1) & ~(PAGE - 1))

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

static void bo_create(struct bo *bo, uint64_t addr, uint32_t size)
{
	struct drm_pvr_ioctl_create_bo_args create = {
		.size = size,
		.flags = DRM_PVR_BO_ALLOW_CPU_USERSPACE_ACCESS | DRM_PVR_BO_BYPASS_DEVICE_CACHE,
	};
	struct drm_pvr_ioctl_get_bo_mmap_offset_args off = { 0 };
	struct drm_pvr_ioctl_vm_map_args map = { 0 };

	if (ioctl(fd, DRM_IOCTL_PVR_CREATE_BO, &create))
		die("CREATE_BO");
	off.handle = create.handle;
	if (ioctl(fd, DRM_IOCTL_PVR_GET_BO_MMAP_OFFSET, &off))
		die("GET_BO_MMAP_OFFSET");
	bo->map = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, off.offset);
	if (bo->map == MAP_FAILED)
		die("mmap");
	memset(bo->map, 0, size);
	map.vm_context_handle = vm;
	map.device_addr = addr;
	map.handle = create.handle;
	map.size = size;
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

static void wf(struct bo *bo, uint32_t off, float v)
{
	uint32_t u;

	memcpy(&u, &v, 4);
	w32(bo, off, u);
}

static double now(void)
{
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec / 1e9;
}

/* The job: binding (buffer, 64 threads), the kernel, the end of the pass. */
static void build_job(struct bo *pds, struct bo *usc, struct bo *stream, struct bo *out,
		      const char *code_path)
{
	const struct g9p_pass_end_programs pass_end = {
		.kick_code = 0x2400, .kick_data = 0x2000,
		.fence_code = 0x2300, .fence_data = 0x2700,
	};
	struct g9p_cdm_record rec[2];
	uint32_t w[4], tail[33], i;
	uint16_t empty[33];
	FILE *f = fopen(code_path, "rb");

	if (!f)
		die(code_path);
	if (!fread(usc->map + 0x40, 1, 0x2000, f))
		die("kernel code");
	fclose(f);

	rec[0] = g9p_cdm_dma_task(G9P_CDM_DATA_BLOCKS(2), 0x900, 0x3e00);
	rec[1] = g9p_cdm_kernel(G9P_CDM_KERNEL_SIZES | G9P_CDM_ANY_CLUSTER | G9P_CDM_FENCE |
				G9P_CDM_DATA_BLOCKS(2), 0x800, 0x3f00, W / 64, H, 1, 64, 1);

	/* Binding: buffer address to common-store dwords 0-1, thread count to 2 */
	w64(pds, 0x1000, out->addr);
	w32(pds, 0x1010, 64 | 64 << 16);
	w64(pds, 0x900, pds->addr + 0x1000);
	w64(pds, 0x908, pds->addr + 0x1010);
	w32(pds, 0x910, 0x10000002);
	w32(pds, 0x918, 0x90004001);
	w32(pds, 0x3e00, g9p_pds_dout(G9P_DOUTD, 0, G9P_PDS_DATA, 4, 0));
	w32(pds, 0x3e04, g9p_pds_dout(G9P_DOUTD, 1, G9P_PDS_DATA, 6, G9P_PDS_END));
	w32(pds, 0x3e08, g9p_pds_halt());

	/* Kernel task: workgroup ID x, y (64 bits) to threadgroup words 0-1 */
	g9p_pds_kick_data(w, 0x40);
	w32(pds, 0x800, w[0]);
	w32(pds, 0x804, w[1]);
	w32(pds, 0x808, 0x80000000);
	w32(pds, 0x810, 0x90000002);
	w32(pds, 0x3f00, g9p_pds_bra_not_if1(4));
	w32(pds, 0x3f04, g9p_pds_dout(G9P_DOUTW, 0, G9P_PDS_TEMPS, 4, G9P_PDS_END));
	w32(pds, 0x3f08, g9p_pds_halt());
	w32(pds, 0x3f0c, g9p_pds_halt());
	w32(pds, 0x3f10, g9p_pds_dout(G9P_DOUTW, 0, G9P_PDS_TEMPS, 2, 0));
	w32(pds, 0x3f14, g9p_pds_dout(G9P_DOUTU, 0, G9P_PDS_DATA, 0, G9P_PDS_END | G9P_PDS_CC));
	w32(pds, 0x3f18, g9p_pds_halt());

	/* End of the pass */
	g9p_usc_empty_kernel(empty);
	for (i = 0; i < 33; i++)
		*(volatile uint16_t *)(usc->map + 0x3000 + 2 * i) = empty[i];
	g9p_pds_kick_data(w, 0x3000);
	w32(pds, pass_end.kick_data, w[0]);
	w32(pds, pass_end.kick_data + 4, w[1]);
	g9p_pds_kick_program(w);
	for (i = 0; i < 4; i++)
		w32(pds, pass_end.kick_code + 4 * i, w[i]);
	g9p_pds_fence_program(w);
	for (i = 0; i < 4; i++)
		w32(pds, pass_end.fence_code + 4 * i, w[i]);
	g9p_cdm_end_pass(tail, &pass_end);

	for (i = 0; i < 8; i++) {
		w32(stream, 4 * i, rec[0].w[i]);
		w32(stream, 4 * (8 + i), rec[1].w[i]);
	}
	for (i = 0; i < 33; i++)
		w32(stream, 4 * (16 + i), tail[i]);
}

/* 2x nearest-neighbour scale of the 768x1024 image onto the framebuffer */
static void present(const uint32_t *src, uint8_t *fb)
{
	static uint32_t row[W];
	uint32_t x, y;

	for (y = 0; y < H; y++) {
		uint32_t *d0 = (uint32_t *)(fb + (2 * y) * FB_STRIDE);
		uint32_t *d1 = (uint32_t *)(fb + (2 * y + 1) * FB_STRIDE);

		memcpy(row, src + y * W, sizeof(row));
		for (x = 0; x < W; x++)
			d0[2 * x] = d0[2 * x + 1] = row[x];
		memcpy(d1, d0, 4 * FB_W);
	}
}

int main(int argc, char **argv)
{
	struct drm_pvr_ioctl_create_vm_context_args vm_args = { 0 };
	struct drm_pvr_ioctl_create_context_args ctx = { 0 };
	struct drm_pvr_ioctl_submit_jobs_args submit = { 0 };
	struct drm_pvr_job job = { 0 };
	struct drm_syncobj_create syncobj = { 0 };
	struct drm_pvr_sync_op sync_op = { 0 };
	struct bo pds, usc, stream, state, out;
	uint8_t cmd[36] = { 0 };
	double seconds = argc > 2 ? atof(argv[2]) : 30, t0, t, gpu = 0, cpu = 0;
	unsigned int frames = 0;
	uint8_t *fb;
	int fbfd, tty;

	if (argc < 2) {
		fprintf(stderr, "usage: pvr-fx FX.bin [SECONDS]\n");
		return 1;
	}
	fd = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
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
	bo_create(&pds, heaps[DRM_PVR_HEAP_PDS_CODE_DATA].base, PAGE);
	bo_create(&usc, heaps[DRM_PVR_HEAP_USC_CODE].base, PAGE);
	bo_create(&stream, heaps[DRM_PVR_HEAP_GENERAL].base + 0x10000, PAGE);
	bo_create(&state, heaps[DRM_PVR_HEAP_GENERAL].base + 0x14000, PAGE);
	bo_create(&out, heaps[DRM_PVR_HEAP_GENERAL].base + 0x100000, OUT_SIZE);
	build_job(&pds, &usc, &stream, &out, argv[1]);

	/* Keep the text console off the framebuffer while the demo runs */
	tty = open("/dev/tty0", O_RDWR);
	if (tty >= 0)
		ioctl(tty, KDSETMODE, KD_GRAPHICS);
	fbfd = open("/dev/fb0", O_RDWR);
	if (fbfd < 0)
		die("/dev/fb0");
	fb = mmap(NULL, FB_STRIDE * FB_H, PROT_READ | PROT_WRITE, MAP_SHARED, fbfd, 0);
	if (fb == MAP_FAILED)
		die("mmap /dev/fb0");

	ctx.type = DRM_PVR_CTX_TYPE_COMPUTE;
	ctx.priority = DRM_PVR_CTX_PRIORITY_NORMAL;
	ctx.vm_context_handle = vm;
	if (ioctl(fd, DRM_IOCTL_PVR_CREATE_CONTEXT, &ctx))
		die("CREATE_CONTEXT");
	if (ioctl(fd, DRM_IOCTL_SYNCOBJ_CREATE, &syncobj))
		die("SYNCOBJ_CREATE");
	/* The compute command: main length, then the stream and context-state bases */
	*(uint32_t *)(cmd + 0) = sizeof(cmd);
	*(uint64_t *)(cmd + 16) = stream.addr;
	*(uint64_t *)(cmd + 24) = state.addr;
	job.type = DRM_PVR_JOB_TYPE_COMPUTE;
	job.context_handle = ctx.handle;
	job.cmd_stream = (uintptr_t)cmd;
	job.cmd_stream_len = sizeof(cmd);
	sync_op.handle = syncobj.handle;
	sync_op.flags = DRM_PVR_SYNC_OP_FLAG_HANDLE_TYPE_SYNCOBJ | DRM_PVR_SYNC_OP_FLAG_SIGNAL;
	job.sync_ops.stride = sizeof(sync_op);
	job.sync_ops.count = 1;
	job.sync_ops.array = (uintptr_t)&sync_op;
	submit.jobs.stride = sizeof(job);
	submit.jobs.count = 1;
	submit.jobs.array = (uintptr_t)&job;

	t0 = now();
	while ((t = now() - t0) < seconds && access("/run/fx.stop", F_OK)) {
		struct drm_syncobj_array reset = {
			.handles = (uintptr_t)&syncobj.handle, .count_handles = 1,
		};
		struct drm_syncobj_wait wait = {
			.handles = (uintptr_t)&syncobj.handle, .count_handles = 1,
			.timeout_nsec = (int64_t)((now() + 5) * 1e9),	/* absolute */
		};
		double a = 0.35 * t, t1;

		/* Julia constant on a circle, a slow zoom pulse, a drifting palette */
		wf(&out, 4, 0.7885f * cosf(a));
		wf(&out, 8, 0.7885f * sinf(a));
		wf(&out, 12, (3.2f / H) * (0.8f + 0.2f * cosf(0.5f * t)));
		wf(&out, 16, 0.05f * t);
		if (ioctl(fd, DRM_IOCTL_SYNCOBJ_RESET, &reset))
			die("SYNCOBJ_RESET");
		t1 = now();
		if (ioctl(fd, DRM_IOCTL_PVR_SUBMIT_JOBS, &submit))
			die("SUBMIT_JOBS");
		if (ioctl(fd, DRM_IOCTL_SYNCOBJ_WAIT, &wait))
			die("SYNCOBJ_WAIT");
		gpu += now() - t1;
		t1 = now();
		present((const uint32_t *)(out.map + 64), fb);
		cpu += now() - t1;
		frames++;
	}
	if (tty >= 0)
		ioctl(tty, KDSETMODE, KD_TEXT);
	printf("%u frames in %.1f s: %.1f fps (GPU %.1f ms, copy %.1f ms per frame)\n", frames,
	       now() - t0, frames / (now() - t0), 1e3 * gpu / frames, 1e3 * cpu / frames);
	return 0;
}
