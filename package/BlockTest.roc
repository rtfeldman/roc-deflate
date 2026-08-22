import Block
import BitWriter
import DeflateTables
import Deflate

BlockTest := [].{
	## Encode every byte as a literal in a single block. Enough to exercise code
	## construction, the precode, the header, and symbol output together.
	literals_only : List(U8) -> List(U8)
	literals_only = |data| {
		n = List.len(data)
		var $litlen = List.repeat(0.U32, DeflateTables.num_litlen_syms)
		var $i = 0.U64
		while $i < n {
			lit = (List.get(data, $i) ?? 0).to_u64()
			$litlen = List.set($litlen, lit, (List.get($litlen, lit) ?? 0) + 1) ?? $litlen
			$i = $i + 1
		}
		eob = DeflateTables.end_of_block
		$litlen = List.set($litlen, eob, (List.get($litlen, eob) ?? 0) + 1) ?? $litlen

		freqs = { litlen: $litlen, offset: List.repeat(0.U32, DeflateTables.num_offset_syms) }
		seqs = [{ litrunlen: n, length: 0, offset: 0 }]
		w = Block.flush(BitWriter.new(n + 64), data, 0, n, seqs, freqs, True)
		BitWriter.finish(w)
	}

	## True when the encoded form decodes back to the original.
	round_trips : List(U8) -> Bool
	round_trips = |data|
		match Deflate.decompress(BlockTest.literals_only(data)) {
			Ok(back) => back == data
			Err(_) => False
		}
}

# Skewed data: dynamic codes should win and decode back.
expect BlockTest.round_trips(List.repeat(65.U8, 500))
expect BlockTest.round_trips([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
expect BlockTest.round_trips([])
expect BlockTest.round_trips([42])


# Literal/length codewords stay within the bound the encoder builds to, which
# is one below what the format permits. Only skewed frequencies reach it, so
# building to the format's limit instead goes unnoticed on ordinary data: the
# code that wants a 15-bit codeword takes a different shape, and the header
# describing it changes with it.
expect {
	# Fibonacci frequencies are the classic worst case for code depth -- each
	# symbol is as rare as the two before it combined, so the tree grows one
	# level per symbol until the bound stops it.
	var $litlen = List.repeat(0.U32, DeflateTables.num_litlen_syms)
	var $prev = 1.U32
	var $cur = 1.U32
	var $i = 0.U64
	while $i < 20 {
		$litlen = List.set($litlen, $i, $cur) ?? $litlen
		next = $prev + $cur
		$prev = $cur
		$cur = next
		$i = $i + 1
	}
	codes = Block.build_codes({ litlen: $litlen, offset: List.repeat(0.U32, DeflateTables.num_offset_syms) })
	var $longest = 0.U8
	var $k = 0.U64
	while $k < List.len(codes.litlen_lens) {
		$longest = $longest.max(List.get(codes.litlen_lens, $k) ?? 0)
		$k = $k + 1
	}
	$longest == 14
}
