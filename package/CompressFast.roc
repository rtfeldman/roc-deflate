import DeflateTables
import HuffmanEncode
import BlockOut
import Matchfinder
import HtMatchfinder
import CompressLazy

## The fastest DEFLATE parser, ported from libdeflate's
## `deflate_compress_fastest`.
##
## This is the greedy parser with two things given up for speed: the
## hash-table matchfinder replaces the hash chains, so the work per position is
## fixed rather than bounded by a search depth, and blocks end at a fixed
## length instead of where the block splitter would put them.
CompressFast := [].{

	## Blocks end here rather than where a split would be worthwhile, so this
	## sits below the block length the other parsers aim for.
	fast_soft_max_block_length : U64
	fast_soft_max_block_length = 65535

	fast_seq_store_length : U64
	fast_seq_store_length = 8192

	compress : List(U8), U64 -> Try(List(U8), [CompressBug])
	compress = |input, nice_match_length| {
		in_end = List.len(input)
		static = CompressLazy.build_static_codes(0)?

		var $out = List.with_capacity(5 * ((in_end + CompressLazy.min_block_length - 1) // CompressLazy.min_block_length).max(1) + in_end)
		var $bitbuf = 0.U64
		var $bitcount = 0.U64
		var $in_next = 0.U64
		var $max_len = DeflateTables.max_match_len
		var $nice_len = nice_match_length.min(DeflateTables.max_match_len)
		var $mf = {
			hash_tab: Matchfinder.init_table(65536),
			in_cur_base: 0.U64,
			next_hash: 0.U64,
		}
		var $seqs = List.repeat(
			{ litrunlen_and_length: 0.U32, offset: 0.U16, offset_slot: 0.U16 },
			CompressFast.fast_seq_store_length + 1,
		)

		var $blocking = 1.U64
		while $blocking == 1 {
			in_block_begin = $in_next
			in_max_block_end = CompressLazy.choose_max_block_end(
				$in_next,
				in_end,
				CompressFast.fast_soft_max_block_length,
			)
			var $freqs_litlen = List.repeat(0.U32, DeflateTables.num_litlen_syms)
			var $freqs_offset = List.repeat(0.U32, DeflateTables.num_offset_syms)
			var $seq_idx = 0.U64
			var $litrunlen = 0.U32

			var $in_block = 1.U64
			while $in_block == 1 {
				remaining = in_end - $in_next
				var $searched = 1.U64
				if remaining < DeflateTables.max_match_len {
					$max_len = remaining
					if $max_len < HtMatchfinder.required_nbytes {
						# Too little left to hash; the rest are literals.
						var $left = $max_len
						while $left > 0 {
							lit = (List.get(input, $in_next) ?? 0).to_u64()
							$freqs_litlen = match List.set($freqs_litlen, lit, (List.get($freqs_litlen, lit) ?? 0) + 1) {
								Ok(next) => next
								Err(_) => return Err(CompressBug)
							}
							$litrunlen = $litrunlen + 1
							$in_next = $in_next + 1
							$left = $left - 1
						}
						$searched = 0
						$in_block = 0
					} else {
						$nice_len = $nice_len.min($max_len)
					}
				} else {
				}

				if $searched == 1 {
					found = HtMatchfinder.longest_match($mf, input, $in_next, $max_len, $nice_len)?
					$mf = found.state

					if found.length != 0 {
						length_slot = DeflateTables.length_slot(found.length)
						offset_slot = DeflateTables.offset_slot(found.offset)
						litlen_sym = DeflateTables.first_len_sym + length_slot
						$freqs_litlen = match List.set($freqs_litlen, litlen_sym, (List.get($freqs_litlen, litlen_sym) ?? 0) + 1) {
							Ok(next) => next
							Err(_) => return Err(CompressBug)
						}
						$freqs_offset = match List.set($freqs_offset, offset_slot, (List.get($freqs_offset, offset_slot) ?? 0) + 1) {
							Ok(next) => next
							Err(_) => return Err(CompressBug)
						}
						$seqs = match List.set($seqs, $seq_idx, {
							litrunlen_and_length: $litrunlen.bitwise_or(found.length.to_u32_wrap().shl_wrap(BlockOut.seq_length_shift)),
							offset: found.offset.to_u16_wrap(),
							offset_slot: offset_slot.to_u16_wrap(),
						}) {
							Ok(next) => next
							Err(_) => return Err(CompressBug)
						}
						$seq_idx = $seq_idx + 1
						$litrunlen = 0

						$mf = HtMatchfinder.skip_bytes($mf, input, $in_next + 1, in_end, found.length - 1)?
						$in_next = $in_next + found.length
					} else {
						lit = (List.get(input, $in_next) ?? 0).to_u64()
						$freqs_litlen = match List.set($freqs_litlen, lit, (List.get($freqs_litlen, lit) ?? 0) + 1) {
							Ok(next) => next
							Err(_) => return Err(CompressBug)
						}
						$litrunlen = $litrunlen + 1
						$in_next = $in_next + 1
					}

					if $in_next >= in_max_block_end or $seq_idx >= CompressFast.fast_seq_store_length {
						$in_block = 0
					} else {
					}
				} else {
				}
			}

			$seqs = match List.set($seqs, $seq_idx, {
				litrunlen_and_length: $litrunlen,
				offset: 0.U16,
				offset_slot: 0.U16,
			}) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$freqs_litlen = match List.set($freqs_litlen, DeflateTables.end_of_block,
				(List.get($freqs_litlen, DeflateTables.end_of_block) ?? 0) + 1) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			litlen_code = HuffmanEncode.make_code(
				DeflateTables.num_litlen_syms,
				BlockOut.max_litlen_codeword_len,
				$freqs_litlen,
				List.repeat(0.U8, DeflateTables.num_litlen_syms),
				List.repeat(0.U32, DeflateTables.num_litlen_syms),
			)?
			offset_code = HuffmanEncode.make_code(
				DeflateTables.num_offset_syms,
				BlockOut.max_offset_codeword_len,
				$freqs_offset,
				List.repeat(0.U8, DeflateTables.num_offset_syms),
				List.repeat(0.U32, DeflateTables.num_offset_syms),
			)?

			is_final = if $in_next == in_end { 1 } else { 0 }
			flushed = BlockOut.flush_block({
				out: $out,
				bitbuf: $bitbuf,
				bitcount: $bitcount,
				input,
				block_begin: in_block_begin,
				block_length: $in_next - in_block_begin,
				seqs: $seqs,
				freqs_litlen: $freqs_litlen,
				freqs_offset: $freqs_offset,
				codes: {
					litlen_lens: litlen_code.lens,
					litlen_codewords: litlen_code.codewords,
					offset_lens: offset_code.lens,
					offset_codewords: offset_code.codewords,
				},
				static_codes: static,
				is_final,
			})?
			$out = flushed.out
			$bitbuf = flushed.bitbuf
			$bitcount = flushed.bitcount

			if $in_next == in_end {
				$blocking = 0
			} else {
			}
		}

		if $bitcount > 0 {
			$out = List.append($out, $bitbuf.to_u8_wrap())
		} else {
		}
		Ok($out)
	}
}
