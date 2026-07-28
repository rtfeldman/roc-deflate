import Huffman
import Precode
import DeflateTables
import BitWriter

## Emitting one DEFLATE block, ported from libdeflate's `deflate_flush_block`.
##
## A block can be sent three ways -- stored, with the fixed Huffman codes RFC
## 1951 defines, or with codes built for this block's own statistics. Which is
## cheapest depends on the data, so all three costs are computed in bits and the
## smallest wins. Ties go to stored, then static, then dynamic, matching
## libdeflate, because a tie broken the other way would change the output.
Block := [].{

	## What the parser produced for a block: a run of literals, then optionally a
	## match. `length` of 0 means literals only, which is how the final sequence
	## of a block is marked.
	Sequence : { litrunlen : U64, length : U64, offset : U64 }

	## Symbol frequencies gathered while parsing.
	Freqs : { litlen : List(U32), offset : List(U32) }

	## A built Huffman code pair.
	Codes : {
		litlen_lens : List(U8),
		litlen_codewords : List(U32),
		offset_lens : List(U8),
		offset_codewords : List(U32),
	}

	empty_freqs : Freqs
	empty_freqs = {
		litlen: List.repeat(0.U32, DeflateTables.num_litlen_syms),
		offset: List.repeat(0.U32, DeflateTables.num_offset_syms),
	}

	## Build the dynamic codes for these frequencies.
	build_codes : Freqs -> Codes
	build_codes = |freqs| {
		litlen = Huffman.build(freqs.litlen, 15)
		offset = Huffman.build(freqs.offset, 15)
		{
			litlen_lens: litlen.lengths,
			litlen_codewords: litlen.codewords,
			offset_lens: offset.lengths,
			offset_codewords: offset.codewords,
		}
	}

	## The fixed codes RFC 1951 defines, built once from their known lengths.
	static_codes : Codes
	static_codes = {
		litlen = Block.canonical_from_lens(DeflateTables.static_litlen_lens)
		offset = Block.canonical_from_lens(DeflateTables.static_offset_lens)
		{
			litlen_lens: DeflateTables.static_litlen_lens,
			litlen_codewords: litlen,
			offset_lens: DeflateTables.static_offset_lens,
			offset_codewords: offset,
		}
	}

	## Canonical codewords for a given set of lengths, bit-reversed as DEFLATE
	## requires. Used for the static codes, whose lengths are fixed rather than
	## derived from frequencies.
	canonical_from_lens : List(U8) -> List(U32)
	canonical_from_lens = |lens| {
		n = List.len(lens)
		var $counts = List.repeat(0.U32, 16)
		var $i = 0.U64
		while $i < n {
			l = (List.get(lens, $i) ?? 0).to_u64()
			if l != 0 {
				$counts = List.set($counts, l, (List.get($counts, l) ?? 0) + 1) ?? $counts
			} else {}
			$i = $i + 1
		}

		var $next = List.repeat(0.U32, 16)
		var $len = 2.U64
		while $len <= 15 {
			prev = List.get($next, $len - 1) ?? 0
			cnt = List.get($counts, $len - 1) ?? 0
			$next = List.set($next, $len, (prev + cnt).shl_wrap(1)) ?? $next
			$len = $len + 1
		}

		var $out = List.repeat(0.U32, n)
		var $s = 0.U64
		while $s < n {
			l = (List.get(lens, $s) ?? 0).to_u64()
			if l != 0 {
				code = List.get($next, l) ?? 0
				$next = List.set($next, l, code + 1) ?? $next
				$out = List.set($out, $s, Huffman.reverse_codeword(code, l)) ?? $out
			} else {}
			$s = $s + 1
		}
		$out
	}

	## Everything the header needs, computed once so its cost can be counted
	## before deciding whether to use it. Mirrors
	## `deflate_precompute_huffman_header`.
	Header : {
		num_litlen_syms : U64,
		num_offset_syms : U64,
		num_explicit_lens : U64,
		items : List(U32),
		precode_lens : List(U8),
		precode_codewords : List(U32),
	}

	precompute_header : Codes -> Header
	precompute_header = |codes| {
		num_litlen = Precode.num_litlen_syms(codes.litlen_lens)
		num_offset = Precode.num_offset_syms(codes.offset_lens)

		# The two length arrays are run-length encoded as one contiguous run, so
		# a run spanning the boundary is encoded as one. libdeflate achieves
		# this by moving the offset lengths up next to the trimmed litlen ones.
		joined = List.concat(
			List.sublist(codes.litlen_lens, { start: 0, len: num_litlen }),
			List.sublist(codes.offset_lens, { start: 0, len: num_offset }),
		)
		computed = Precode.compute_items(joined)
		precode = Huffman.build(computed.freqs, Precode.max_codeword_len)
		{
			num_litlen_syms: num_litlen,
			num_offset_syms: num_offset,
			num_explicit_lens: Precode.num_explicit_lens(precode.lengths),
			items: computed.items,
			precode_lens: precode.lengths,
			precode_codewords: precode.codewords,
		}
	}

	## Cost in bits of sending this block with the given codes, excluding the
	## 3-bit block header.
	symbol_cost : Freqs, Codes -> U64
	symbol_cost = |freqs, codes| {
		var $cost = 0.U64

		# Literals and the end-of-block symbol.
		var $sym = 0.U64
		while $sym <= DeflateTables.end_of_block {
			f = (List.get(freqs.litlen, $sym) ?? 0).to_u64()
			l = (List.get(codes.litlen_lens, $sym) ?? 0).to_u64()
			$cost = $cost + f * l
			$sym = $sym + 1
		}

		# Lengths, which carry extra bits beyond their symbol.
		var $i = 0.U64
		while $i < 29 {
			sym = DeflateTables.first_len_sym + $i
			f = (List.get(freqs.litlen, sym) ?? 0).to_u64()
			extra = (List.get(DeflateTables.extra_length_bits, $i) ?? 0).to_u64()
			l = (List.get(codes.litlen_lens, sym) ?? 0).to_u64()
			$cost = $cost + f * (extra + l)
			$i = $i + 1
		}

		# Offsets, likewise.
		var $j = 0.U64
		while $j < 30 {
			f = (List.get(freqs.offset, $j) ?? 0).to_u64()
			extra = (List.get(DeflateTables.extra_offset_bits, $j) ?? 0).to_u64()
			l = (List.get(codes.offset_lens, $j) ?? 0).to_u64()
			$cost = $cost + f * (extra + l)
			$j = $j + 1
		}

		$cost
	}

	## Cost in bits of the dynamic block's header: the three counts, the precode
	## lengths, and the run-length-encoded code lengths themselves.
	header_cost : Header -> U64
	header_cost = |header| {
		var $cost = 5 + 5 + 4 + (3 * header.num_explicit_lens)
		var $i = 0.U64
		while $i < List.len(header.items) {
			item = List.get(header.items, $i) ?? 0
			sym = item.bitwise_and(31).to_u64()
			extra = (List.get(DeflateTables.extra_precode_bits, sym) ?? 0).to_u64()
			l = (List.get(header.precode_lens, sym) ?? 0).to_u64()
			$cost = $cost + extra + l
			$i = $i + 1
		}
		$cost
	}

	## Write one block, choosing the cheapest of the three encodings.
	##
	## `data` is the whole input; the block covers `[start, start + length)`.
	## `seqs` is what the parser produced for it. Mirrors `deflate_flush_block`.
	flush : BitWriter.Writer, List(U8), U64, U64, List(Sequence), Freqs, Bool -> BitWriter.Writer
	flush = |w, data, start, length, seqs, freqs, is_final| {
		dynamic_codes = Block.build_codes(freqs)
		header = Block.precompute_header(dynamic_codes)

		# All three costs include the 3-bit block header.
		dynamic_cost = 3 + Block.header_cost(header) + Block.symbol_cost(freqs, dynamic_codes)
		static_cost = 3 + Block.symbol_cost(freqs, Block.static_codes)
		# A stored block pads to a byte boundary, then costs 32 bits of LEN/NLEN
		# per 65535-byte chunk plus the bytes themselves.
		# Bits of padding to reach a byte boundary after the 3-bit header. The
		# negation is deliberately wrapping: this is C's `-(bitcount + 3) & 7`,
		# where the wrap is what makes the mask compute the padding.
		pad = (0.U64).minus_wrap(w.bitcount.to_u64() + 3).bitwise_and(7)
		chunks = (length + 65534) // 65535
		extra_chunks = if chunks == 0 {
			0
		} else {
			chunks - 1
		}
		stored_cost = 3 + pad + 32 + (40 * extra_chunks) + (8 * length)

		best = dynamic_cost.min(static_cost.min(stored_cost))

		# Ties go to stored, then static, then dynamic, as libdeflate does.
		if best == stored_cost {
			Block.emit_stored(w, data, start, length, is_final)
		} else if best == static_cost {
			w2 = BitWriter.add(
				w,
				if is_final {
					1
				} else {
					0
				},
				1,
			)
			w3 = BitWriter.flush(BitWriter.add(w2, DeflateTables.blocktype_static, 2))
			Block.emit_symbols(w3, data, start, seqs, Block.static_codes)
		} else {
			w2 = BitWriter.add(
				w,
				if is_final {
					1
				} else {
					0
				},
				1,
			)
			w3 = BitWriter.add(w2, DeflateTables.blocktype_dynamic, 2)
			w4 = Block.emit_header(w3, header)
			Block.emit_symbols(w4, data, start, seqs, dynamic_codes)
		}
	}

	## Stored blocks carry raw bytes, so they align to a byte boundary first and
	## are split at 65535 bytes, the largest LEN a block header can express.
	emit_stored : BitWriter.Writer, List(U8), U64, U64, Bool -> BitWriter.Writer
	emit_stored = |w, data, start, length, is_final| {
		var $w = w
		var $pos = start
		var $left = length
		var $more = True
		while $more {
			chunk = $left.min(65535)
			final_chunk = is_final and chunk == $left
			$w = BitWriter.add(
				$w,
				if final_chunk {
					1
				} else {
					0
				},
				1,
			)
			$w = BitWriter.add($w, DeflateTables.blocktype_uncompressed, 2)
			$w = BitWriter.align($w)
			$w = BitWriter.append_bytes(
				$w,
				[
					chunk.to_u8_wrap(),
					chunk.shr_zf_wrap(8).to_u8_wrap(),
					chunk.bitwise_not().to_u8_wrap(),
					chunk.bitwise_not().shr_zf_wrap(8).to_u8_wrap(),
				],
			)
			$w = BitWriter.append_bytes($w, List.sublist(data, { start: $pos, len: chunk }))
			$pos = $pos + chunk
			$left = $left - chunk
			if $left == 0 {
				$more = False
			} else {}
		}
		$w
	}

	## The dynamic block header: three counts, the precode lengths in their
	## permuted order, then the run-length-encoded code lengths.
	emit_header : BitWriter.Writer, Header -> BitWriter.Writer
	emit_header = |w, header| {
		var $w = BitWriter.add(w, header.num_litlen_syms - 257, 5)
		$w = BitWriter.add($w, header.num_offset_syms - 1, 5)
		$w = BitWriter.add($w, header.num_explicit_lens - 4, 4)
		$w = BitWriter.flush($w)

		var $i = 0.U64
		while $i < header.num_explicit_lens {
			at = (List.get(Precode.lens_permutation, $i) ?? 0).to_u64()
			l = (List.get(header.precode_lens, at) ?? 0).to_u64()
			$w = BitWriter.flush(BitWriter.add($w, l, 3))
			$i = $i + 1
		}

		var $k = 0.U64
		while $k < List.len(header.items) {
			item = List.get(header.items, $k) ?? 0
			sym = item.bitwise_and(31).to_u64()
			cw = (List.get(header.precode_codewords, sym) ?? 0).to_u64()
			cl = List.get(header.precode_lens, sym) ?? 0
			$w = BitWriter.add($w, cw, cl)
			$w = BitWriter.add($w, item.shr_zf_wrap(5).to_u64(), List.get(DeflateTables.extra_precode_bits, sym) ?? 0)
			$w = BitWriter.flush($w)
			$k = $k + 1
		}
		$w
	}

	## The block body: each sequence is a run of literals then optionally a
	## match, and the end-of-block symbol closes it.
	emit_symbols : BitWriter.Writer, List(U8), U64, List(Sequence), Codes -> BitWriter.Writer
	emit_symbols = |w, data, start, seqs, codes| {
		var $w = w
		var $pos = start
		var $s = 0.U64
		while $s < List.len(seqs) {
			seq = List.get(seqs, $s) ?? { litrunlen: 0, length: 0, offset: 0 }

			var $n = 0.U64
			while $n < seq.litrunlen {
				lit = (List.get(data, $pos) ?? 0).to_u64()
				$w = BitWriter.add($w, (List.get(codes.litlen_codewords, lit) ?? 0).to_u64(), List.get(codes.litlen_lens, lit) ?? 0)
				$w = BitWriter.flush($w)
				$pos = $pos + 1
				$n = $n + 1
			}

			if seq.length != 0 {
				len_slot = DeflateTables.length_slot(seq.length)
				len_sym = DeflateTables.first_len_sym + len_slot
				len_base = (List.get(DeflateTables.length_slot_base, len_slot) ?? 0).to_u64()
				len_extra = List.get(DeflateTables.extra_length_bits, len_slot) ?? 0
				$w = BitWriter.add($w, (List.get(codes.litlen_codewords, len_sym) ?? 0).to_u64(), List.get(codes.litlen_lens, len_sym) ?? 0)
				$w = BitWriter.add($w, seq.length - len_base, len_extra)
				$w = BitWriter.flush($w)

				off_slot = DeflateTables.offset_slot(seq.offset)
				off_base = (List.get(DeflateTables.offset_slot_base, off_slot) ?? 0).to_u64()
				off_extra = List.get(DeflateTables.extra_offset_bits, off_slot) ?? 0
				$w = BitWriter.add($w, (List.get(codes.offset_codewords, off_slot) ?? 0).to_u64(), List.get(codes.offset_lens, off_slot) ?? 0)
				$w = BitWriter.add($w, seq.offset - off_base, off_extra)
				$w = BitWriter.flush($w)
				$pos = $pos + seq.length
			} else {}
			$s = $s + 1
		}

		eob = DeflateTables.end_of_block
		$w = BitWriter.add($w, (List.get(codes.litlen_codewords, eob) ?? 0).to_u64(), List.get(codes.litlen_lens, eob) ?? 0)
		BitWriter.flush($w)
	}
}
