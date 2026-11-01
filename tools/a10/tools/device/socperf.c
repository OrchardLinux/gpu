// socperf [STATE]: PMGR SoC/MEM performance state (PMGR + 0x68000, low 4 bits;
// iOS's AppleT8010PMGR::setPerfState): print it, or set STATE and wait for
// bit 31 (change pending) to clear
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	volatile uint32_t *r = mmap(0, 0x4000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0x20e068000ULL);

	if (fd < 0 || r == MAP_FAILED) { perror("mmap"); return 1; }
	printf("before %08x\n", r[0]);
	if (argc > 1) {
		uint32_t v = (r[0] & ~0xfu) | (strtoul(argv[1], 0, 0) & 0xf);
		r[0] = v;
		for (int i = 0; i < 1000000 && (r[0] >> 31); i++)
			;
		printf("after  %08x\n", r[0]);
	}
	return 0;
}
