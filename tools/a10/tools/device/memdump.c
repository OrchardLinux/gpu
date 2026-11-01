// memdump ADDR SIZE OUT: copy physical memory to a file (/dev/mem)
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	uint64_t a = strtoull(argv[1], 0, 0);
	size_t n = strtoull(argv[2], 0, 0);
	char *b = malloc(n);
	int fd = open("/dev/mem", O_RDONLY);
	FILE *f;

	if (fd < 0 || pread(fd, b, n, a) != (ssize_t)n) { perror("read"); return 1; }
	f = fopen(argv[3], "wb");
	fwrite(b, 1, n, f);
	fclose(f);
	return 0;
}
