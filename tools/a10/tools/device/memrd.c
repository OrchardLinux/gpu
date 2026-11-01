// memrd ADDR COUNT: COUNT u32 words of physical memory at ADDR (/dev/mem)
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	uint64_t a = strtoull(argv[1], 0, 0);
	unsigned n = atoi(argv[2]);
	uint32_t *w = calloc(n, 4);
	int fd = open("/dev/mem", O_RDONLY);

	if (fd < 0 || pread(fd, w, n * 4, a) != (ssize_t)(n * 4)) { perror("read"); return 1; }
	for (unsigned i = 0; i < n; i++)
		printf("%s%08x", i % 8 ? " " : (i ? "\n" : ""), w[i]);
	printf("\n");
	return 0;
}
