#include <stdio.h>
#include <stdlib.h>
#include "deflate_compress_inst.c"

int main(int argc, char **argv) {
	FILE *f = fopen(argv[2], "rb");
	fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
	unsigned char *in = malloc(n); fread(in, 1, n, f); fclose(f);
	struct libdeflate_compressor *c = libdeflate_alloc_compressor(atoi(argv[1]));
	size_t cap = libdeflate_deflate_compress_bound(c, n);
	unsigned char *out = malloc(cap);
	size_t got = libdeflate_deflate_compress(c, in, n, out, cap);
	printf("%zu\n", got);
	if (argc > 3) { FILE *g = fopen(argv[3], "wb"); fwrite(out, 1, got, g); fclose(g); }
	return 0;
}
