// Decompression benchmark driver against libdeflate, plus the stream
// generator that produces the exact bytes both engines decode.
//
//   dbench gen <original> <out.deflate>          compress at level 6, raw deflate
//   dbench bench <stream.deflate> <original> <N> verify, then min-of-N MB/s
//
// The bench mode decompresses into a caller-allocated exact-size buffer,
// verifies byte-for-byte against the original once, then times N reps and
// prints:  c\t<min_ns>\t<mbps>
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
    if (fread(buf, 1, *len, f) != *len) exit(3);
    fclose(f);
    return buf;
}

static int gen(const char *orig_path, const char *out_path) {
    size_t n;
    unsigned char *data = slurp(orig_path, &n);
    struct libdeflate_compressor *c = libdeflate_alloc_compressor(6);
    size_t cap = libdeflate_deflate_compress_bound(c, n);
    unsigned char *out = malloc(cap);
    size_t sz = libdeflate_deflate_compress(c, data, n, out, cap);
    if (sz == 0) { fprintf(stderr, "compress failed\n"); return 4; }
    FILE *f = fopen(out_path, "wb");
    if (!f || fwrite(out, 1, sz, f) != sz) { fprintf(stderr, "write failed\n"); return 5; }
    fclose(f);
    return 0;
}

static int bench(const char *stream_path, const char *orig_path, int reps) {
    size_t stream_len, orig_len;
    unsigned char *stream = slurp(stream_path, &stream_len);
    unsigned char *orig = slurp(orig_path, &orig_len);

    struct libdeflate_decompressor *d = libdeflate_alloc_decompressor();
    unsigned char *out = malloc(orig_len);
    size_t actual = 0;
    enum libdeflate_result r = libdeflate_deflate_decompress(d, stream, stream_len, out, orig_len, &actual);
    if (r != LIBDEFLATE_SUCCESS || actual != orig_len || memcmp(out, orig, orig_len) != 0) {
        fprintf(stderr, "VERIFY FAIL\n");
        return 6;
    }

    long long best = 0;
    for (int i = 0; i < reps; i++) {
        struct timespec t0, t1;
        clock_gettime(CLOCK_MONOTONIC, &t0);
        libdeflate_deflate_decompress(d, stream, stream_len, out, orig_len, &actual);
        clock_gettime(CLOCK_MONOTONIC, &t1);
        long long ns = (t1.tv_sec - t0.tv_sec) * 1000000000LL + (t1.tv_nsec - t0.tv_nsec);
        if (i == 0 || ns < best) best = ns;
    }
    long long mbps_x10 = (long long)orig_len * 10000LL / best;
    printf("c\t%lld\t%lld.%lld\n", best, mbps_x10 / 10, mbps_x10 % 10);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 4 && strcmp(argv[1], "gen") == 0) return gen(argv[2], argv[3]);
    if (argc == 5 && strcmp(argv[1], "bench") == 0) return bench(argv[2], argv[3], atoi(argv[4]));
    fprintf(stderr, "usage: dbench gen <original> <out.deflate>\n"
                    "       dbench bench <stream.deflate> <original> <reps>\n");
    return 1;
}
