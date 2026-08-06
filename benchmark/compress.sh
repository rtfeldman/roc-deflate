#!/usr/bin/env bash
# Benchmark roc-deflate compression against libdeflate across the Silesia
# corpus and print the per-corpus gap table.
#
#     ./benchmark/compress.sh [level] [rounds] [reps]
#
# For each corpus file this runs `rounds` interleaved pairs of (libdeflate,
# roc), each reporting the fastest of `reps` compressions, and keeps each
# engine's best round, which cancels thermal drift between the two sides.
# Both sides compress at the same level into a caller-allocated buffer sized
# by libdeflate's own bound, verify the result decompresses back to the
# input, and run under mimalloc so allocator quality is not part of the
# comparison. Throughput is over uncompressed bytes.
#
# The compressed streams are also compared byte for byte, since this
# implementation is a port of libdeflate's and should agree with it exactly.
#
# Prerequisites:
#   - a libdeflate source checkout (sibling directory or LIBDEFLATE_SRC)
#   - the roc compiler on PATH (or ROC pointing at it)
#   - mimalloc installed (brew install mimalloc / libmimalloc-dev)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
level="${1:-6}"
rounds="${2:-3}"
reps="${3:-5}"
corpus="$here/.corpus"
build="$here/.build"
work="$here/.work"
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
mkdir -p "$build" "$work"

if [ ! -x "$build/cbench" ] || [ "$here/cbench.c" -nt "$build/cbench" ]; then
	echo "building cbench"
	"$cc" -O3 -I"$libdeflate_src" -o "$build/cbench" "$here/cbench.c" \
		"$libdeflate_src"/lib/*.c "$libdeflate_src"/lib/*/*.c
fi

# Rebuild when the harness or any package source is newer than the binary;
# checking only the harness silently benchmarks a stale compressor.
needs_build=0
if [ ! -x "$build/ctime" ]; then
	needs_build=1
else
	while IFS= read -r src; do
		if [ "$src" -nt "$build/ctime" ]; then
			needs_build=1
			break
		fi
	done < <(find "$here/ctime.roc" "$here/../package" -name '*.roc')
fi
if [ "$needs_build" -eq 1 ]; then
	echo "building ctime (roc --opt=speed)"
	(cd "$here" && "$roc" build --opt=speed ctime.roc)
	mv "$here/ctime" "$build/ctime"
fi

# Level and repetition count reach the Roc harness as bytes.
printf "$(printf '\\%03o' "$level")$(printf '\\%03o' "$reps")" > "$work/params.bin"

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

echo "compression level $level, best of $rounds rounds of min-of-$reps"
printf "%-9s %10s %10s %8s %12s %9s\n" corpus c_mbps roc_mbps gap size bytes
gaps=()
for f in "${files[@]}"; do
	best_c=0
	best_r=0
	c_size=0
	roc_size=0
	r=0
	while [ "$r" -lt "$rounds" ]; do
		c_line="$("$build/cbench" "$corpus/$f" "$level" "$reps" "$work/c_$f.deflate")"
		roc_line="$("$build/ctime" "$corpus/$f" "$work/params.bin" "$work/roc_$f.deflate")"
		c_mbps="$(echo "$c_line" | cut -f3)"
		roc_mbps="$(echo "$roc_line" | cut -f3)"
		c_size="$(echo "$c_line" | cut -f4)"
		roc_size="$(echo "$roc_line" | cut -f4)"
		best_c="$(python3 -c "print(max($best_c, $c_mbps))")"
		best_r="$(python3 -c "print(max($best_r, $roc_mbps))")"
		r=$((r + 1))
	done
	gap="$(python3 -c "print(f'{($best_c - $best_r) / $best_r * 100:+.1f}%')")"
	gaps+=("$(python3 -c "print(($best_c - $best_r) / $best_r * 100)")")
	if cmp -s "$work/c_$f.deflate" "$work/roc_$f.deflate"; then
		bytes="identical"
	else
		bytes="DIFFER"
	fi
	printf "%-9s %10s %10s %8s %12s %9s\n" "$f" "$best_c" "$best_r" "$gap" "$roc_size" "$bytes"
done

printf '%s\n' "${gaps[@]}" | python3 -c "
import statistics, sys
gaps = [float(line) for line in sys.stdin]
print(f'median gap: +{statistics.median(gaps):.1f}%')
"
