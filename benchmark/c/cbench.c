// Reference DEFLATE benchmark: libdeflate and zlib-ng on the same bytes, with
// the same measurement protocol roc-deflate is held to.
//
// The target is three matched points, not a curve. roc-deflate's `Fastest`,
// `Balanced`, and `Smallest` are paired with the C library's lowest, default,
// and highest levels, and at each of those three points roc-deflate must match
// the C library on *both* compression ratio and throughput, within noise. A
// win at one setting does not pay for a loss at another. The pairing lives in
// LD_TRIPLE / ZNG_TRIPLE below; benchmark/compare.sh renders the verdict.
//
// Everything here is raw DEFLATE (RFC 1951) with no zlib/gzip wrapper and no
// checksum, so the numbers are compression and decompression work alone.
//
// Each measurement warms up once, then repeats until it has both a minimum
// iteration count and a minimum elapsed time, and reports the fastest and the
// median of those iterations. The fastest is the headline number: it is the run
// least disturbed by scheduling and interrupts, and it is reproducible across
// machines under load in a way a mean never is.
//
// Throughput is always uncompressed bytes per second, for both directions, so
// compress and decompress numbers are directly comparable (the lzbench
// convention).
//
// Usage:
//     cbench [options] <file>...
//
// Options:
//     --engines=libdeflate,zlibng   which implementations to run
//     --ld-levels=1,6,12            libdeflate levels (1-12)
//     --zng-levels=1,6,9            zlib-ng levels (1-9)
//     --min-iters=N                 minimum timed iterations (default 5)
//     --min-ms=N                    keep iterating until this many ms elapse (default 400)
//     --max-ms=N                    stop iterating once this many ms elapse (default 8000)
//     --max-iters=N                 hard cap on iterations (default 200)
//     --chunk=N                     also measure zlib-ng streaming in N-byte chunks
//     --format=human|tsv            output format (default human)

#include <errno.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "libdeflate.h"
#include "zlib-ng.h"

#ifdef __APPLE__
#include <pthread/qos.h>
#endif

#define MAX_ITERS_LIMIT 100000
#define MAX_LEVELS 16
#define WINDOW_BITS_RAW (-15)
#define ZNG_MEM_LEVEL 8

// ---------------------------------------------------------------- utilities

static void die(const char *fmt, ...) {
	va_list args;
	va_start(args, fmt);
	fprintf(stderr, "cbench: ");
	vfprintf(stderr, fmt, args);
	fprintf(stderr, "\n");
	va_end(args);
	exit(1);
}

static void *xmalloc(size_t n) {
	void *p = malloc(n ? n : 1);
	if (!p)
		die("out of memory (%zu bytes)", n);
	return p;
}

static uint64_t now_ns(void) {
	struct timespec ts;
	if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0)
		die("clock_gettime failed: %s", strerror(errno));
	return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}

static int cmp_u64(const void *a, const void *b) {
	uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b;
	return (x > y) - (x < y);
}

// ------------------------------------------------------------- measurement

typedef struct {
	uint64_t best_ns;
	uint64_t median_ns;
	unsigned iters;
} Timing;

// How long a single measurement may run. It iterates until it has both
// min_iters samples and min_ns of elapsed time, but max_ns cuts it off
// regardless: the slowest levels on the largest corpus files take seconds per
// iteration, and five of those buys no accuracy worth the wait.
typedef struct {
	unsigned min_iters;
	unsigned max_iters;
	uint64_t min_ns;
	uint64_t max_ns;
} Budget;

// One timed unit of work. Returns a value derived from the work so the compiler
// cannot elide it; the harness accumulates it into a sink.
typedef size_t (*WorkFn)(void *ctx);

static volatile size_t g_sink;

static Timing measure(WorkFn work, void *ctx, const Budget *budget) {
	uint64_t *samples = xmalloc(budget->max_iters * sizeof(uint64_t));
	uint64_t elapsed = 0;
	unsigned iters = 0;

	g_sink += work(ctx); // warmup: fault in buffers, prime caches and branch predictors

	while (iters < budget->max_iters && elapsed < budget->max_ns &&
	       (iters < budget->min_iters || elapsed < budget->min_ns)) {
		uint64_t start = now_ns();
		size_t produced = work(ctx);
		uint64_t stop = now_ns();
		g_sink += produced;
		samples[iters++] = stop - start;
		elapsed += stop - start;
	}

	qsort(samples, iters, sizeof(uint64_t), cmp_u64);
	Timing t = {
		.best_ns = samples[0],
		.median_ns = samples[iters / 2],
		.iters = iters,
	};
	free(samples);
	return t;
}

static double mb_per_sec(size_t bytes, uint64_t ns) {
	if (ns == 0)
		return 0.0;
	return (double)bytes * 1000.0 / (double)ns; // bytes/ns -> MB/s (1e6 bytes)
}

// ------------------------------------------------------------- libdeflate

typedef struct {
	struct libdeflate_compressor *compressor;
	const uint8_t *in;
	size_t in_len;
	uint8_t *out;
	size_t out_cap;
	size_t last_out_len;
} LdCompressCtx;

static size_t ld_compress_work(void *raw) {
	LdCompressCtx *ctx = raw;
	size_t n = libdeflate_deflate_compress(ctx->compressor, ctx->in, ctx->in_len,
	                                       ctx->out, ctx->out_cap);
	if (n == 0)
		die("libdeflate_deflate_compress ran out of output space");
	ctx->last_out_len = n;
	return n;
}

typedef struct {
	struct libdeflate_decompressor *decompressor;
	const uint8_t *in;
	size_t in_len;
	uint8_t *out;
	size_t out_len;
} LdDecompressCtx;

static size_t ld_decompress_work(void *raw) {
	LdDecompressCtx *ctx = raw;
	size_t produced = 0;
	enum libdeflate_result r = libdeflate_deflate_decompress(
		ctx->decompressor, ctx->in, ctx->in_len, ctx->out, ctx->out_len, &produced);
	if (r != LIBDEFLATE_SUCCESS)
		die("libdeflate_deflate_decompress failed (%d)", (int)r);
	if (produced != ctx->out_len)
		die("libdeflate decompressed %zu bytes, expected %zu", produced, ctx->out_len);
	return produced;
}

// ---------------------------------------------------------------- zlib-ng

// zlib-ng's deflate/inflate objects are reset rather than reallocated between
// iterations, so the timed region is the same steady-state work libdeflate does
// with a reused compressor.

typedef struct {
	zng_stream stream;
	int level;
	const uint8_t *in;
	size_t in_len;
	uint8_t *out;
	size_t out_cap;
	size_t chunk; // 0 = one shot; otherwise feed and drain in chunks of this size
	size_t last_out_len;
} ZngCompressCtx;

static void zng_compress_init(ZngCompressCtx *ctx) {
	memset(&ctx->stream, 0, sizeof(ctx->stream));
	int rc = zng_deflateInit2(&ctx->stream, ctx->level, Z_DEFLATED, WINDOW_BITS_RAW,
	                          ZNG_MEM_LEVEL, Z_DEFAULT_STRATEGY);
	if (rc != Z_OK)
		die("zng_deflateInit2 failed (%d)", rc);
}

static size_t zng_compress_work(void *raw) {
	ZngCompressCtx *ctx = raw;
	if (zng_deflateReset(&ctx->stream) != Z_OK)
		die("zng_deflateReset failed");

	size_t fed = 0;
	size_t produced = 0;
	size_t chunk = ctx->chunk ? ctx->chunk : ctx->in_len;

	for (;;) {
		size_t take = ctx->in_len - fed;
		if (take > chunk)
			take = chunk;
		bool last = (fed + take == ctx->in_len);

		ctx->stream.next_in = (const uint8_t *)ctx->in + fed;
		ctx->stream.avail_in = (uint32_t)take;
		fed += take;

		// Drain into the output buffer, in chunk-sized windows when streaming, so
		// a streaming run pays the real per-window bookkeeping instead of writing
		// into one giant buffer.
		for (;;) {
			size_t room = ctx->out_cap - produced;
			if (ctx->chunk && room > chunk)
				room = chunk;
			if (room == 0)
				die("zlib-ng compress ran out of output space");
			ctx->stream.next_out = ctx->out + produced;
			ctx->stream.avail_out = (uint32_t)room;

			int rc = zng_deflate(&ctx->stream, last ? Z_FINISH : Z_NO_FLUSH);
			produced += room - ctx->stream.avail_out;
			if (rc == Z_STREAM_END)
				goto done;
			if (rc != Z_OK && rc != Z_BUF_ERROR)
				die("zng_deflate failed (%d)", rc);
			if (ctx->stream.avail_out != 0 && ctx->stream.avail_in == 0)
				break; // consumed this input chunk and the encoder wants more
		}
	}
done:
	ctx->last_out_len = produced;
	return produced;
}

typedef struct {
	zng_stream stream;
	const uint8_t *in;
	size_t in_len;
	uint8_t *out;
	size_t out_len;
	size_t chunk;
} ZngDecompressCtx;

static void zng_decompress_init(ZngDecompressCtx *ctx) {
	memset(&ctx->stream, 0, sizeof(ctx->stream));
	int rc = zng_inflateInit2(&ctx->stream, WINDOW_BITS_RAW);
	if (rc != Z_OK)
		die("zng_inflateInit2 failed (%d)", rc);
}

static size_t zng_decompress_work(void *raw) {
	ZngDecompressCtx *ctx = raw;
	if (zng_inflateReset(&ctx->stream) != Z_OK)
		die("zng_inflateReset failed");

	size_t fed = 0;
	size_t produced = 0;
	size_t chunk = ctx->chunk ? ctx->chunk : ctx->in_len;

	for (;;) {
		size_t take = ctx->in_len - fed;
		if (take > chunk)
			take = chunk;
		ctx->stream.next_in = (const uint8_t *)ctx->in + fed;
		ctx->stream.avail_in = (uint32_t)take;
		fed += take;

		for (;;) {
			size_t room = ctx->out_len - produced;
			if (ctx->chunk && room > chunk)
				room = chunk;
			if (room == 0 && fed == ctx->in_len)
				goto done;
			ctx->stream.next_out = ctx->out + produced;
			ctx->stream.avail_out = (uint32_t)room;

			int rc = zng_inflate(&ctx->stream, Z_NO_FLUSH);
			produced += room - ctx->stream.avail_out;
			if (rc == Z_STREAM_END)
				goto done;
			if (rc != Z_OK && rc != Z_BUF_ERROR)
				die("zng_inflate failed (%d)", rc);
			if (ctx->stream.avail_in == 0)
				break;
			if (rc == Z_BUF_ERROR && ctx->stream.avail_out != 0)
				break;
		}
		if (fed == ctx->in_len && produced == ctx->out_len)
			break;
		if (fed == ctx->in_len && ctx->stream.avail_in == 0 && produced < ctx->out_len)
			die("zng_inflate ended early: %zu of %zu bytes", produced, ctx->out_len);
	}
done:
	if (produced != ctx->out_len)
		die("zlib-ng inflated %zu bytes, expected %zu", produced, ctx->out_len);
	return produced;
}

// ------------------------------------------------------------------- rows

typedef struct {
	const char *file;
	const char *engine;
	const char *op;
	const char *setting; // "fastest" / "balanced" / "smallest", or "-" off the triple
	int level;
	size_t chunk;
	size_t orig_bytes;
	size_t comp_bytes;
	Timing timing;
} Row;

static const char *g_format = "human";

static void emit(const Row *r) {
	double ratio = r->orig_bytes ? 100.0 * (double)r->comp_bytes / (double)r->orig_bytes : 0.0;
	double best = mb_per_sec(r->orig_bytes, r->timing.best_ns);
	double med = mb_per_sec(r->orig_bytes, r->timing.median_ns);

	if (strcmp(g_format, "tsv") == 0) {
		printf("%s\t%s\t%s\t%s\t%d\t%zu\t%zu\t%zu\t%.4f\t%llu\t%llu\t%u\t%.2f\t%.2f\n",
		       r->file, r->engine, r->op, r->setting, r->level, r->chunk,
		       r->orig_bytes, r->comp_bytes, ratio,
		       (unsigned long long)r->timing.best_ns,
		       (unsigned long long)r->timing.median_ns, r->timing.iters, best, med);
	} else {
		char label[64];
		if (r->chunk)
			snprintf(label, sizeof(label), "%s-%d/%zuk", r->engine, r->level, r->chunk / 1024);
		else
			snprintf(label, sizeof(label), "%s-%d", r->engine, r->level);
		printf("  %-8s %-18s %-9s %11zu %11zu %6.2f%% %9.1f %9.1f %5u\n", r->op, label,
		       r->setting, r->orig_bytes, r->comp_bytes, ratio, best, med, r->timing.iters);
	}
	fflush(stdout);
}

static void emit_header(const char *file, size_t bytes) {
	if (strcmp(g_format, "tsv") == 0)
		return;
	printf("\n== %s (%zu bytes)\n", file, bytes);
	printf("  %-8s %-18s %-9s %11s %11s %7s %9s %9s %5s\n", "op", "engine",
	       "setting", "orig", "comp", "ratio", "best", "median", "iters");
	printf("  %-8s %-18s %-9s %11s %11s %7s %9s %9s %5s\n", "", "", "", "", "",
	       "", "MB/s", "MB/s", "");
}

// --------------------------------------------------------------- driver

typedef struct {
	int levels[MAX_LEVELS];
	int count;
} Levels;

// An engine's lowest, default, and highest compression level.
typedef struct {
	int low, mid, high;
} Triple;

// Which C level each roc-deflate setting is held to. This pairing is the whole
// point of the benchmark: roc-deflate at its lowest setting must match the C
// library at *its* lowest, and likewise for middle and highest, on both ratio
// and throughput. Level numbers are not comparable across libraries, so the
// pairing is by position -- lowest, default, highest -- and lives here alone.
static const Triple LD_TRIPLE = { 1, 6, 12 };  // libdeflate spans 1-12, default 6
static const Triple ZNG_TRIPLE = { 1, 6, 9 };  // zlib-ng spans 1-9, default 6

static const char *setting_for(const Triple *t, int level) {
	if (level == t->low)
		return "fastest";
	if (level == t->mid)
		return "balanced";
	if (level == t->high)
		return "smallest";
	return "-";
}

static void triple_levels(const Triple *t, Levels *out) {
	out->count = 3;
	out->levels[0] = t->low;
	out->levels[1] = t->mid;
	out->levels[2] = t->high;
}

static void parse_levels(const char *s, Levels *out, int lo, int hi) {
	out->count = 0;
	while (*s) {
		char *end;
		long v = strtol(s, &end, 10);
		if (end == s)
			die("bad level list near \"%s\"", s);
		if (v < lo || v > hi)
			die("level %ld out of range %d-%d", v, lo, hi);
		if (out->count == MAX_LEVELS)
			die("too many levels (max %d)", MAX_LEVELS);
		out->levels[out->count++] = (int)v;
		s = (*end == ',') ? end + 1 : end;
	}
	if (out->count == 0)
		die("empty level list");
}

static uint8_t *read_file(const char *path, size_t *len_out) {
	FILE *f = fopen(path, "rb");
	if (!f)
		die("cannot open %s: %s", path, strerror(errno));
	if (fseek(f, 0, SEEK_END) != 0)
		die("cannot seek %s", path);
	long size = ftell(f);
	if (size < 0)
		die("cannot size %s", path);
	rewind(f);
	uint8_t *buf = xmalloc((size_t)size);
	if (size > 0 && fread(buf, 1, (size_t)size, f) != (size_t)size)
		die("short read on %s", path);
	fclose(f);
	*len_out = (size_t)size;
	return buf;
}

static const char *basename_of(const char *path) {
	const char *slash = strrchr(path, '/');
	return slash ? slash + 1 : path;
}

static void run_libdeflate(const char *name, const uint8_t *in, size_t in_len,
                           const Levels *levels, const Budget *budget) {
	size_t bound = libdeflate_deflate_compress_bound(NULL, in_len);
	uint8_t *comp = xmalloc(bound);
	uint8_t *decomp = xmalloc(in_len);

	struct libdeflate_decompressor *dec = libdeflate_alloc_decompressor();
	if (!dec)
		die("libdeflate_alloc_decompressor failed");

	for (int i = 0; i < levels->count; i++) {
		int level = levels->levels[i];
		struct libdeflate_compressor *comp_obj = libdeflate_alloc_compressor(level);
		if (!comp_obj)
			die("libdeflate_alloc_compressor(%d) failed", level);

		LdCompressCtx cctx = {
			.compressor = comp_obj,
			.in = in,
			.in_len = in_len,
			.out = comp,
			.out_cap = bound,
		};
		const char *setting = setting_for(&LD_TRIPLE, level);
		Timing ct = measure(ld_compress_work, &cctx, budget);
		emit(&(Row){ name, "libdeflate", "compress", setting, level, 0, in_len,
		             cctx.last_out_len, ct });

		LdDecompressCtx dctx = {
			.decompressor = dec,
			.in = comp,
			.in_len = cctx.last_out_len,
			.out = decomp,
			.out_len = in_len,
		};
		Timing dt = measure(ld_decompress_work, &dctx, budget);
		if (memcmp(decomp, in, in_len) != 0)
			die("libdeflate round-trip mismatch at level %d", level);
		emit(&(Row){ name, "libdeflate", "decomp", setting, level, 0, in_len,
		             cctx.last_out_len, dt });

		libdeflate_free_compressor(comp_obj);
	}

	libdeflate_free_decompressor(dec);
	free(comp);
	free(decomp);
}

static void run_zlibng(const char *name, const uint8_t *in, size_t in_len,
                       const Levels *levels, size_t chunk, const Budget *budget) {
	// Worst case for raw DEFLATE is every block stored: a 5-byte header per
	// 65535-byte block, plus slack for the final empty block.
	size_t bound = in_len + 5 * (in_len / 65535 + 1) + 64;
	uint8_t *comp = xmalloc(bound);
	uint8_t *decomp = xmalloc(in_len);

	for (int i = 0; i < levels->count; i++) {
		int level = levels->levels[i];

		ZngCompressCtx cctx = {
			.level = level,
			.in = in,
			.in_len = in_len,
			.out = comp,
			.out_cap = bound,
			.chunk = chunk,
		};
		const char *setting = setting_for(&ZNG_TRIPLE, level);
		zng_compress_init(&cctx);
		Timing ct = measure(zng_compress_work, &cctx, budget);
		emit(&(Row){ name, "zlibng", "compress", setting, level, chunk, in_len,
		             cctx.last_out_len, ct });
		zng_deflateEnd(&cctx.stream);

		ZngDecompressCtx dctx = {
			.in = comp,
			.in_len = cctx.last_out_len,
			.out = decomp,
			.out_len = in_len,
			.chunk = chunk,
		};
		zng_decompress_init(&dctx);
		Timing dt = measure(zng_decompress_work, &dctx, budget);
		if (memcmp(decomp, in, in_len) != 0)
			die("zlib-ng round-trip mismatch at level %d", level);
		emit(&(Row){ name, "zlibng", "decomp", setting, level, chunk, in_len,
		             cctx.last_out_len, dt });
		zng_inflateEnd(&dctx.stream);
	}

	free(comp);
	free(decomp);
}

static bool arg_prefix(const char *arg, const char *prefix, const char **value) {
	size_t n = strlen(prefix);
	if (strncmp(arg, prefix, n) != 0)
		return false;
	*value = arg + n;
	return true;
}

int main(int argc, char **argv) {
#ifdef __APPLE__
	// Ask for a performance core. Without this the benchmark can land on an
	// efficiency core and read 3-4x slow for reasons that have nothing to do
	// with the code under test.
	pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#endif

	// Default to exactly the three paired settings: that comparison is the
	// benchmark's reason for existing, and everything else is diagnostics.
	Levels ld_levels, zng_levels;
	triple_levels(&LD_TRIPLE, &ld_levels);
	triple_levels(&ZNG_TRIPLE, &zng_levels);

	bool want_libdeflate = true, want_zlibng = true;
	size_t chunk = 0;
	Budget budget = {
		.min_iters = 5,
		.max_iters = 200,
		.min_ns = 400ull * 1000000ull,
		.max_ns = 8000ull * 1000000ull,
	};

	int first_file = argc;
	for (int i = 1; i < argc; i++) {
		const char *value;
		if (arg_prefix(argv[i], "--engines=", &value)) {
			want_libdeflate = strstr(value, "libdeflate") != NULL;
			want_zlibng = strstr(value, "zlibng") != NULL;
			if (!want_libdeflate && !want_zlibng)
				die("--engines must name libdeflate and/or zlibng");
		} else if (arg_prefix(argv[i], "--ld-levels=", &value)) {
			parse_levels(value, &ld_levels, 1, 12);
		} else if (arg_prefix(argv[i], "--zng-levels=", &value)) {
			parse_levels(value, &zng_levels, 1, 9);
		} else if (arg_prefix(argv[i], "--min-iters=", &value)) {
			budget.min_iters = (unsigned)strtoul(value, NULL, 10);
		} else if (arg_prefix(argv[i], "--max-iters=", &value)) {
			budget.max_iters = (unsigned)strtoul(value, NULL, 10);
			if (budget.max_iters == 0 || budget.max_iters > MAX_ITERS_LIMIT)
				die("--max-iters must be 1-%d", MAX_ITERS_LIMIT);
		} else if (arg_prefix(argv[i], "--min-ms=", &value)) {
			budget.min_ns = strtoull(value, NULL, 10) * 1000000ull;
		} else if (arg_prefix(argv[i], "--max-ms=", &value)) {
			budget.max_ns = strtoull(value, NULL, 10) * 1000000ull;
		} else if (arg_prefix(argv[i], "--chunk=", &value)) {
			chunk = strtoull(value, NULL, 10);
		} else if (arg_prefix(argv[i], "--format=", &value)) {
			if (strcmp(value, "human") != 0 && strcmp(value, "tsv") != 0)
				die("--format must be human or tsv");
			g_format = value;
		} else if (argv[i][0] == '-') {
			die("unknown option %s", argv[i]);
		} else {
			first_file = i;
			break;
		}
	}

	if (first_file >= argc)
		die("no input files; usage: cbench [options] <file>...");

	if (budget.min_iters > budget.max_iters)
		budget.min_iters = budget.max_iters;

	if (strcmp(g_format, "tsv") == 0)
		printf("file\tengine\top\tsetting\tlevel\tchunk\torig\tcomp\tratio_pct\tbest_ns\tmedian_ns\titers\tbest_mbps\tmedian_mbps\n");

	for (int i = first_file; i < argc; i++) {
		size_t len;
		uint8_t *data = read_file(argv[i], &len);
		if (len == 0)
			die("%s is empty", argv[i]);
		const char *name = basename_of(argv[i]);

		emit_header(name, len);
		if (want_libdeflate)
			run_libdeflate(name, data, len, &ld_levels, &budget);
		if (want_zlibng)
			run_zlibng(name, data, len, &zng_levels, chunk, &budget);

		free(data);
	}

	return 0;
}
