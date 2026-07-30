import CompressFastest
import Inflate
import CompressBalanced
import CompressSmallest

## DEFLATE (RFC 1951) compression and decompression in pure Roc.
##
## `decompress` handles all three block types (stored, fixed Huffman, dynamic
## Huffman), so it can read streams produced by zlib, gzip, and ZIP tools.
## `compress` picks its strategy from the level it is given: `Fastest` runs a
## hash-table matchfinder in a single greedy pass, `Balanced` walks hash chains
## and defers each match by a byte to see whether a better one starts there, and
## `Smallest` searches a binary tree and finds the cheapest path through the
## matches under a cost model it refines over several passes. All three produce
## streams any inflate implementation can read.

## Errors that can occur when decompressing a DEFLATE stream.
DeflateError : [
	CorruptData,
	UnexpectedEnd,
]

## How hard [Deflate.compress] searches for LZ77 matches, trading speed for
## size: `Fastest` gives up quickly, `Smallest` searches far deeper, and
## `Balanced` sits in between (roughly zlib's default effort).
Level : [Fastest, Balanced, Smallest]

Deflate := [].{

	## Compress bytes into a raw DEFLATE stream.
	compress : List(U8), Level -> List(U8)
	compress = |input, level| match level {
		Fastest => CompressFastest.compress(input)
		Smallest => CompressSmallest.compress(input)
		Balanced => CompressBalanced.compress(input)
	}

	## Decompress a raw DEFLATE stream.
	decompress : List(U8) -> Try(List(U8), DeflateError)
	decompress = |input|
		Inflate.decompress(input)
}
