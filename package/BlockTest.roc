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

