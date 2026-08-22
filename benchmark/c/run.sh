#!/usr/bin/env bash
# Build (if needed) and run the C reference benchmark on a corpus.
#
# By default this runs the three levels paired with roc-deflate's Fastest,
# Balanced, and Smallest; feed the --tsv output to benchmark/compare.sh
# alongside roc-deflate's to get the verdict.
#
#     ./benchmark/c/run.sh                # Silesia, all 12 files
#     ./benchmark/c/run.sh --quick        # Canterbury only, short budget
#     ./benchmark/c/run.sh --tsv > c.tsv
#
# Any other arguments are passed through to cbench, so a focused run is e.g.
#
#     ./benchmark/c/run.sh --engines=libdeflate --ld-levels=6
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
cbench="$here/.build/cbench"

quick=false
passthrough=()
for arg in "$@"; do
	case "$arg" in
		--quick) quick=true ;;
		--tsv) passthrough+=(--format=tsv) ;;
		*) passthrough+=("$arg") ;;
	esac
done

if [ ! -x "$cbench" ] || [ "$here/cbench.c" -nt "$cbench" ]; then
	"$here/build.sh" >&2
fi

if $quick; then
	exec "$cbench" --min-ms=200 --min-iters=3 "${passthrough[@]}" \
		"$repo/tests/corpus/canterbury.bin"
fi

"$repo/benchmark/corpus.sh" >&2
corpus="$repo/benchmark/.corpus"
exec "$cbench" "${passthrough[@]}" \
	"$corpus/dickens" "$corpus/mozilla" "$corpus/mr" "$corpus/nci" \
	"$corpus/ooffice" "$corpus/osdb" "$corpus/reymont" "$corpus/samba" \
	"$corpus/sao" "$corpus/webster" "$corpus/x-ray" "$corpus/xml"
