#!/usr/bin/env bash
# Benchmark roc-deflate decompression against libdeflate across the Silesia
# corpus and print the per-corpus gap table.
#
#     ./benchmark/decompress.sh [rounds] [reps]
#
# For each corpus file this runs `rounds` interleaved pairs of (libdeflate,
# roc), each reporting the fastest of `reps` decompressions, and keeps each
# engine's best round, which cancels thermal drift between the two sides.
# Both engines decode the same libdeflate-level-6 raw DEFLATE stream into a
# caller-allocated buffer of exactly the output size, verify the result
# byte-for-byte against the original, and time only the decompression.
#
# Prerequisites:
#   - a libdeflate source checkout (sibling directory or LIBDEFLATE_SRC)
#   - the roc compiler on PATH (or ROC pointing at it)
#   - mimalloc installed (brew install mimalloc / libmimalloc-dev); both
#     engines are run under the same allocator so allocator quality is not
#     part of the comparison
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rounds="${1:-3}"
reps="${2:-12}"
corpus="$here/.corpus"
streams="$here/.streams"
build="$here/.build"
roc="${ROC:-roc}"
cc="${CC:-cc}"
libdeflate_src="${LIBDEFLATE_SRC:-$here/../../libdeflate}"

files=(dickens mozilla mr nci ooffice osdb reymont samba sao webster x-ray xml)

if [ ! -d "$libdeflate_src" ]; then
	echo "missing libdeflate checkout: $libdeflate_src" >&2
	echo "clone ebiggers/libdeflate next to this repo, or set LIBDEFLATE_SRC" >&2
	exit 1
fi

"$here/corpus.sh" "$corpus"

mkdir -p "$build" "$streams"

# Build the C driver with libdeflate compiled in at -O3, matching what
# --opt=speed gives the Roc side.
if [ ! -x "$build/dbench" ] || [ "$here/dbench.c" -nt "$build/dbench" ]; then
	echo "building dbench"
	"$cc" -O3 -I"$libdeflate_src" -o "$build/dbench" "$here/dbench.c" \
		"$libdeflate_src"/lib/*.c "$libdeflate_src"/lib/*/*.c
fi

# The exact streams both engines decode: libdeflate level 6, raw DEFLATE.
for f in "${files[@]}"; do
	if [ ! -f "$streams/$f.deflate" ]; then
		echo "generating stream: $f"
		"$build/dbench" gen "$corpus/$f" "$streams/$f.deflate"
	fi
done

if [ ! -x "$build/dtime" ] || [ "$here/dtime.roc" -nt "$build/dtime" ]; then
	echo "building dtime (roc --opt=speed)"
	# roc build exits nonzero on warnings; judge success by the binary.
	rm -f "$here/dtime"
	(cd "$here" && "$roc" build --opt=speed dtime.roc) || true
	if [ ! -x "$here/dtime" ]; then
		echo "roc build failed" >&2
		exit 1
	fi
	mv "$here/dtime" "$build/dtime"
fi

# Run both engines under mimalloc so the allocator is held constant.
case "$(uname)" in
Darwin)
	mi="$(brew --prefix mimalloc 2>/dev/null)/lib/libmimalloc.dylib"
	if [ -f "$mi" ]; then
		export DYLD_INSERT_LIBRARIES="$mi"
	else
		echo "warning: mimalloc not found; running with the system allocator" >&2
	fi
	;;
*)
	mi="$(ldconfig -p 2>/dev/null | awk '/libmimalloc\.so/ {print $NF; exit}')"
	if [ -n "$mi" ]; then
		export LD_PRELOAD="$mi"
	else
		echo "warning: mimalloc not found; running with the system allocator" >&2
	fi
	;;
esac

# dtime takes one argv per extra rep.
extras=()
i=1
while [ "$i" -lt "$reps" ]; do
	extras+=("r$i")
	i=$((i + 1))
done

printf "%-9s %10s %10s %8s\n" corpus c_mbps roc_mbps gap
gaps=()
for f in "${files[@]}"; do
	best_c=0
	best_r=0
	r=0
	while [ "$r" -lt "$rounds" ]; do
		c="$("$build/dbench" bench "$streams/$f.deflate" "$corpus/$f" "$reps" | cut -f3)"
		roc_mbps="$("$build/dtime" "$streams/$f.deflate" "$corpus/$f" "${extras[@]}" | cut -f3)"
		best_c="$(python3 -c "print(max($best_c, $c))")"
		best_r="$(python3 -c "print(max($best_r, $roc_mbps))")"
		r=$((r + 1))
	done
	gap="$(python3 -c "print(f'{($best_c - $best_r) / $best_r * 100:+.1f}%')")"
	gaps+=("$(python3 -c "print(($best_c - $best_r) / $best_r * 100)")")
	printf "%-9s %10s %10s %8s\n" "$f" "$best_c" "$best_r" "$gap"
done

printf '%s\n' "${gaps[@]}" | python3 -c "
import statistics, sys
gaps = [float(line) for line in sys.stdin]
print(f'median gap: +{statistics.median(gaps):.1f}%')
"
