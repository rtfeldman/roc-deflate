import DeflateTables
import HuffmanEncode

## Choosing a block's type and writing it out, ported from libdeflate's
## `deflate_flush_block` and the header precomputation it calls.
##
## The bit writer keeps its state in loop-local values rather than a record
## that helper calls thread back and forth, and the bit operations are written
## out at each site instead of being factored into functions. That is what
## libdeflate's ADD_BITS/FLUSH_BITS macros buy: on a 64-bit bit buffer, four
## literals or one whole match fit between flushes, so a literal run costs one
## store per four symbols rather than a call per symbol.
BlockOut := [].{

	## Codeword tables for one block's two Huffman codes.
	Codes : {
		litlen_lens : List(U8),
		litlen_codewords : List(U32),
		offset_lens : List(U8),
		offset_codewords : List(U32),
	}

	## One run of literals followed by a match, or by the end of the block.
	##
	## `litrunlen_and_length` packs the literal count in its low 23 bits and
	## the following match's length above them; a length of zero marks the last
	## sequence in a block. The literals themselves are not stored, since they
	## are read back from the uncompressed input.
	Sequence : {
		litrunlen_and_length : U32,
		offset : U16,
		offset_slot : U16,
	}

	seq_length_shift : U8
	seq_length_shift = 23

	seq_litrunlen_mask : U32
	seq_litrunlen_mask = 0x7FFFFF

	## The bit buffer holds one bit less than a machine word so that shifting
	## by `bitcount & ~7` is always defined.
	bitbuf_nbits : U64
	bitbuf_nbits = 63

	max_litlen_codeword_len : U64
	max_litlen_codeword_len = 14

	max_offset_codeword_len : U64
	max_offset_codeword_len = 15

	max_pre_codeword_len : U64
	max_pre_codeword_len = 7

	PrecodeInfo : {
		freqs : List(U32),
		lens : List(U8),
		codewords : List(U32),
		items : List(U32),
		num_items : U64,
		num_litlen_syms : U64,
		num_offset_syms : U64,
		num_explicit_lens : U64,
	}

	## Run-length encode the litlen and offset codeword lengths into precode
	## items, counting how often each precode symbol is used.
	##
	## Each item carries its precode symbol in the low five bits and any extra
	## bits above them.
	compute_precode_items : List(U8), U64, List(U32), List(U32) -> Try({ freqs : List(U32), items : List(U32), num_items : U64 }, [CompressBug])
	compute_precode_items = |lens, num_lens, freqs0, items0| {
		var $freqs = freqs0
		var $items = items0
		var $num_items = 0.U64
		var $run_start = 0.U64

		while $run_start != num_lens {
			# Extend the run of equal lengths that starts here.
			len = List.get(lens, $run_start) ?? 0
			var $run_end = $run_start + 1
			while $run_end != num_lens and len == (List.get(lens, $run_end) ?? 0) {
				$run_end = $run_end + 1
			}

			if len == 0 {
				# Symbol 18 repeats 11 to 138 zeroes, symbol 17 repeats 3 to 10.
				while ($run_end - $run_start) >= 11 {
					extra = (($run_end - $run_start) - 11).min(0x7F)
					$freqs = match List.set($freqs, 18, (List.get($freqs, 18) ?? 0) + 1) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$items = match List.set($items, $num_items, 18.U32.bitwise_or(extra.to_u32_wrap().shl_wrap(5))) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$num_items = $num_items + 1
					$run_start = $run_start + 11 + extra
				}
				if ($run_end - $run_start) >= 3 {
					extra = (($run_end - $run_start) - 3).min(0x7)
					$freqs = match List.set($freqs, 17, (List.get($freqs, 17) ?? 0) + 1) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$items = match List.set($items, $num_items, 17.U32.bitwise_or(extra.to_u32_wrap().shl_wrap(5))) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$num_items = $num_items + 1
					$run_start = $run_start + 3 + extra
				} else {
				}
			} else {
				# Symbol 16 repeats the previous length 3 to 6 more times, so
				# the length itself must be written once first.
				if ($run_end - $run_start) >= 4 {
					$freqs = match List.set($freqs, len.to_u64(), (List.get($freqs, len.to_u64()) ?? 0) + 1) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$items = match List.set($items, $num_items, len.to_u32()) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$num_items = $num_items + 1
					$run_start = $run_start + 1
					var $repeating = True
					while $repeating {
						extra = (($run_end - $run_start) - 3).min(0x3)
						$freqs = match List.set($freqs, 16, (List.get($freqs, 16) ?? 0) + 1) {
							Ok(next) => next
							Err(_) => return Err(CompressBug)
						}
						$items = match List.set($items, $num_items, 16.U32.bitwise_or(extra.to_u32_wrap().shl_wrap(5))) {
							Ok(next) => next
							Err(_) => return Err(CompressBug)
						}
						$num_items = $num_items + 1
						$run_start = $run_start + 3 + extra
						if ($run_end - $run_start) < 3 {
							$repeating = False
						} else {
						}
					}
				} else {
				}
			}

			# Whatever the run-length symbols could not cover goes out plainly.
			while $run_start != $run_end {
				$freqs = match List.set($freqs, len.to_u64(), (List.get($freqs, len.to_u64()) ?? 0) + 1) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$items = match List.set($items, $num_items, len.to_u32()) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$num_items = $num_items + 1
				$run_start = $run_start + 1
			}
		}
		Ok({ freqs: $freqs, items: $items, num_items: $num_items })
	}

	## Work out everything the dynamic Huffman header needs: how many litlen
	## and offset lengths must be sent, the precode items that encode them, and
	## the precode itself.
	precompute_huffman_header : Codes -> Try(PrecodeInfo, [CompressBug])
	precompute_huffman_header = |codes| {
		# Trailing unused symbols need not be sent.
		var $num_litlen_syms = DeflateTables.num_litlen_syms
		var $scanning = True
		while $scanning and $num_litlen_syms > 257 {
			if (List.get(codes.litlen_lens, $num_litlen_syms - 1) ?? 0) != 0 {
				$scanning = False
			} else {
				$num_litlen_syms = $num_litlen_syms - 1
			}
		}
		var $num_offset_syms = DeflateTables.num_offset_syms
		$scanning = True
		while $scanning and $num_offset_syms > 1 {
			if (List.get(codes.offset_lens, $num_offset_syms - 1) ?? 0) != 0 {
				$scanning = False
			} else {
				$num_offset_syms = $num_offset_syms - 1
			}
		}

		# The precode encodes both codes' lengths as one contiguous run.
		num_lens = $num_litlen_syms + $num_offset_syms
		var $lens = List.with_capacity(num_lens)
		var $i = 0.U64
		while $i < $num_litlen_syms {
			$lens = List.append($lens, List.get(codes.litlen_lens, $i) ?? 0)
			$i = $i + 1
		}
		$i = 0
		while $i < $num_offset_syms {
			$lens = List.append($lens, List.get(codes.offset_lens, $i) ?? 0)
			$i = $i + 1
		}

		computed = BlockOut.compute_precode_items(
			$lens,
			num_lens,
			List.repeat(0.U32, DeflateTables.num_precode_syms),
			List.repeat(0.U32, DeflateTables.num_litlen_syms + DeflateTables.num_offset_syms),
		)?

		precode = HuffmanEncode.make_code(
			DeflateTables.num_precode_syms,
			BlockOut.max_pre_codeword_len,
			computed.freqs,
			List.repeat(0.U8, DeflateTables.num_precode_syms),
			List.repeat(0.U32, DeflateTables.num_precode_syms),
		)?

		# Trailing zero precode lengths need not be sent either.
		var $num_explicit_lens = DeflateTables.num_precode_syms
		$scanning = True
		while $scanning and $num_explicit_lens > 4 {
			perm = (List.get(DeflateTables.precode_lens_permutation, $num_explicit_lens - 1) ?? 0).to_u64()
			if (List.get(precode.lens, perm) ?? 0) != 0 {
				$scanning = False
			} else {
				$num_explicit_lens = $num_explicit_lens - 1
			}
		}

		Ok({
			freqs: computed.freqs,
			lens: precode.lens,
			codewords: precode.codewords,
			items: computed.items,
			num_items: computed.num_items,
			num_litlen_syms: $num_litlen_syms,
			num_offset_syms: $num_offset_syms,
			num_explicit_lens: $num_explicit_lens,
		})
	}

	FullLens : { codewords : List(U32), lens : List(U8) }

	## Concatenate each match length's litlen codeword with its extra bits, so
	## writing a match is one table lookup rather than a slot lookup plus two
	## assembles.
	compute_full_len_codewords : Codes -> Try(FullLens, [CompressBug])
	compute_full_len_codewords = |codes| {
		var $codewords = List.repeat(0.U32, DeflateTables.max_match_len + 1)
		var $lens = List.repeat(0.U8, DeflateTables.max_match_len + 1)
		var $len = DeflateTables.min_match_len
		while $len <= DeflateTables.max_match_len {
			slot = DeflateTables.length_slot($len)
			litlen_sym = DeflateTables.first_len_sym + slot
			extra_bits = $len.to_u32_wrap() - (List.get(DeflateTables.length_slot_base, slot) ?? 0)
			sym_len = (List.get(codes.litlen_lens, litlen_sym) ?? 0)
			$codewords = match List.set($codewords, $len,
				(List.get(codes.litlen_codewords, litlen_sym) ?? 0)
					.bitwise_or(extra_bits.shl_wrap(sym_len))) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$lens = match List.set($lens, $len,
				sym_len + (List.get(DeflateTables.extra_length_bits, slot) ?? 0)) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$len = $len + 1
		}
		Ok({ codewords: $codewords, lens: $lens })
	}
	OutState : { out : List(U8), bitbuf : U64, bitcount : U64 }

	FlushArgs : {
		out : List(U8),
		bitbuf : U64,
		bitcount : U64,
		input : List(U8),
		block_begin : U64,
		block_length : U64,
		seqs : List(Sequence),
		freqs_litlen : List(U32),
		freqs_offset : List(U32),
		codes : Codes,
		static_codes : Codes,
		is_final : U64,
	}

	## Choose the cheapest of the three block types and write the block.
	##
	## The cost of each type is computed in bits before anything is written,
	## which is what lets the writer commit to a type and then emit the whole
	## block without re-checking anything. Ties prefer uncompressed, then
	## static, then dynamic, as libdeflate does.
	flush_block : FlushArgs -> Try(OutState, [CompressBug])
	flush_block = |args| {
		codes = args.codes
		precode = BlockOut.precompute_huffman_header(codes)?

		# Cost of the dynamic Huffman header: the three length counts, the
		# explicit precode lengths, then the precode-encoded lengths.
		var $dynamic_cost = 3.U64 + 5 + 5 + 4 + 3 * precode.num_explicit_lens
		var $sym = 0.U64
		while $sym < DeflateTables.num_precode_syms {
			extra = (List.get(DeflateTables.extra_precode_bits, $sym) ?? 0).to_u64()
			$dynamic_cost = $dynamic_cost
				+ (List.get(precode.freqs, $sym) ?? 0).to_u64()
					* (extra + (List.get(precode.lens, $sym) ?? 0).to_u64())
			$sym = $sym + 1
		}

		# Literals: the static code spends 8 bits below 144 and 9 above.
		var $static_cost = 3.U64
		$sym = 0
		while $sym < 144 {
			freq = (List.get(args.freqs_litlen, $sym) ?? 0).to_u64()
			$dynamic_cost = $dynamic_cost + freq * (List.get(codes.litlen_lens, $sym) ?? 0).to_u64()
			$static_cost = $static_cost + freq * 8
			$sym = $sym + 1
		}
		while $sym < 256 {
			freq = (List.get(args.freqs_litlen, $sym) ?? 0).to_u64()
			$dynamic_cost = $dynamic_cost + freq * (List.get(codes.litlen_lens, $sym) ?? 0).to_u64()
			$static_cost = $static_cost + freq * 9
			$sym = $sym + 1
		}

		# End-of-block.
		$dynamic_cost = $dynamic_cost + (List.get(codes.litlen_lens, DeflateTables.end_of_block) ?? 0).to_u64()
		$static_cost = $static_cost + 7

		# Lengths.
		$sym = 0
		while $sym < 29 {
			extra = (List.get(DeflateTables.extra_length_bits, $sym) ?? 0).to_u64()
			litlen_sym = DeflateTables.first_len_sym + $sym
			freq = (List.get(args.freqs_litlen, litlen_sym) ?? 0).to_u64()
			$dynamic_cost = $dynamic_cost + freq * (extra + (List.get(codes.litlen_lens, litlen_sym) ?? 0).to_u64())
			$static_cost = $static_cost + freq * (extra + (List.get(args.static_codes.litlen_lens, litlen_sym) ?? 0).to_u64())
			$sym = $sym + 1
		}

		# Offsets; the static offset code is five bits flat.
		$sym = 0
		while $sym < 30 {
			extra = (List.get(DeflateTables.extra_offset_bits, $sym) ?? 0).to_u64()
			freq = (List.get(args.freqs_offset, $sym) ?? 0).to_u64()
			$dynamic_cost = $dynamic_cost + freq * (extra + (List.get(codes.offset_lens, $sym) ?? 0).to_u64())
			$static_cost = $static_cost + freq * (extra + 5)
			$sym = $sym + 1
		}

		# An uncompressed block pads to a byte, then spends four bytes of
		# header per 65535 bytes of payload.
		block_length = args.block_length
		num_uncompressed_blocks = (block_length + 65534) // 65535
		uncompressed_cost = 3
			+ 0.U64.minus_wrap(args.bitcount + 3).bitwise_and(7)
			+ 32
			+ 40 * (num_uncompressed_blocks - 1)
			+ 8 * block_length

		best_cost = $dynamic_cost.min($static_cost).min(uncompressed_cost)

		var $out = args.out
		var $bitbuf = args.bitbuf
		var $bitcount = args.bitcount
		var $in_next = args.block_begin
		in_end = args.block_begin + block_length

		if best_cost == uncompressed_cost {
			# Uncompressed. DEFLATE caps a stored block at 65535 bytes, so a
			# longer flush becomes several blocks.
			var $storing = True
			while $storing {
				remaining = in_end - $in_next
				len = remaining.min(65535)
				bfinal = if remaining <= 65535 { args.is_final } else { 0 }

				# The header is three bits, then the stream aligns to a byte.
				$out = List.append($out, bfinal.shl_wrap($bitcount.to_u8_wrap()).bitwise_or($bitbuf).to_u8_wrap())
				if $bitcount > 5 {
					$out = List.append($out, 0)
				} else {
				}
				$bitbuf = 0
				$bitcount = 0

				$out = match len.append_le_bytes_to($out, 2) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$out = match len.bitwise_not().append_le_bytes_to($out, 2) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$out = List.append_sublist($out, args.input, { start: $in_next, len })
				$in_next = $in_next + len
				if $in_next == in_end {
					$storing = False
				} else {
				}
			}
			Ok({ out: $out, bitbuf: $bitbuf, bitcount: $bitcount })
		} else {
			use_static = best_cost == $static_cost
			write_codes = if use_static { args.static_codes } else { codes }

			if use_static {
				$bitbuf = $bitbuf.bitwise_or(args.is_final.shl_wrap($bitcount.to_u8_wrap()))
				$bitcount = $bitcount + 1
				$bitbuf = $bitbuf.bitwise_or(DeflateTables.blocktype_static.shl_wrap($bitcount.to_u8_wrap()))
				$bitcount = $bitcount + 2
				n = $bitcount.shr_zf_wrap(3)
				$out = match $bitbuf.append_le_bytes_to($out, n.to_u8_wrap()) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$bitbuf = $bitbuf.shr_zf_wrap(n.shl_wrap(3).to_u8_wrap())
				$bitcount = $bitcount.bitwise_and(7)
			} else {
				$bitbuf = $bitbuf.bitwise_or(args.is_final.shl_wrap($bitcount.to_u8_wrap()))
				$bitcount = $bitcount + 1
				$bitbuf = $bitbuf.bitwise_or(DeflateTables.blocktype_dynamic.shl_wrap($bitcount.to_u8_wrap()))
				$bitcount = $bitcount + 2
				$bitbuf = $bitbuf.bitwise_or((precode.num_litlen_syms - 257).shl_wrap($bitcount.to_u8_wrap()))
				$bitcount = $bitcount + 5
				$bitbuf = $bitbuf.bitwise_or((precode.num_offset_syms - 1).shl_wrap($bitcount.to_u8_wrap()))
				$bitcount = $bitcount + 5
				$bitbuf = $bitbuf.bitwise_or((precode.num_explicit_lens - 4).shl_wrap($bitcount.to_u8_wrap()))
				$bitcount = $bitcount + 4

				# A 64-bit buffer is one bit too small to hold all 19 precode
				# lengths at once, so the first one goes out with the fields
				# above and the rest follow in a single run.
				perm0 = (List.get(DeflateTables.precode_lens_permutation, 0) ?? 0).to_u64()
				$bitbuf = $bitbuf.bitwise_or((List.get(precode.lens, perm0) ?? 0).to_u64().shl_wrap($bitcount.to_u8_wrap()))
				$bitcount = $bitcount + 3
				n0 = $bitcount.shr_zf_wrap(3)
				$out = match $bitbuf.append_le_bytes_to($out, n0.to_u8_wrap()) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$bitbuf = $bitbuf.shr_zf_wrap(n0.shl_wrap(3).to_u8_wrap())
				$bitcount = $bitcount.bitwise_and(7)

				var $i = 1.U64
				while $i < precode.num_explicit_lens {
					perm = (List.get(DeflateTables.precode_lens_permutation, $i) ?? 0).to_u64()
					$bitbuf = $bitbuf.bitwise_or((List.get(precode.lens, perm) ?? 0).to_u64().shl_wrap($bitcount.to_u8_wrap()))
					$bitcount = $bitcount + 3
					$i = $i + 1
				}
				n1 = $bitcount.shr_zf_wrap(3)
				$out = match $bitbuf.append_le_bytes_to($out, n1.to_u8_wrap()) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$bitbuf = $bitbuf.shr_zf_wrap(n1.shl_wrap(3).to_u8_wrap())
				$bitcount = $bitcount.bitwise_and(7)

				# Then the litlen and offset lengths, precode-encoded.
				$i = 0
				while $i < precode.num_items {
					item = List.get(precode.items, $i) ?? 0
					precode_sym = item.bitwise_and(0x1F).to_u64()
					$bitbuf = $bitbuf.bitwise_or((List.get(precode.codewords, precode_sym) ?? 0).to_u64().shl_wrap($bitcount.to_u8_wrap()))
					$bitcount = $bitcount + (List.get(precode.lens, precode_sym) ?? 0).to_u64()
					$bitbuf = $bitbuf.bitwise_or(item.shr_zf_wrap(5).to_u64().shl_wrap($bitcount.to_u8_wrap()))
					$bitcount = $bitcount + (List.get(DeflateTables.extra_precode_bits, precode_sym) ?? 0).to_u64()
					n = $bitcount.shr_zf_wrap(3)
					$out = match $bitbuf.append_le_bytes_to($out, n.to_u8_wrap()) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$bitbuf = $bitbuf.shr_zf_wrap(n.shl_wrap(3).to_u8_wrap())
					$bitcount = $bitcount.bitwise_and(7)
					$i = $i + 1
				}
			}

			full = BlockOut.compute_full_len_codewords(write_codes)?
			litlen_codewords = write_codes.litlen_codewords
			litlen_lens = write_codes.litlen_lens
			offset_codewords = write_codes.offset_codewords
			offset_lens = write_codes.offset_lens
			full_codewords = full.codewords
			full_lens = full.lens
			input = args.input

			var $seq_idx = 0.U64
			var $writing = True
			while $writing {
				seq = List.get(args.seqs, $seq_idx) ?? { litrunlen_and_length: 0, offset: 0, offset_slot: 0 }
				var $litrunlen = seq.litrunlen_and_length.bitwise_and(BlockOut.seq_litrunlen_mask).to_u64()
				length = seq.litrunlen_and_length.shr_zf_wrap(BlockOut.seq_length_shift).to_u64()

				# Four literals fit between flushes: 7 leftover bits plus four
				# 14-bit codewords stay inside the 63-bit buffer.
				while $litrunlen >= 4 {
					lit0 = (List.get(input, $in_next) ?? 0).to_u64()
					$bitbuf = $bitbuf.bitwise_or((List.get(litlen_codewords, lit0) ?? 0).to_u64().shl_wrap($bitcount.to_u8_wrap()))
					$bitcount = $bitcount + (List.get(litlen_lens, lit0) ?? 0).to_u64()
					lit1 = (List.get(input, $in_next + 1) ?? 0).to_u64()
					$bitbuf = $bitbuf.bitwise_or((List.get(litlen_codewords, lit1) ?? 0).to_u64().shl_wrap($bitcount.to_u8_wrap()))
					$bitcount = $bitcount + (List.get(litlen_lens, lit1) ?? 0).to_u64()
					lit2 = (List.get(input, $in_next + 2) ?? 0).to_u64()
					$bitbuf = $bitbuf.bitwise_or((List.get(litlen_codewords, lit2) ?? 0).to_u64().shl_wrap($bitcount.to_u8_wrap()))
					$bitcount = $bitcount + (List.get(litlen_lens, lit2) ?? 0).to_u64()
					lit3 = (List.get(input, $in_next + 3) ?? 0).to_u64()
					$bitbuf = $bitbuf.bitwise_or((List.get(litlen_codewords, lit3) ?? 0).to_u64().shl_wrap($bitcount.to_u8_wrap()))
					$bitcount = $bitcount + (List.get(litlen_lens, lit3) ?? 0).to_u64()
					$in_next = $in_next + 4
					n = $bitcount.shr_zf_wrap(3)
					$out = match $bitbuf.append_le_bytes_to($out, n.to_u8_wrap()) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$bitbuf = $bitbuf.shr_zf_wrap(n.shl_wrap(3).to_u8_wrap())
					$bitcount = $bitcount.bitwise_and(7)
					$litrunlen = $litrunlen - 4
				}
				if $litrunlen != 0 {
					lit0 = (List.get(input, $in_next) ?? 0).to_u64()
					$bitbuf = $bitbuf.bitwise_or((List.get(litlen_codewords, lit0) ?? 0).to_u64().shl_wrap($bitcount.to_u8_wrap()))
					$bitcount = $bitcount + (List.get(litlen_lens, lit0) ?? 0).to_u64()
					$in_next = $in_next + 1
					if $litrunlen >= 2 {
						lit1 = (List.get(input, $in_next) ?? 0).to_u64()
						$bitbuf = $bitbuf.bitwise_or((List.get(litlen_codewords, lit1) ?? 0).to_u64().shl_wrap($bitcount.to_u8_wrap()))
						$bitcount = $bitcount + (List.get(litlen_lens, lit1) ?? 0).to_u64()
						$in_next = $in_next + 1
						if $litrunlen >= 3 {
							lit2 = (List.get(input, $in_next) ?? 0).to_u64()
							$bitbuf = $bitbuf.bitwise_or((List.get(litlen_codewords, lit2) ?? 0).to_u64().shl_wrap($bitcount.to_u8_wrap()))
							$bitcount = $bitcount + (List.get(litlen_lens, lit2) ?? 0).to_u64()
							$in_next = $in_next + 1
						} else {
						}
					} else {
					}
					n = $bitcount.shr_zf_wrap(3)
					$out = match $bitbuf.append_le_bytes_to($out, n.to_u8_wrap()) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$bitbuf = $bitbuf.shr_zf_wrap(n.shl_wrap(3).to_u8_wrap())
					$bitcount = $bitcount.bitwise_and(7)
				} else {
				}

				if length == 0 {
					$writing = False
				} else {
					# A whole match fits between flushes as well: the length
					# codeword with its extra bits, the offset codeword, and the
					# extra offset bits come to at most 47 bits.
					offset = seq.offset.to_u64()
					offset_slot = seq.offset_slot.to_u64()
					$bitbuf = $bitbuf.bitwise_or((List.get(full_codewords, length) ?? 0).to_u64().shl_wrap($bitcount.to_u8_wrap()))
					$bitcount = $bitcount + (List.get(full_lens, length) ?? 0).to_u64()
					$bitbuf = $bitbuf.bitwise_or((List.get(offset_codewords, offset_slot) ?? 0).to_u64().shl_wrap($bitcount.to_u8_wrap()))
					$bitcount = $bitcount + (List.get(offset_lens, offset_slot) ?? 0).to_u64()
					$bitbuf = $bitbuf.bitwise_or((offset - (List.get(DeflateTables.offset_slot_base, offset_slot) ?? 0).to_u64()).shl_wrap($bitcount.to_u8_wrap()))
					$bitcount = $bitcount + (List.get(DeflateTables.extra_offset_bits, offset_slot) ?? 0).to_u64()
					n = $bitcount.shr_zf_wrap(3)
					$out = match $bitbuf.append_le_bytes_to($out, n.to_u8_wrap()) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					$bitbuf = $bitbuf.shr_zf_wrap(n.shl_wrap(3).to_u8_wrap())
					$bitcount = $bitcount.bitwise_and(7)
					$in_next = $in_next + length
					$seq_idx = $seq_idx + 1
				}
			}

			# End of block.
			$bitbuf = $bitbuf.bitwise_or((List.get(litlen_codewords, DeflateTables.end_of_block) ?? 0).to_u64().shl_wrap($bitcount.to_u8_wrap()))
			$bitcount = $bitcount + (List.get(litlen_lens, DeflateTables.end_of_block) ?? 0).to_u64()
			n = $bitcount.shr_zf_wrap(3)
			$out = match $bitbuf.append_le_bytes_to($out, n.to_u8_wrap()) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$bitbuf = $bitbuf.shr_zf_wrap(n.shl_wrap(3).to_u8_wrap())
			$bitcount = $bitcount.bitwise_and(7)

			Ok({ out: $out, bitbuf: $bitbuf, bitcount: $bitcount })
		}
	}
}
