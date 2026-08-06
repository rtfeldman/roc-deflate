// Compression benchmark driver against libdeflate.
//
//   cbench <original> <level> <reps> [out.deflate]
//
// Verifies the compressed stream round-trips, then times `reps`
// compressions into a caller-allocated bound-sized buffer, reusing one
// compressor across reps exactly as a caller would, and prints:
//   c\t<min_ns>\t<mbps>\t<compressed_size>
// Throughput is over the uncompressed input, which is the work done.
#include <libdeflate.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static unsigned char *slurp(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", path); exit(2); }
    fseek(f, 0, SEEK_END);
    *len = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *buf = malloc(*len);
    if (*len && fread(buf, 1, *len, f) != *len) exit(3);
    fclose(f);
    return buf;
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: cbench <original> <level> <reps> [out.deflate]\n");
        return 1;
    }
    size_t n;
    unsigned char *in = slurp(argv[1], &n);
    int level = atoi(argv[2]);
    int reps = atoi(argv[3]);

    struct libdeflate_compressor *c = libdeflate_alloc_compressor(level);
    size_t cap = libdeflate_deflate_compress_bound(c, n);
    unsigned char *out = malloc(cap);

    size_t sz = libdeflate_deflate_compress(c, in, n, out, cap);
    if (sz == 0) { fprintf(stderr, "compress failed\n"); return 4; }

    // Verify the stream decompresses back to the input.
    struct libdeflate_decompressor *d = libdeflate_alloc_decompressor();
    unsigned char *back = malloc(n ? n : 1);
    size_t actual = 0;
    if (libdeflate_deflate_decompress(d, out, sz, back, n, &actual) != LIBDEFLATE_SUCCESS
        || actual != n || (n && memcmp(back, in, n) != 0)) {
        fprintf(stderr, "VERIFY FAIL\n");
        return 5;
    }

    long long best = 0;
    for (int i = 0; i < reps; i++) {
        struct timespec t0, t1;
        clock_gettime(CLOCK_MONOTONIC, &t0);
        sz = libdeflate_deflate_compress(c, in, n, out, cap);
        clock_gettime(CLOCK_MONOTONIC, &t1);
        long long ns = (t1.tv_sec - t0.tv_sec) * 1000000000LL + (t1.tv_nsec - t0.tv_nsec);
        if (i == 0 || ns < best) best = ns;
    }
    long long mbps_x10 = (long long)n * 10000LL / (best ? best : 1);
    printf("c\t%lld\t%lld.%lld\t%zu\n", best, mbps_x10 / 10, mbps_x10 % 10, sz);

    if (argc > 4) { FILE *o = fopen(argv[4], "wb"); fwrite(out, 1, sz, o); fclose(o); }
    return 0;
}
