// adtscan: find Apple device tree "perf-states" properties in physical RAM
// (/dev/mem), print them and save 64 KiB around each: adtscan START END OUTDIR
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	uint64_t start = strtoull(argv[1], 0, 0), end = strtoull(argv[2], 0, 0);
	const size_t chunk = 1 << 20;
	char key[32] = "perf-states";
	unsigned char *buf = malloc(chunk + 4096);
	int fd = open("/dev/mem", O_RDONLY), found = 0;

	if (fd < 0) { perror("/dev/mem"); return 1; }
	for (uint64_t a = start; a < end; a += chunk) {
		ssize_t n = pread(fd, buf, chunk + 4096, a);
		if (n < 36)
			continue;
		for (ssize_t i = 0; i + 36 + 128 <= n && i < (ssize_t)chunk; i += 4) {
			if (memcmp(buf + i, key, 32))
				continue;
			uint32_t len = *(uint32_t *)(buf + i + 32) & 0x7fffffff;
			uint32_t *v = (uint32_t *)(buf + i + 36);
			int nz = 0;
			for (unsigned k = 0; k < len / 4 && k < 64; k++)
				nz |= v[k] != 0;
			printf("0x%llx len %u%s:", (unsigned long long)(a + i), len, nz ? "" : " (zeros)");
			for (unsigned k = 0; k < len / 4 && k < 32; k++)
				printf(" %08x", v[k]);
			printf("\n");
			if (nz && found < 4) {
				char path[256];
				unsigned char *dump = malloc(65536);
				snprintf(path, sizeof(path), "%s/adt-%d.bin", argv[3], found++);
				if (pread(fd, dump, 65536, a + i - 32768) == 65536) {
					FILE *f = fopen(path, "wb");
					fwrite(dump, 1, 65536, f);
					fclose(f);
				}
				free(dump);
			}
		}
	}
	return 0;
}
