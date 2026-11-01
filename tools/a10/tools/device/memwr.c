// memwr ADDR VALUE: write one u32 to physical memory (/dev/mem)
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	uint64_t a = strtoull(argv[1], 0, 0);
	uint32_t v = strtoul(argv[2], 0, 0);
	int fd = open("/dev/mem", O_RDWR | O_SYNC);

	if (fd < 0 || pwrite(fd, &v, 4, a) != 4) { perror("write"); return 1; }
	return 0;
}
