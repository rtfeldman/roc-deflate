import DeflateTables
import HuffmanEncode
import BlockOut
import Matchfinder
import HcMatchfinder

## The greedy and lazy DEFLATE parsers, ported from libdeflate's
## `deflate_compress_greedy` and `deflate_compress_lazy_generic`.
##
## Greedy takes the longest match at each position. Lazy first checks whether
## the next position starts a better one and, if so, emits a literal and moves
## there instead; lazy2 looks one position further still. The comparison is not
## on length alone: a longer match only wins if it beats the incumbent by
## enough to pay for the literal, and a nearer offset counts in the incumbent's
## favour, since near offsets cost fewer bits.
CompressLazy := [].{

	## Blocks shorter than this are not worth their Huffman header.
	min_block_length : U64
	min_block_length = 5000

	## The length at which the parser tries to end a block.
	soft_max_block_length : U64
	soft_max_block_length = 300000

	## Matches a block may hold before it must be ended.
	seq_store_length : U64
	seq_store_length = 50000

	num_observation_types : U64
	num_observation_types = 10

	observations_per_block_check : U64
	observations_per_block_check = 512

	Params : { max_search_depth : U64, nice_match_length : U64, lazy : U64 }

	## Minimum match length as a function of how many distinct literals the
	## data uses.
	##
	## Data with many distinct literals has expensive literals, so short
	## matches pay off; data with few has cheap literals, so they do not. A
	## shallow search cannot find long matches reliably, which caps the minimum
	## as well.
	choose_min_match_len : U64, U64 -> U64
	choose_min_match_len = |num_used_literals, max_search_depth| {
		min_lens = [
			9, 9, 9, 9, 9, 9, 8, 8, 7, 7, 6, 6, 6, 6, 6, 6,
			5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
			5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 4, 4, 4,
			4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
			4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
		]
		if num_used_literals >= 80 {
			3
		} else {
			var $min_len = (List.get(min_lens, num_used_literals) ?? 3.U8).to_u64()
			if max_search_depth < 16 {
				if max_search_depth < 5 {
					$min_len = $min_len.min(4)
				} else if max_search_depth < 10 {
					$min_len = $min_len.min(5)
				} else {
					$min_len = $min_len.min(7)
				}
			} else {
			}
			$min_len
		}
	}

	## First approximation of the minimum match length, from the distinct
	## literals in the first few kilobytes of the block.
	calculate_min_match_len : List(U8), U64, U64, U64 -> Try(U64, [CompressBug])
	calculate_min_match_len = |data, at, data_len0, max_search_depth| {
		if data_len0 < 512 {
			# Short inputs often end up as static Huffman blocks, where short
			# matches cost nothing extra.
			Ok(DeflateTables.min_match_len)
		} else {
			data_len = data_len0.min(4096)
			var $used = List.repeat(0.U8, 256)
			var $i = 0.U64
			while $i < data_len {
				b = (List.get(data, at + $i) ?? 0).to_u64()
				$used = match List.set($used, b, 1) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$i = $i + 1
			}
			var $num_used = 0.U64
			$i = 0
			while $i < 256 {
				$num_used = $num_used + (List.get($used, $i) ?? 0).to_u64()
				$i = $i + 1
			}
			Ok(CompressLazy.choose_min_match_len($num_used, max_search_depth))
		}
	}

	## Revise the minimum match length once the block's own literal
	## distribution is known, ignoring literals that barely occur.
	recalculate_min_match_len : List(U32), U64 -> U64
	recalculate_min_match_len = |freqs_litlen, max_search_depth| {
		var $literal_freq = 0.U64
		var $i = 0.U64
		while $i < DeflateTables.num_literals {
			$literal_freq = $literal_freq + (List.get(freqs_litlen, $i) ?? 0).to_u64()
			$i = $i + 1
		}
		cutoff = $literal_freq.shr_zf_wrap(10)
		var $num_used = 0.U64
		$i = 0
		while $i < DeflateTables.num_literals {
			if (List.get(freqs_litlen, $i) ?? 0).to_u64() > cutoff {
				$num_used = $num_used + 1
			} else {
			}
			$i = $i + 1
		}
		CompressLazy.choose_min_match_len($num_used, max_search_depth)
	}

	## Where a block would end if nothing else ended it first. A block that
	## would leave too short a remainder simply runs to the end of the input.
	choose_max_block_end : U64, U64, U64 -> U64
	choose_max_block_end = |in_block_begin, in_end, soft_max_len|
		if in_end - in_block_begin < soft_max_len + CompressLazy.min_block_length {
			in_end
		} else {
			in_block_begin + soft_max_len
		}

	Stats : {
		new_observations : List(U32),
		observations : List(U32),
		num_new_observations : U64,
		num_observations : U64,
	}

	## Decide whether the symbols seen recently differ enough from those seen
	## earlier in the block to be worth a new Huffman code.
	##
	## The test is the sum of absolute differences between the two
	## distributions, scaled so no division is needed, against a cutoff that
	## grows with block length. Very short blocks pay a surcharge, since their
	## header is a larger share of their cost.
	do_end_block_check : Stats, U64 -> Try({ stats : Stats, should_end : U64 }, [CompressBug])
	do_end_block_check = |stats, block_length| {
		if stats.num_observations > 0 {
			var $total_delta = 0.U64
			var $i = 0.U64
			while $i < CompressLazy.num_observation_types {
				expected = (List.get(stats.observations, $i) ?? 0).to_u64() * stats.num_new_observations
				actual = (List.get(stats.new_observations, $i) ?? 0).to_u64() * stats.num_observations
				delta = if actual > expected { actual - expected } else { expected - actual }
				$total_delta = $total_delta + delta
				$i = $i + 1
			}
			num_items = stats.num_observations + stats.num_new_observations
			var $cutoff = stats.num_new_observations * 200 // 512 * stats.num_observations
			if block_length < 10000 and num_items < 8192 {
				$cutoff = $cutoff + $cutoff * (8192 - num_items) // 8192
			} else {
			}
			if $total_delta + (block_length // 4096) * stats.num_observations >= $cutoff {
				Ok({ stats, should_end: 1 })
			} else {
				Ok({ stats: CompressLazy.merge_observations(stats)?, should_end: 0 })
			}
		} else {
			Ok({ stats: CompressLazy.merge_observations(stats)?, should_end: 0 })
		}
	}

	merge_observations : Stats -> Try(Stats, [CompressBug])
	merge_observations = |stats| {
		var $observations = stats.observations
		var $new_observations = stats.new_observations
		var $i = 0.U64
		while $i < CompressLazy.num_observation_types {
			merged = (List.get($observations, $i) ?? 0) + (List.get($new_observations, $i) ?? 0)
			$observations = match List.set($observations, $i, merged) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$new_observations = match List.set($new_observations, $i, 0) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$i = $i + 1
		}
		Ok({
			observations: $observations,
			new_observations: $new_observations,
			num_observations: stats.num_observations + stats.num_new_observations,
			num_new_observations: 0,
		})
	}
	## The static Huffman code RFC 1951 defines, built once per stream so a
	## block can be costed against it.
	build_static_codes : U64 -> Try(BlockOut.Codes, [CompressBug])
	build_static_codes = |_unused| {
		var $freqs_litlen = List.repeat(0.U32, DeflateTables.num_litlen_syms)
		var $i = 0.U64
		while $i < DeflateTables.num_litlen_syms {
			f =
				if $i < 144 {
					2
				} else if $i < 256 {
					1
				} else if $i < 280 {
					4
				} else {
					2
				}
			$freqs_litlen = match List.set($freqs_litlen, $i, f) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$i = $i + 1
		}
		litlen = HuffmanEncode.make_code(
			DeflateTables.num_litlen_syms,
			BlockOut.max_litlen_codeword_len,
			$freqs_litlen,
			List.repeat(0.U8, DeflateTables.num_litlen_syms),
			List.repeat(0.U32, DeflateTables.num_litlen_syms),
		)?
		offset = HuffmanEncode.make_code(
			DeflateTables.num_offset_syms,
			BlockOut.max_offset_codeword_len,
			List.repeat(1.U32, DeflateTables.num_offset_syms),
			List.repeat(0.U8, DeflateTables.num_offset_syms),
			List.repeat(0.U32, DeflateTables.num_offset_syms),
		)?
		Ok({
			litlen_lens: litlen.lens,
			litlen_codewords: litlen.codewords,
			offset_lens: offset.lens,
			offset_codewords: offset.codewords,
		})
	}

	## Index of the highest set bit, which stands in for the cost of an offset:
	## each extra bit of magnitude is roughly one more bit on the wire.
	bsr32 : U64 -> I64
	bsr32 = |x| 31 - x.to_u32_wrap().count_leading_zero_bits().to_i64()

	## Compress with the greedy or lazy parser.
	##
	## `params.lazy` selects how far ahead the parser looks before committing to
	## a match: zero is greedy, one is lazy, two is lazy2.
	compress : List(U8), Params -> Try(List(U8), [CompressBug])
	compress = |input, params| {
		in_end = List.len(input)
		static = CompressLazy.build_static_codes(0)?

		var $out = List.with_capacity(in_end + in_end // 4 + 1024)
		var $bitbuf = 0.U64
		var $bitcount = 0.U64
		var $in_next = 0.U64
		var $max_len = DeflateTables.max_match_len
		var $nice_len = params.nice_match_length.min(DeflateTables.max_match_len)
		var $mf = {
			hash3: Matchfinder.init_table(32768),
			hash4: Matchfinder.init_table(65536),
			next_tab: Matchfinder.init_table(Matchfinder.window_size),
			in_cur_base: 0.U64,
			next_hash3: 0.U64,
			next_hash4: 0.U64,
		}
		var $seqs = List.repeat(
			{ litrunlen_and_length: 0.U32, offset: 0.U16, offset_slot: 0.U16 },
			CompressLazy.seq_store_length + 1,
		)

		var $blocking = 1.U64
		while $blocking == 1 {
			# Starting a new block.
			in_block_begin = $in_next
			in_max_block_end = CompressLazy.choose_max_block_end(
				$in_next,
				in_end,
				CompressLazy.soft_max_block_length,
			)
			var $next_recalc_min_len = $in_next + (in_end - $in_next).min(10000)
			var $stats = {
				new_observations: List.repeat(0.U32, CompressLazy.num_observation_types),
				observations: List.repeat(0.U32, CompressLazy.num_observation_types),
				num_new_observations: 0.U64,
				num_observations: 0.U64,
			}
			var $freqs_litlen = List.repeat(0.U32, DeflateTables.num_litlen_syms)
			var $freqs_offset = List.repeat(0.U32, DeflateTables.num_offset_syms)
			var $seq_idx = 0.U64
			var $litrunlen = 0.U32
			var $min_len = CompressLazy.calculate_min_match_len(
				input,
				$in_next,
				in_max_block_end - $in_next,
				params.max_search_depth,
			)?

			var $in_block = 1.U64
			while $in_block == 1 {
				# Revise the minimum match length once enough of the block has
				# been seen for its own literal distribution to mean something.
				if $in_next >= $next_recalc_min_len {
					$min_len = CompressLazy.recalculate_min_match_len($freqs_litlen, params.max_search_depth)
					$next_recalc_min_len = $next_recalc_min_len
						+ (in_end - $next_recalc_min_len).min($in_next - in_block_begin)
				} else {
				}

				remaining0 = in_end - $in_next
				if remaining0 < DeflateTables.max_match_len {
					$max_len = remaining0
					$nice_len = $nice_len.min($max_len)
				} else {
				}

				found = HcMatchfinder.longest_match(
					$mf,
					input,
					$in_next,
					$min_len - 1,
					$max_len,
					$nice_len,
					params.max_search_depth,
				)?
				$mf = found.state

				if found.length < $min_len
					or (found.length == DeflateTables.min_match_len and found.offset > 8192) {
					# No match worth taking; emit a literal.
					lit = (List.get(input, $in_next) ?? 0).to_u64()
					$freqs_litlen = match List.set($freqs_litlen, lit, (List.get($freqs_litlen, lit) ?? 0) + 1) {
						Ok(next) => next
						Err(_) => return Err(CompressBug)
					}
					obs = lit.shr_zf_wrap(5).bitwise_and(0x6).bitwise_or(lit.bitwise_and(1))
					$stats = { ..$stats,
						new_observations: match List.set($stats.new_observations, obs, (List.get($stats.new_observations, obs) ?? 0) + 1) {
							Ok(next) => next
							Err(_) => return Err(CompressBug)
						},
						num_new_observations: $stats.num_new_observations + 1,
					}
					$litrunlen = $litrunlen + 1
					$in_next = $in_next + 1
				} else {
					$in_next = $in_next + 1
					var $cur_len = found.length
					var $cur_offset = found.offset

					# Hold the match while looking for a better one just ahead.
					var $matching = 1.U64
					while $matching == 1 {
						var $emit = 0.U64
						var $skip_after = 0.U64

						if $cur_len >= $nice_len {
							# Long enough that looking further cannot pay.
							$emit = 1
							$skip_after = $cur_len - 1
						} else {
							remaining1 = in_end - $in_next
							if remaining1 < DeflateTables.max_match_len {
								$max_len = remaining1
								$nice_len = $nice_len.min($max_len)
							} else {
								}
							# Half the search depth here: the initial match is
							# worth more effort than the lookahead.
							nxt = HcMatchfinder.longest_match(
								$mf,
								input,
								$in_next,
								$cur_len - 1,
								$max_len,
								$nice_len,
								params.max_search_depth.shr_zf_wrap(1),
							)?
							$mf = nxt.state
							$in_next = $in_next + 1

							better = nxt.length >= $cur_len
								and 4 * (nxt.length.to_i64_wrap() - $cur_len.to_i64_wrap())
									+ (CompressLazy.bsr32($cur_offset) - CompressLazy.bsr32(nxt.offset)) > 2

							if better {
								# The next position starts a better match, so
								# this position becomes a literal.
								lit = (List.get(input, $in_next - 2) ?? 0).to_u64()
								$freqs_litlen = match List.set($freqs_litlen, lit, (List.get($freqs_litlen, lit) ?? 0) + 1) {
									Ok(next) => next
									Err(_) => return Err(CompressBug)
								}
								obs = lit.shr_zf_wrap(5).bitwise_and(0x6).bitwise_or(lit.bitwise_and(1))
								$stats = { ..$stats,
									new_observations: match List.set($stats.new_observations, obs, (List.get($stats.new_observations, obs) ?? 0) + 1) {
										Ok(next) => next
										Err(_) => return Err(CompressBug)
									},
									num_new_observations: $stats.num_new_observations + 1,
								}
								$litrunlen = $litrunlen + 1
								$cur_len = nxt.length
								$cur_offset = nxt.offset
							} else if params.lazy >= 2 {
								remaining2 = in_end - $in_next
								if remaining2 < DeflateTables.max_match_len {
									$max_len = remaining2
									$nice_len = $nice_len.min($max_len)
								} else {
								}
								nxt2 = HcMatchfinder.longest_match(
									$mf,
									input,
									$in_next,
									$cur_len - 1,
									$max_len,
									$nice_len,
									params.max_search_depth.shr_zf_wrap(2),
								)?
								$mf = nxt2.state
								$in_next = $in_next + 1

								better2 = nxt2.length >= $cur_len
									and 4 * (nxt2.length.to_i64_wrap() - $cur_len.to_i64_wrap())
										+ (CompressLazy.bsr32($cur_offset) - CompressLazy.bsr32(nxt2.offset)) > 6

								if better2 {
									# Two positions ahead is better still, so
									# both of these become literals.
									lit_a = (List.get(input, $in_next - 3) ?? 0).to_u64()
									$freqs_litlen = match List.set($freqs_litlen, lit_a, (List.get($freqs_litlen, lit_a) ?? 0) + 1) {
										Ok(next) => next
										Err(_) => return Err(CompressBug)
									}
									obs_a = lit_a.shr_zf_wrap(5).bitwise_and(0x6).bitwise_or(lit_a.bitwise_and(1))
									$stats = { ..$stats,
										new_observations: match List.set($stats.new_observations, obs_a, (List.get($stats.new_observations, obs_a) ?? 0) + 1) {
											Ok(next) => next
											Err(_) => return Err(CompressBug)
										},
										num_new_observations: $stats.num_new_observations + 1,
									}
									lit_b = (List.get(input, $in_next - 2) ?? 0).to_u64()
									$freqs_litlen = match List.set($freqs_litlen, lit_b, (List.get($freqs_litlen, lit_b) ?? 0) + 1) {
										Ok(next) => next
										Err(_) => return Err(CompressBug)
									}
									obs_b = lit_b.shr_zf_wrap(5).bitwise_and(0x6).bitwise_or(lit_b.bitwise_and(1))
									$stats = { ..$stats,
										new_observations: match List.set($stats.new_observations, obs_b, (List.get($stats.new_observations, obs_b) ?? 0) + 1) {
											Ok(next) => next
											Err(_) => return Err(CompressBug)
										},
										num_new_observations: $stats.num_new_observations + 2 - 1,
									}
									$litrunlen = $litrunlen + 2
									$cur_len = nxt2.length
									$cur_offset = nxt2.offset
								} else {
									$emit = 1
									$skip_after = if $cur_len > 3 { $cur_len - 3 } else { 0 }
								}
							} else {
								$emit = 1
								$skip_after = $cur_len - 2
							}
						}

						if $emit == 1 {
							length_slot = DeflateTables.length_slot($cur_len)
							offset_slot = DeflateTables.offset_slot($cur_offset)
							litlen_sym = DeflateTables.first_len_sym + length_slot
							$freqs_litlen = match List.set($freqs_litlen, litlen_sym, (List.get($freqs_litlen, litlen_sym) ?? 0) + 1) {
								Ok(next) => next
								Err(_) => return Err(CompressBug)
							}
							$freqs_offset = match List.set($freqs_offset, offset_slot, (List.get($freqs_offset, offset_slot) ?? 0) + 1) {
								Ok(next) => next
								Err(_) => return Err(CompressBug)
							}
							obs = 8 + if $cur_len >= 9 { 1 } else { 0 }
							$stats = { ..$stats,
								new_observations: match List.set($stats.new_observations, obs, (List.get($stats.new_observations, obs) ?? 0) + 1) {
									Ok(next) => next
									Err(_) => return Err(CompressBug)
								},
								num_new_observations: $stats.num_new_observations + 1,
							}
							$seqs = match List.set($seqs, $seq_idx, {
								litrunlen_and_length: $litrunlen.bitwise_or($cur_len.to_u32_wrap().shl_wrap(BlockOut.seq_length_shift)),
								offset: $cur_offset.to_u16_wrap(),
								offset_slot: offset_slot.to_u16_wrap(),
							}) {
								Ok(next) => next
								Err(_) => return Err(CompressBug)
							}
							$seq_idx = $seq_idx + 1
							$litrunlen = 0

							if $skip_after > 0 {
								$mf = HcMatchfinder.skip_bytes($mf, input, $in_next, in_end, $skip_after)?
								$in_next = $in_next + $skip_after
							} else {
							}
							$matching = 0
						} else {
						}
					}
				}

				# Time to end the block?
				if $in_next >= in_max_block_end or $seq_idx >= CompressLazy.seq_store_length {
					$in_block = 0
				} else if $stats.num_new_observations >= CompressLazy.observations_per_block_check
					and $in_next - in_block_begin >= CompressLazy.min_block_length
					and in_end - $in_next >= CompressLazy.min_block_length {
					checked = CompressLazy.do_end_block_check($stats, $in_next - in_block_begin)?
					$stats = checked.stats
					if checked.should_end == 1 {
						$in_block = 0
					} else {
					}
				} else {
				}
			}

			# Close the sequence list with the trailing literal run.
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

		# Any bits left over occupy one final byte.
		if $bitcount > 0 {
			$out = List.append($out, $bitbuf.to_u8_wrap())
		} else {
		}
		Ok($out)
	}
}
