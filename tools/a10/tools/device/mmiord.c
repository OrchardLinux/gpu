// mmiord ADDR COUNT: COUNT u32 registers at physical ADDR (mmap of /dev/mem)
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	uint64_t a = strtoull(argv[1], 0, 0), base = a & ~0x3fffULL;
	unsigned n = atoi(argv[2]);
	int fd = open("/dev/mem", O_RDONLY | O_SYNC);
	size_t len = (a - base) + n * 4 + 0x4000;
	volatile uint32_t *m = mmap(0, len, PROT_READ, MAP_SHARED, fd, base);

	if (fd < 0 || m == MAP_FAILED) { perror("mmap"); return 1; }
	m = (volatile uint32_t *)((volatile char *)m + (a - base));
	for (unsigned i = 0; i < n; i++)
		printf("%s%08x", i % 8 ? " " : (i ? "\n" : ""), m[i]);
	printf("\n");
	return 0;
}
