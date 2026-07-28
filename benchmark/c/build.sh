#!/usr/bin/env bash
# Build the C reference benchmark: libdeflate and zlib-ng as static libraries at
# -O2, plus the cbench driver that times them.
#
# The library sources are expected as sibling checkouts; override with
# LIBDEFLATE_SRC / ZLIBNG_SRC. Everything built lands in benchmark/c/.build,
# which is gitignored.
#
#     ./benchmark/c/build.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build="$here/.build"

libdeflate_src="${LIBDEFLATE_SRC:-$here/../../../libdeflate}"
zlibng_src="${ZLIBNG_SRC:-$here/../../../zlib-ng}"
cc="${CC:-cc}"
opt="${OPT_FLAGS:--O2}"

for src in "$libdeflate_src" "$zlibng_src"; do
	if [ ! -d "$src" ]; then
		echo "missing source checkout: $src" >&2
		echo "clone ebiggers/libdeflate and zlib-ng/zlib-ng next to this repo," >&2
		echo "or set LIBDEFLATE_SRC / ZLIBNG_SRC" >&2
		exit 1
	fi
done

libdeflate_src="$(cd "$libdeflate_src" && pwd)"
zlibng_src="$(cd "$zlibng_src" && pwd)"

generator=()
if command -v ninja >/dev/null 2>&1; then
	generator=(-G Ninja)
fi

echo "== libdeflate ($opt)"
cmake "${generator[@]}" -S "$libdeflate_src" -B "$build/libdeflate" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_C_FLAGS_RELEASE="$opt -DNDEBUG" \
	-DLIBDEFLATE_BUILD_STATIC_LIB=ON \
	-DLIBDEFLATE_BUILD_SHARED_LIB=OFF \
	-DLIBDEFLATE_BUILD_GZIP=OFF \
	-DLIBDEFLATE_BUILD_TESTS=OFF \
	-DLIBDEFLATE_INSTALL=OFF >/dev/null
cmake --build "$build/libdeflate" >/dev/null

# zlib-ng's own API (ZLIB_COMPAT=OFF) keeps its symbols out of any zlib the
# platform links, so there is no chance of silently benchmarking system zlib.
echo "== zlib-ng ($opt)"
cmake "${generator[@]}" -S "$zlibng_src" -B "$build/zlib-ng" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_C_FLAGS_RELEASE="$opt -DNDEBUG" \
	-DBUILD_SHARED_LIBS=OFF \
	-DZLIB_COMPAT=OFF \
	-DZLIB_ENABLE_TESTS=OFF \
	-DWITH_GTEST=OFF \
	-DWITH_GZFILEOP=OFF \
	-DBUILD_TESTING=OFF >/dev/null
cmake --build "$build/zlib-ng" >/dev/null

libdeflate_a="$(find "$build/libdeflate" -name 'libdeflate*.a' | head -1)"
zlibng_a="$(find "$build/zlib-ng" -name 'libz-ng*.a' -o -name 'libz-ng*.a' | head -1)"
[ -n "$libdeflate_a" ] || { echo "libdeflate static lib not found" >&2; exit 1; }
[ -n "$zlibng_a" ] || { echo "zlib-ng static lib not found" >&2; exit 1; }

echo "== cbench ($opt)"
"$cc" $opt -std=c11 -Wall -Wextra -o "$build/cbench" "$here/cbench.c" \
	-I "$libdeflate_src" \
	-I "$zlibng_src" -I "$build/zlib-ng" \
	"$libdeflate_a" "$zlibng_a"

echo "built $build/cbench"
