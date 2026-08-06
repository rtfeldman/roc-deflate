import Inflate
import CompressLazy

## DEFLATE (RFC 1951) compression and decompression in pure Roc, ported from
## libdeflate.
##
## `decompress` handles all three block types (stored, fixed Huffman, dynamic
## Huffman), so it reads streams produced by zlib, gzip, and ZIP tools.
## `compress` takes a level from 1 to 12 with the same meaning libdeflate gives
## it: the level selects the parser and how hard it searches.

## Errors that can occur when decompressing a DEFLATE stream.
DeflateError : [
	CorruptData,
	UnexpectedEnd,
]

Deflate := [].{

	## Compress bytes into a raw DEFLATE stream at the given level, 1 to 12.
	compress : List(U8), U64 -> Try(List(U8), [CompressBug])
	compress = |input, level|
		CompressLazy.compress(input, Deflate.params_for(level))

	## The search parameters libdeflate uses at each level.
	params_for : U64 -> CompressLazy.Params
	params_for = |level|
		if level <= 2 {
			{ max_search_depth: 6, nice_match_length: 10, lazy: 0 }
		} else if level == 3 {
			{ max_search_depth: 12, nice_match_length: 14, lazy: 0 }
		} else if level == 4 {
			{ max_search_depth: 16, nice_match_length: 30, lazy: 0 }
		} else if level == 5 {
			{ max_search_depth: 16, nice_match_length: 30, lazy: 1 }
		} else if level == 6 {
			{ max_search_depth: 35, nice_match_length: 65, lazy: 1 }
		} else if level == 7 {
			{ max_search_depth: 100, nice_match_length: 130, lazy: 1 }
		} else if level == 8 {
			{ max_search_depth: 300, nice_match_length: 258, lazy: 2 }
		} else {
			{ max_search_depth: 600, nice_match_length: 258, lazy: 2 }
		}

	## Decompress a raw DEFLATE stream.
	decompress : List(U8) -> Try(List(U8), DeflateError)
	decompress = |input|
		Inflate.decompress(input)

	## Decompress a raw DEFLATE stream, appending the output to `out`.
	##
	## Passing a list with enough spare capacity for the whole result means
	## the decompressor never reallocates mid-stream, and a returned list can
	## be emptied with its capacity kept and passed back in for the next
	## stream.
	decompress_into : List(U8), List(U8) -> Try(List(U8), DeflateError)
	decompress_into = |input, out|
		Inflate.decompress_into(input, out)
}
