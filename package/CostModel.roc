import Huffman
import Precode
import DeflateTables
import Block

## The cost model the near-optimal parser searches against, ported from
## libdeflate.
##
## Costs are in sixteenths of a bit (`bit_cost`), so the search can weigh
## fractional differences between encodings without floating point. A symbol
## the current code does not use still needs a price -- the parser may want to
## start using it -- so unused symbols are charged a fixed estimate rather than
## being treated as free or impossible.
CostModel := [].{
	## Costs are scaled by this so they can be compared at sub-bit precision.
	bit_cost : U64
	bit_cost = 16

	## What to charge for a symbol the current code does not use.
	literal_nostat_bits : U64
	literal_nostat_bits = 13

	length_nostat_bits : U64
	length_nostat_bits = 13

	offset_nostat_bits : U64
	offset_nostat_bits = 10

	min_match_len : U64
	min_match_len = 3

	max_match_len : U64
	max_match_len = 258

	## `literal` is indexed by byte, `length` by match length, `offset_slot` by
	## slot.
	Costs : { literal : List(U32), length : List(U32), offset_slot : List(U32) }

	## Derive costs from an actual set of codeword lengths, which is how every
	## pass after the first prices things: the previous pass's codes become the
	## next pass's cost model.
	from_codes : Block.Codes -> Costs
	from_codes = |codes| {
		var $literal = List.repeat(0.U32, 256)
		var $i = 0.U64
		while $i < 256 {
			l = (List.get(codes.litlen_lens, $i) ?? 0).to_u64()
			bits = if l != 0 { l } else { CostModel.literal_nostat_bits }
			$literal = List.set($literal, $i, (bits * CostModel.bit_cost).to_u32_wrap()) ?? $literal
			$i = $i + 1
		}

		var $length = List.repeat(0.U32, CostModel.max_match_len + 1)
		var $len = CostModel.min_match_len
		while $len <= CostModel.max_match_len {
			slot = DeflateTables.length_slot($len)
			sym = DeflateTables.first_len_sym + slot
			l = (List.get(codes.litlen_lens, sym) ?? 0).to_u64()
			base = if l != 0 { l } else { CostModel.length_nostat_bits }
			bits = base + (List.get(DeflateTables.extra_length_bits, slot) ?? 0).to_u64()
			$length = List.set($length, $len, (bits * CostModel.bit_cost).to_u32_wrap()) ?? $length
			$len = $len + 1
		}

		var $offset = List.repeat(0.U32, 30)
		var $s = 0.U64
		while $s < 30 {
			l = (List.get(codes.offset_lens, $s) ?? 0).to_u64()
			base = if l != 0 { l } else { CostModel.offset_nostat_bits }
			bits = base + (List.get(DeflateTables.extra_offset_bits, $s) ?? 0).to_u64()
			$offset = List.set($offset, $s, (bits * CostModel.bit_cost).to_u32_wrap()) ?? $offset
			$s = $s + 1
		}

		{ literal: $literal, length: $length, offset_slot: $offset }
	}

	## Every byte a literal. Used to price the all-literals encoding, which
	## sometimes beats anything the parser can find.
	all_literals_freqs : List(U8), U64, U64 -> Block.Freqs
	all_literals_freqs = |data, start, length| {
		var $litlen = List.repeat(0.U32, DeflateTables.num_litlen_syms)
		var $i = 0.U64
		while $i < length {
			lit = (List.get(data, start + $i) ?? 0).to_u64()
			$litlen = List.set($litlen, lit, (List.get($litlen, lit) ?? 0) + 1) ?? $litlen
			$i = $i + 1
		}
		eob = DeflateTables.end_of_block
		$litlen = List.set($litlen, eob, (List.get($litlen, eob) ?? 0) + 1) ?? $litlen
		{ litlen: $litlen, offset: List.repeat(0.U32, DeflateTables.num_offset_syms) }
	}

	## What this block would actually cost to send, in whole bits, header
	## included. This is what the passes compare -- unlike the search costs,
	## which are estimates in sixteenths.
	true_cost : Block.Freqs, Block.Codes -> U64
	true_cost = |freqs, codes| {
		header = Block.precompute_header(codes)

		var $cost = 5 + 5 + 4 + (3 * header.num_explicit_lens)

		# The precode's own cost, recovered from the item stream.
		var $k = 0.U64
		while $k < List.len(header.items) {
			item = List.get(header.items, $k) ?? 0
			sym = item.bitwise_and(31).to_u64()
			$cost = $cost
				+ (List.get(header.precode_lens, sym) ?? 0).to_u64()
				+ (List.get(DeflateTables.extra_precode_bits, sym) ?? 0).to_u64()
			$k = $k + 1
		}

		# Literals and the end-of-block symbol.
		var $sym = 0.U64
		while $sym < DeflateTables.first_len_sym {
			f = (List.get(freqs.litlen, $sym) ?? 0).to_u64()
			l = (List.get(codes.litlen_lens, $sym) ?? 0).to_u64()
			$cost = $cost + f * l
			$sym = $sym + 1
		}

		var $i = 0.U64
		while $i < 29 {
			s = DeflateTables.first_len_sym + $i
			f = (List.get(freqs.litlen, s) ?? 0).to_u64()
			l = (List.get(codes.litlen_lens, s) ?? 0).to_u64()
			e = (List.get(DeflateTables.extra_length_bits, $i) ?? 0).to_u64()
			$cost = $cost + f * (l + e)
			$i = $i + 1
		}

		var $j = 0.U64
		while $j < 30 {
			f = (List.get(freqs.offset, $j) ?? 0).to_u64()
			l = (List.get(codes.offset_lens, $j) ?? 0).to_u64()
			e = (List.get(DeflateTables.extra_offset_bits, $j) ?? 0).to_u64()
			$cost = $cost + f * (l + e)
			$j = $j + 1
		}

		$cost
	}
}
