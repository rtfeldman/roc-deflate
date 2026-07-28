#!/usr/bin/env bash
# Fetch and verify the Silesia corpus into benchmark/.corpus.
#
# Each file is downloaded as a .zip from a GitHub mirror and checked against a
# pinned sha256 before extraction, so a corrupt or swapped download fails loudly
# instead of quietly skewing benchmark numbers. Files already extracted are left
# alone, so reruns are free.
#
#     ./benchmark/corpus.sh [dest-dir]
set -euo pipefail

dest="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.corpus}"
mirror="https://raw.githubusercontent.com/MiloszKrajewski/SilesiaCorpus/master"

# Silesia file names paired with the sha256 of each .zip on the mirror.
files=(
	"dickens b0fcae3adb0334b5b3b73b1d1d06edfc5839c0bb7561255e0c490ab4682b46cc"
	"mozilla 3abdbd504073eda475f5d3d3ee7a69460db465065c329c73dd37ba3a082b8088"
	"mr bfb3e0735c7d275d22b3bc5d142e3f5431aacb7d3f7d329c6c9fe51dc1dfea2e"
	"nci 2982cb2a3fd9360735c74997b2e60f63b2f0a6a3941167cb0021f45dc0225a02"
	"ooffice 909880ebf9fc5702036b921935345450c43f9e352a6acb32100babafcf8f1d30"
	"osdb a1955a73be3ef1b1b14ab73c75e45e2c5c013c9bbbcaec277e58a94f732eeb1b"
	"reymont 691069ebbcf881d2e5177c0ff81711008209e6bd824e07a90e703451fb96d9c2"
	"samba 285c06096c0e24b71e28705f489932482b23d823b306dddc1cd8d0a8145121a1"
	"sao eeb657d7511dbdff833853157249506b61cde55a3223f2013e88cbbdb934c36f"
	"webster 6495af470253ced7d60e616a2b2f2f2841a88ea55bfd23cf0f1d46daa808f937"
	"x-ray f3d111158444a6cb42e7e60a46582755083c58f1657a55613f0edd64c5626ec6"
	"xml feeac237babe74e77ca1b7cd72d651ab0a722218ee3d2c07d519625b1a60fe50"
)

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	else
		shasum -a 256 "$1" | cut -d' ' -f1
	fi
}

mkdir -p "$dest"
for entry in "${files[@]}"; do
	name="${entry%% *}"
	want="${entry##* }"
	if [ -f "$dest/$name" ]; then
		continue
	fi
	echo "  $name: downloading"
	curl -fsSL --retry 3 -o "$dest/$name.zip" "$mirror/$name.zip"
	got="$(sha256_of "$dest/$name.zip")"
	if [ "$got" != "$want" ]; then
		echo "  $name: SHA256 MISMATCH" >&2
		echo "    expected $want" >&2
		echo "    got      $got" >&2
		rm -f "$dest/$name.zip"
		exit 1
	fi
	unzip -oq "$dest/$name.zip" -d "$dest"
	rm -f "$dest/$name.zip"
done

echo "corpus ready in $dest"
