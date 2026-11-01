/* Host check: pvr_apple_layout_build() at the golden addresses vs the replayed
 * baseline-46 images. Firmware image and RTKit areas of the window are ignored. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "pvr_apple_layout.h"
static u8 *load(const char *path, size_t size) {
	u8 *b = calloc(1, size); FILE *f = fopen(path, "rb");
	if (!f || fread(b, 1, size, f) != size) { perror(path); exit(2); }
	fclose(f); return b;
}
static int cmp(const char *name, const u8 *a, const u8 *b, size_t lo, size_t hi) {
	int bad = 0;
	for (size_t o = lo; o < hi; o += 4) {
		unsigned x, y; memcpy(&x, a + o, 4); memcpy(&y, b + o, 4);
		if (x != y && bad++ < 40) printf("%s+%#07zx: built %#010x golden %#010x\n", name, o, x, y);
	}
	return bad;
}
int main(int argc, char **argv) {
	if (argc < 2) { fprintf(stderr, "usage: %s GOLDEN_DIR\n", argv[0]); return 2; }
	char p[512];
	u8 *win = calloc(1, PVR_APPLE_WINDOW_SIZE), *heap = calloc(1, PVR_APPLE_HEAP_SIZE);
	pvr_apple_layout_build(win, 0x802100000ull, heap, 0x802400000ull, 0, 0x300000000ull, 0x300000000ull);
	/* The run itself sets the compute producer index before the doorbell. */
	heap[pvr_apple_layout_compute_producer()] = 1;
	snprintf(p, sizeof(p), "%s/window.bin", argv[1]); u8 *gw = load(p, PVR_APPLE_WINDOW_SIZE);
	snprintf(p, sizeof(p), "%s/scratch.bin", argv[1]); u8 *gs = load(p, PVR_APPLE_HEAP_SIZE);
	/*
	 * Intended deviations from baseline 46, each with its reason: the
	 * golden stays the replay of what the device ran.
	 */
	static const struct { size_t off; unsigned val; } dev[] = {
		/* X+0x301: power-state struct moved off the geometry queue (fw 0x159000) */
		{ 0x300, 0x15900000 },
	};
	for (size_t i = 0; i < sizeof(dev) / sizeof(dev[0]); i++)
		memcpy(gs + dev[i].off, &dev[i].val, 4);
	int bad = cmp("win", win, gw, 0x98000, 0x9d000) + cmp("heap", heap, gs, 0, PVR_APPLE_HEAP_SIZE);
	printf(bad ? "%d mismatching words\n" : "layout matches golden\n", bad);
	return !!bad;
}
