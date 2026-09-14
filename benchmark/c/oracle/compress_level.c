// Compress a file with libdeflate at a given level and write the raw DEFLATE
// stream, so a Roc-produced stream can be compared against it byte for byte.
//   compress_level <level> <in> <out>
#include <libdeflate.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
	if (argc != 4) return 2;
	int level = atoi(argv[1]);
	FILE *f = fopen(argv[2], "rb");
	if (!f) return 2;
	fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f);
	unsigned char *in = malloc(n ? n : 1);
	if (n && fread(in, 1, n, f) != (size_t)n) return 2;
	fclose(f);

	struct libdeflate_compressor *c = libdeflate_alloc_compressor(level);
	size_t bound = libdeflate_deflate_compress_bound(c, n);
	unsigned char *out = malloc(bound);
	size_t got = libdeflate_deflate_compress(c, in, n, out, bound);
	if (got == 0) { fprintf(stderr, "compress failed\n"); return 1; }

	FILE *o = fopen(argv[3], "wb");
	fwrite(out, 1, got, o);
	fclose(o);
	printf("%zu\n", got);
	return 0;
}
