// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * Screenshot of what the display scans out: the framebuffer on the first
 * active CRTC of the first KMS card (simpledrm or ADBE on the iPad),
 * whoever set it (a compositor), mapped as a dumb buffer and written as a
 * binary PPM. Root
 * only (the framebuffer's handle needs CAP_SYS_ADMIN). Run in the device
 * chroot while the compositor runs:
 *
 *   kms-grab OUT.ppm [SCALE]    # SCALE: keep every SCALE-th pixel (default 2)
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#include <drm_fourcc.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

static void die(const char *what)
{
	fprintf(stderr, "%s failed (%s)\n", what, strerror(errno));
	exit(1);
}

int main(int argc, char **argv)
{
	const unsigned scale = argc > 2 ? atoi(argv[2]) : 2;
	int fd = -1;
	drmModeRes *res = NULL;
	drmModeFB2 *fb = NULL;
	struct drm_mode_map_dumb map = { 0 };
	const uint8_t *px;
	size_t size;
	FILE *out;

	if (argc < 2 || !scale) {
		fprintf(stderr, "usage: kms-grab OUT.ppm [SCALE]\n");
		return 1;
	}
	/* the first card with KMS: simpledrm's or the ADBE driver's, not the GPU's */
	for (int n = 0; n < 4 && !res; n++) {
		char path[32];

		snprintf(path, sizeof(path), "/dev/dri/card%d", n);
		fd = open(path, O_RDWR | O_CLOEXEC);
		if (fd < 0)
			continue;
		res = drmModeGetResources(fd);
		if (!res)
			close(fd);
	}
	if (!res)
		die("drmModeGetResources on /dev/dri/card0-3");
	for (int i = 0; i < res->count_crtcs && !fb; i++) {
		drmModeCrtc *crtc = drmModeGetCrtc(fd, res->crtcs[i]);

		if (crtc && crtc->buffer_id)
			fb = drmModeGetFB2(fd, crtc->buffer_id);
		drmModeFreeCrtc(crtc);
	}
	if (!fb || !fb->handles[0])
		die("no scanned-out framebuffer with a handle (root?)");
	if (fb->pixel_format != DRM_FORMAT_XRGB8888 && fb->pixel_format != DRM_FORMAT_ARGB8888) {
		fprintf(stderr, "format %.4s not handled\n", (const char *)&fb->pixel_format);
		return 1;
	}
	map.handle = fb->handles[0];
	if (drmIoctl(fd, DRM_IOCTL_MODE_MAP_DUMB, &map))
		die("DRM_IOCTL_MODE_MAP_DUMB");
	size = (size_t)fb->pitches[0] * fb->height;
	px = mmap(NULL, size, PROT_READ, MAP_SHARED, fd, map.offset);
	if (px == MAP_FAILED)
		die("mmap");

	out = fopen(argv[1], "wb");
	if (!out)
		die(argv[1]);
	fprintf(out, "P6 %u %u 255\n", fb->width / scale, fb->height / scale);
	for (unsigned y = 0; y < fb->height / scale; y++) {
		const uint8_t *row = px + (size_t)y * scale * fb->pitches[0];

		for (unsigned x = 0; x < fb->width / scale; x++) {
			const uint8_t *p = row + 4 * x * scale;	/* B G R X */
			const uint8_t rgb[3] = { p[2], p[1], p[0] };

			fwrite(rgb, 1, 3, out);
		}
	}
	fclose(out);
	printf("%ux%u framebuffer %u, written at 1/%u\n", fb->width, fb->height, fb->fb_id, scale);
	return 0;
}
