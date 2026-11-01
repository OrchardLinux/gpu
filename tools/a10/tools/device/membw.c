// membw: CPU memory bandwidth (memset and memcpy over 64 MiB buffers)
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }

int main(void)
{
	const size_t n = 64 << 20;
	char *a = malloc(n), *b = malloc(n);
	memset(a, 1, n); memset(b, 2, n);
	double t = now();
	for (int i = 0; i < 10; i++) memset(a, i, n);
	double w = 10.0 * n / (now() - t) / 1e9;
	t = now();
	for (int i = 0; i < 10; i++) memcpy(b, a, n);
	double c = 10.0 * n / (now() - t) / 1e9;
	printf("write %.1f GB/s, copy %.1f GB/s (read+write %.1f)\n", w, c, 2 * c);
	return a[1] + b[2] == 0;
}
