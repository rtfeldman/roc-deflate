// Decompress a raw DEFLATE stream with libdeflate and write the result.
// Used to check that streams produced by the Roc encoder are valid DEFLATE
// according to a decoder that is not the one that produced them.
//
//   roundtrip <compressed-file> <expected-uncompressed-size>
// Exits 0 and prints the decompressed bytes' length on success.
#include <libdeflate.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
	if (argc != 3) return 2;
	FILE *f = fopen(argv[1], "rb");
	if (!f) return 2;
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	rewind(f);
	unsigned char *in = malloc(n);
	if (fread(in, 1, n, f) != (size_t)n) return 2;
	fclose(f);

	size_t expected = strtoul(argv[2], NULL, 10);
	unsigned char *out = malloc(expected ? expected : 1);
	struct libdeflate_decompressor *d = libdeflate_alloc_decompressor();
	size_t actual = 0;
	enum libdeflate_result r =
		libdeflate_deflate_decompress(d, in, n, out, expected, &actual);
	if (r != LIBDEFLATE_SUCCESS) {
		fprintf(stderr, "decompress failed: %d\n", (int)r);
		return 1;
	}
	fwrite(out, 1, actual, stdout);
	return 0;
}
