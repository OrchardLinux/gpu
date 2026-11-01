// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * Show the self-test's rendered target on the framebuffer.
 *
 * The GPU renders into a square, twiddled (Morton order, y bit first) RGBA8
 * target; the fragment self-test leaves a copy at <debugfs>/apple_target.
 * This untwiddles it and draws it scaled up in the middle of the screen
 * (XRGB8888) on black. The CPU only copies the GPU's pixels; pixels the GPU
 * did not touch (tiles without geometry keep the 0x55 fill) are drawn black,
 * the clear colour.
 *
 * It draws through KMS (a dumb buffer on the first connected connector), so it
 * also works after the console blanked the display.
 *
 *   show-target /sys/kernel/debug/apple_target [/dev/dri/card0]
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <drm/drm.h>
#include <drm/drm_mode.h>

static unsigned int morton(unsigned int x, unsigned int y, unsigned int bits)
{
	unsigned int r = 0, b;

	for (b = 0; b < bits; b++)
		r |= ((y >> b) & 1) << (2 * b) | ((x >> b) & 1) << (2 * b + 1);
	return r;
}

static int fd;

static void xioctl(unsigned long req, void *arg, const char *what)
{
	if (ioctl(fd, req, arg)) {
		perror(what);
		exit(1);
	}
}

int main(int argc, char **argv)
{
	static uint32_t target[512 * 512];
	uint32_t conn_ids[8], crtc_ids[8], enc_ids[8];
	struct drm_mode_modeinfo modes[32];
	struct drm_mode_card_res res = { 0 };
	struct drm_mode_get_connector conn = { 0 };
	struct drm_mode_get_encoder enc = { 0 };
	struct drm_mode_create_dumb dumb = { 0 };
	struct drm_mode_map_dumb map = { 0 };
	struct drm_mode_fb_cmd fbcmd = { 0 };
	struct drm_mode_crtc crtc = { 0 };
	unsigned int size, bits = 0, scale, x0, y0, x, y, w, h, i;
	uint8_t *fb;
	size_t n;
	FILE *in;

	if (argc < 2 || !(in = fopen(argv[1], "rb"))) {
		fprintf(stderr, "usage: show-target TARGET [/dev/dri/card0]\n");
		return 1;
	}
	n = fread(target, 4, sizeof(target) / 4, in);
	for (size = 1; size * size < n; size *= 2)
		bits++;
	if (size * size != n) {
		fprintf(stderr, "%zu pixels is not a square power-of-two target\n", n);
		return 1;
	}

	fd = open(argc > 2 ? argv[2] : "/dev/dri/card0", O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		perror("open");
		return 1;
	}
	ioctl(fd, DRM_IOCTL_SET_MASTER, 0);
	res.connector_id_ptr = (uintptr_t)conn_ids;
	res.count_connectors = 8;
	res.crtc_id_ptr = (uintptr_t)crtc_ids;
	res.count_crtcs = 8;
	res.encoder_id_ptr = (uintptr_t)enc_ids;
	res.count_encoders = 8;
	xioctl(DRM_IOCTL_MODE_GETRESOURCES, &res, "GETRESOURCES");
	for (i = 0; i < res.count_connectors && i < 8; i++) {
		memset(&conn, 0, sizeof(conn));
		conn.connector_id = conn_ids[i];
		conn.modes_ptr = (uintptr_t)modes;
		conn.count_modes = 32;
		xioctl(DRM_IOCTL_MODE_GETCONNECTOR, &conn, "GETCONNECTOR");
		if (conn.connection == 1 && conn.count_modes)
			break;
	}
	if (i == res.count_connectors) {
		fprintf(stderr, "no connected connector\n");
		return 1;
	}
	enc.encoder_id = conn.encoder_id ? conn.encoder_id : enc_ids[0];
	xioctl(DRM_IOCTL_MODE_GETENCODER, &enc, "GETENCODER");
	w = modes[0].hdisplay;
	h = modes[0].vdisplay;

	dumb.width = w;
	dumb.height = h;
	dumb.bpp = 32;
	xioctl(DRM_IOCTL_MODE_CREATE_DUMB, &dumb, "CREATE_DUMB");
	map.handle = dumb.handle;
	xioctl(DRM_IOCTL_MODE_MAP_DUMB, &map, "MAP_DUMB");
	fb = mmap(NULL, dumb.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, map.offset);
	if (fb == MAP_FAILED) {
		perror("mmap");
		return 1;
	}
	fbcmd.width = w;
	fbcmd.height = h;
	fbcmd.bpp = 32;
	fbcmd.depth = 24;
	fbcmd.pitch = dumb.pitch;
	fbcmd.handle = dumb.handle;
	xioctl(DRM_IOCTL_MODE_ADDFB, &fbcmd, "ADDFB");

	scale = w / size < h / size ? w / size : h / size;
	x0 = (w - size * scale) / 2;
	y0 = (h - size * scale) / 2;
	memset(fb, 0, dumb.size);
	for (y = 0; y < size * scale; y++) {
		uint32_t *row = (uint32_t *)(fb + (y0 + y) * dumb.pitch) + x0;

		for (x = 0; x < size * scale; x++) {
			uint32_t abgr = target[morton(x / scale, y / scale, bits)];

			if (abgr == 0x55555555)
				abgr = 0;
			/* RGBA8 (R in the low byte) to XRGB8888 */
			row[x] = (abgr & 0xff) << 16 | (abgr & 0xff00) | (abgr >> 16 & 0xff);
		}
	}

	crtc.crtc_id = enc.crtc_id ? enc.crtc_id : crtc_ids[0];
	crtc.fb_id = fbcmd.fb_id;
	crtc.set_connectors_ptr = (uintptr_t)&conn.connector_id;
	crtc.count_connectors = 1;
	crtc.mode = modes[0];
	crtc.mode_valid = 1;
	xioctl(DRM_IOCTL_MODE_SETCRTC, &crtc, "SETCRTC");
	printf("drew the %ux%u target at %ux scale on %ux%u; holding the display\n", size, size,
	       scale, w, h);
	pause();
	return 0;
}
