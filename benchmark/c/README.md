# C reference benchmark

The bar roc-deflate is measured against: the two fastest open-source DEFLATE
implementations, timed on the same bytes under the same protocol.

- **[libdeflate](https://github.com/ebiggers/libdeflate)** — the fastest
  whole-buffer DEFLATE codec. Whole-buffer only: it has no streaming API, so it
  sets the ceiling for one-shot `compress`/`decompress`.
- **[zlib-ng](https://github.com/zlib-ng/zlib-ng)** — the fastest streaming
  DEFLATE codec, and the reference for the chunked-`Iter` API. `--chunk=N` runs
  it through its streaming interface in `N`-byte windows, so the cost of
  streaming is measured rather than assumed.

Both are built as static libraries at `-O3`, which is what `--opt=speed`
gives the Roc side, with zlib-ng in its native-API mode
(`ZLIB_COMPAT=OFF`) so its symbols cannot collide with the platform zlib and
leave you benchmarking the wrong library.

Everything is **raw DEFLATE** (RFC 1951) — no zlib or gzip wrapper, no Adler-32
or CRC-32 — so what is timed is compression and decompression work alone, which
is exactly what `Deflate.compress` and `Deflate.decompress` do.

## Running

```sh
./benchmark/c/run.sh              # Silesia, all 12 files, the three paired levels
./benchmark/c/run.sh --quick      # Canterbury only, short budget
./benchmark/c/run.sh --tsv        # machine-readable, for compare.sh
```

`run.sh` builds on demand and fetches the Silesia corpus (~200 MB, verified
against pinned SHA-256s) into `benchmark/.corpus` on first use. Extra arguments
pass through to `cbench`:

```sh
./benchmark/c/run.sh --engines=libdeflate --ld-levels=6
./benchmark/c/run.sh --engines=zlibng --chunk=65536   # streaming
```

The library checkouts are expected next to this repo (`../libdeflate`,
`../zlib-ng`); override with `LIBDEFLATE_SRC` / `ZLIBNG_SRC`, and the
optimization level with `OPT_FLAGS`.

## Measurement protocol

Wall-clock numbers from a single compression run are not worth much: on this
kind of workload they swing 20-30% with scheduling alone. So each measurement:

- **warms up once, untimed**, faulting in buffers and priming caches and branch
  predictors, so the first timed iteration is not paying startup costs;
- **reuses the codec object** across iterations (`libdeflate_alloc_compressor`
  once, `zng_deflateReset` between runs) — allocation is not the thing under
  test, steady-state throughput is;
- **allocates output buffers outside the timed region**, so `malloc` behavior
  does not leak into the result;
- **iterates until it has both** at least `--min-iters` samples and
  `--min-ms` of elapsed time, capped by `--max-ms` so the slowest levels on the
  largest files stay tolerable;
- **reports the fastest iteration** as the headline number, with the median
  alongside. The fastest run is the one least disturbed by interrupts and
  migrations, and it reproduces across machines under load in a way a mean does
  not — repeated runs here land within ~1% of each other;
- **requests a performance core** on Apple Silicon
  (`QOS_CLASS_USER_INTERACTIVE`), since landing on an efficiency core reads 3-4x
  slow for reasons unrelated to the code;
- **verifies the round-trip** with `memcmp` before reporting, so a fast wrong
  answer cannot be mistaken for a fast right one.

Throughput is **uncompressed bytes per second in both directions** (the lzbench
convention), so compress and decompress numbers are directly comparable.

## The goal: three matched points

roc-deflate's `Fastest`, `Balanced`, and `Smallest` are paired with the C
library's **lowest, default, and highest** levels:

| roc-deflate | libdeflate | zlib-ng |
| ----------- | ---------- | ------- |
| `Fastest`   | 1          | 1       |
| `Balanced`  | 6          | 6       |
| `Smallest`  | 12         | 9       |

At each of those three points, roc-deflate must match the C library on **both
compression ratio and throughput**, within noise, for **both compression and
decompression**. That is six cells, and all six have to pass. Being faster at
one setting does not pay for being slower at another, and being smaller does not
pay for being slower — the settings mean different things to a caller, so each
one has to hold on its own.

The pairing is by position, not by level number: level 6 in one library and
level 6 in another are unrelated settings, so the only defensible mapping is
lowest-to-lowest, default-to-default, highest-to-highest. It is defined once, in
`LD_TRIPLE` / `ZNG_TRIPLE` in `cbench.c`, and `cbench` runs exactly those three
levels by default.

## Rendering the verdict

`benchmark/compare.sh` takes the two sides' TSV and prints the six cells with a
pass or fail on each, exiting nonzero unless all six pass, so it works as a gate:

```sh
./benchmark/c/run.sh --tsv > c.tsv
# ...produce roc.tsv in the same schema...
./benchmark/compare.sh roc.tsv c.tsv
```

```
== three-point verdict  (ratio within 0.50pp, throughput within 5.0%)

  setting   op             roc        c     delta        roc          c     delta   verdict
                         ratio    ratio      (pp)       MB/s       MB/s       (%)
  fastest   compress    40.20%   40.00%     +0.20      970.9     1000.0     -2.9%   PASS
  balanced  compress    37.80%   37.00%     +0.80      242.7      250.0     -2.9%   FAIL (ratio)
  ...
```

Sizes and times are summed across the corpus before the ratio and throughput are
computed, so the numbers are corpus totals rather than an average of per-file
numbers (which would over-weight the small files).

### Tolerances

`--speed-tol` defaults to **5%**, comfortably above the ~1-2% run-to-run spread
the protocol above produces, so a passing result does not flap between runs.

`--ratio-tol` defaults to **0.5 percentage points**. Compression ratio is
deterministic — it has no run-to-run noise at all — so this one is not a noise
band but a policy choice: it is the margin by which two different algorithms are
called equivalent. Tighten it toward zero for a stricter bar.

### Decompression is not comparable yet

The decompression rows do not currently support a verdict, for two reasons.

Ratio is not a property of decompression at all. A decoder is handed a stream
whose size is already fixed and either reproduces the original bytes or does
not, so the ratio shown on a `decomp` row is just the stream it was given,
echoing the `compress` row above it.

Worse, each side is measured on a *different* stream: roc-deflate decompresses
its own output and libdeflate decompresses its own. Those differ in size and in
kind -- roc-deflate emits fixed-Huffman blocks, libdeflate emits dynamic ones,
and building code tables is work a fixed-Huffman stream never asks for. So the
throughput numbers are not measuring the same job.

Making this meaningful needs one canonical stream per (file, setting), produced
by a single reference encoder, with every decoder timed on those identical
bytes. That means `cbench` writing the streams out and both harnesses reading
them. Until that exists, read the `decomp` rows as "each decoder on its own
output" and not as a comparison.

### TSV schema

`compare.sh` locates columns **by name** from the header row, so the two sides
only have to agree on column names, not order, and either may carry extra
columns. The columns it requires:

| column | meaning |
| ------ | ------- |
| `setting` | `fastest`, `balanced`, `smallest`, or `-` to be ignored |
| `op` | `compress` or `decomp` |
| `orig` | uncompressed bytes |
| `comp` | compressed bytes |
| `best_ns` | fastest iteration, nanoseconds |

A `setting` of `-` marks a diagnostic row from an off-triple level; those are
skipped, so running extra levels for investigation does not disturb the verdict.
