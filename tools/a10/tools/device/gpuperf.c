// gpuperf [STATE]: GPU performance state at Fender + 0x1000 (0x201d01000),
// as the GFX firmware sets it (fw 0x16d40: write STATE | 0x10, wait until the
// low 5 bits read back STATE). Prints it, or sets STATE and waits (bounded).
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static double now(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec * 1e-9;
}

int main(int argc, char **argv)
{
	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	volatile uint32_t *f = mmap(0, 0x4000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0x201d00000ULL);

	if (fd < 0 || f == MAP_FAILED) { perror("mmap"); return 1; }
	volatile uint32_t *r = f + 0x1000 / 4;
	printf("before %08x\n", *r);
	if (argc > 1) {
		uint32_t s = strtoul(argv[1], 0, 0) & 0xf;
		double t0 = now();
		*r = s | 0x10;
		while ((*r & 0x1f) != s && now() - t0 < 0.1)
			;
		printf("after  %08x  %.1f us\n", *r, (now() - t0) * 1e6);
	}
	return 0;
}
