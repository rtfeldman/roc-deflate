import HcMatchfinder
import BlockSplit
import Block
import BitWriter
import DeflateTables

## Level 6 compression, ported from libdeflate's `deflate_compress_lazy`.
##
## Greedy parsing takes the match it finds and moves on. Lazy parsing looks one
## byte further first: if the next position offers a distinctly better match, the
## current byte is emitted as a literal and the better match is taken instead.
## "Distinctly better" is deliberately a high bar -- deferring costs a literal,
## so a match only wins by being enough longer, or by being nearer for the same
## length.
##
## Unlike the near-optimal parser this commits as it goes, so it never revisits
## a decision and never needs a match cache.
CompressBalanced := [].{
	## libdeflate's settings at level 6.
	max_search_depth : U64
	max_search_depth = 35

	nice_match_length : U64
	nice_match_length = 65

	soft_max_block_length : U64
	soft_max_block_length = 300000

	min_block_length : U64
	min_block_length = 5000

	max_match_len : U64
	max_match_len = 258

	min_match_len : U64
	min_match_len = 3

	## How many matches a block may hold before it is ended regardless.
	seq_store_length : U64
	seq_store_length = 50000

	## Inputs this small skip compression entirely: `55 - level * 4` at level 6.
	max_passthrough_size : U64
	max_passthrough_size = 31

	## A length-3 match reaching back further than this costs more than the
	## three literals it replaces.
	max_len3_offset : U64
	max_len3_offset = 8192

	compress : List(U8) -> List(U8)
	compress = |data|
		if List.len(data) <= CompressBalanced.max_passthrough_size {
			CompressBalanced.compress_none(data)
		} else {
			CompressBalanced.compress_blocks(data)
		}

	## Stored blocks only, byte-aligned throughout.
	compress_none : List(U8) -> List(U8)
	compress_none = |data| {
		n = List.len(data)
		if n == 0 {
			[1, 0, 0, 255, 255]
		} else {
			var $out = List.with_capacity(n + 5)
			var $pos = 0.U64
			var $more = True
			while $more {
				left = n - $pos
				len = left.min(65535)
				bfinal = if left <= 65535 { 1.U8 } else { 0 }
				$out = List.append($out, bfinal)
				$out = List.append($out, len.to_u8_wrap())
				$out = List.append($out, len.shr_zf_wrap(8).to_u8_wrap())
				$out = List.append($out, len.bitwise_not().to_u8_wrap())
				$out = List.append($out, len.bitwise_not().shr_zf_wrap(8).to_u8_wrap())
				$out = List.concat($out, List.sublist(data, { start: $pos, len: len }))
				$pos = $pos + len
				if $pos >= n {
					$more = False
				} else {
				}
			}
			$out
		}
	}

	choose_max_block_end : U64, U64 -> U64
	choose_max_block_end = |block_begin, data_len|
		if data_len - block_begin < CompressBalanced.soft_max_block_length + CompressBalanced.min_block_length {
			data_len
		} else {
			block_begin + CompressBalanced.soft_max_block_length
		}

	adjusted_lens : U64 -> { max_len : U64, nice_len : U64 }
	adjusted_lens = |remaining|
		if remaining < CompressBalanced.max_match_len {
			{ max_len: remaining, nice_len: CompressBalanced.nice_match_length.min(remaining) }
		} else {
			{ max_len: CompressBalanced.max_match_len, nice_len: CompressBalanced.nice_match_length }
		}

	## The shortest match worth taking over literals, given how many distinct
	## literals the data uses.
	min_lens : List(U8)
	min_lens = [
		9, 9, 9, 9, 9, 9, 8, 8, 7, 7, 6, 6, 6, 6, 6, 6,
		5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
		5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 4, 4, 4,
		4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
		4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
	]

	## A shallower search would lower this bar, since it finds fewer long
	## matches; at this depth the table stands on its own.
	choose_min_match_len : U64 -> U64
	choose_min_match_len = |num_used_literals|
		match List.get(CompressBalanced.min_lens, num_used_literals) {
			Ok(l) => l.to_u64()
			Err(_) => CompressBalanced.min_match_len
		}

	## Estimate the alphabet size from a sample of the block, before anything has
	## been parsed.
	calculate_min_match_len : List(U8), U64, U64 -> U64
	calculate_min_match_len = |data, start, length|
		if length < 512 {
			CompressBalanced.min_match_len
		} else {
			n = length.min(4096)
			var $used = List.repeat(0.U8, 256)
			var $i = 0.U64
			while $i < n {
				b = (List.get(data, start + $i) ?? 0).to_u64()
				$used = List.set($used, b, 1) ?? $used
				$i = $i + 1
			}
			var $count = 0.U64
			var $k = 0.U64
			while $k < 256 {
				$count = $count + (List.get($used, $k) ?? 0).to_u64()
				$k = $k + 1
			}
			CompressBalanced.choose_min_match_len($count)
		}

	## Once part of the block has been parsed, its own literal frequencies are a
	## better guide than the sample taken before it started.
	recalculate_min_match_len : List(U32) -> U64
	recalculate_min_match_len = |litlen_freqs| {
		var $total = 0.U32
		var $i = 0.U64
		while $i < DeflateTables.num_literals {
			$total = $total + (List.get(litlen_freqs, $i) ?? 0)
			$i = $i + 1
		}
		cutoff = $total.shr_zf_wrap(10)
		var $used = 0.U64
		var $k = 0.U64
		while $k < DeflateTables.num_literals {
			if (List.get(litlen_freqs, $k) ?? 0) > cutoff {
				$used = $used + 1
			} else {
			}
			$k = $k + 1
		}
		CompressBalanced.choose_min_match_len($used)
	}

	## Index of the highest set bit, which stands in for how many bits an offset
	## costs when comparing two candidates.
	bit_length : U64 -> U64
	bit_length = |v| {
		var $n = 0.U64
		var $x = v
		while $x > 1 {
			$x = $x.shr_zf_wrap(1)
			$n = $n + 1
		}
		$n
	}

	## Whether a match found one byte later is enough better to be worth
	## emitting the current byte as a literal. Four sixteenths of a bit per byte
	## of extra length, against the difference in what the offsets cost.
	worth_deferring : U64, U64, U64, U64 -> Bool
	worth_deferring = |cur_len, cur_offset, next_len, next_offset|
		if next_len < cur_len {
			False
		} else {
			gain = 4 * (next_len - cur_len) + CompressBalanced.bit_length(cur_offset)
			gain > 2 + CompressBalanced.bit_length(next_offset)
		}

	## What the parser has accumulated for the block so far.
	Pending : {
		seqs : List(Block.Sequence),
		litrun : U64,
		freqs : Block.Freqs,
		matches : U64,
	}

	begin : {} -> Pending
	begin = |{}| { seqs: [], litrun: 0, freqs: Block.empty_freqs, matches: 0 }

	choose_literal : Pending, U8 -> Pending
	choose_literal = |p, literal| {
		lit = literal.to_u64()
		{
			..p,
			litrun: p.litrun + 1,
			freqs: { ..p.freqs, litlen: CompressBalanced.bump(p.freqs.litlen, lit) },
		}
	}

	choose_match : Pending, U64, U64 -> Pending
	choose_match = |p, length, offset| {
		len_sym = DeflateTables.first_len_sym + DeflateTables.length_slot(length)
		offset_slot = DeflateTables.offset_slot(offset)
		{
			seqs: List.append(p.seqs, { litrunlen: p.litrun, length, offset }),
			litrun: 0,
			freqs: {
				litlen: CompressBalanced.bump(p.freqs.litlen, len_sym),
				offset: CompressBalanced.bump(p.freqs.offset, offset_slot),
			},
			matches: p.matches + 1,
		}
	}

	## The trailing literal run is only recorded when the block ends, since until
	## then a match may still absorb it.
	finish : Pending -> { seqs : List(Block.Sequence), freqs : Block.Freqs }
	finish = |p| {
		seqs = if p.litrun > 0 {
			List.append(p.seqs, { litrunlen: p.litrun, length: 0, offset: 0 })
		} else {
			p.seqs
		}
		eob = DeflateTables.end_of_block
		{ seqs, freqs: { ..p.freqs, litlen: CompressBalanced.bump(p.freqs.litlen, eob) } }
	}

	bump : List(U32), U64 -> List(U32)
	bump = |freqs, idx|
		List.set(freqs, idx, (List.get(freqs, idx) ?? 0) + 1) ?? freqs

	## Running state the parser threads from one position to the next.
	State : {
		finder : HcMatchfinder.Finder,
		next3 : U64,
		next4 : U64,
		split : BlockSplit.Stats,
		pending : Pending,
		pos : U64,
	}

	compress_blocks : List(U8) -> List(U8)
	compress_blocks = |data| {
		data_len = List.len(data)
		var $w = BitWriter.new(data_len // 2 + 64)
		var $st = {
			finder: HcMatchfinder.init({}),
			next3: 0,
			next4: 0,
			split: BlockSplit.init({}),
			pending: CompressBalanced.begin({}),
			pos: 0,
		}
		var $block_begin = 0.U64

		while $block_begin < data_len {
			max_block_end = CompressBalanced.choose_max_block_end($block_begin, data_len)
			$st = { ..$st, split: BlockSplit.init({}), pending: CompressBalanced.begin({}) }

			var $min_len = CompressBalanced.calculate_min_match_len(data, $block_begin, max_block_end - $block_begin)
			var $next_recalc = $block_begin + (data_len - $block_begin).min(10000)
			var $parsing = True

			while $parsing {
				# Partway through, the block's own statistics replace the sample
				# taken at its start, and the interval to the next refresh grows
				# with the block so the cost stays proportional.
				if $st.pos >= $next_recalc {
					$min_len = CompressBalanced.recalculate_min_match_len($st.pending.freqs.litlen)
					$next_recalc = $next_recalc + (data_len - $next_recalc).min($st.pos - $block_begin)
				} else {
				}

				lens = CompressBalanced.adjusted_lens(data_len - $st.pos)
				found = HcMatchfinder.longest_match($st.finder, data, $st.pos, $min_len - 1, lens.max_len, lens.nice_len, CompressBalanced.max_search_depth, $st.next3, $st.next4)
				$st = { ..$st, finder: found.finder, next3: found.next3, next4: found.next4 }

				if found.length < $min_len or (found.length == CompressBalanced.min_match_len and found.offset > CompressBalanced.max_len3_offset) {
					lit = List.get(data, $st.pos) ?? 0
					$st = {
						..$st,
						pending: CompressBalanced.choose_literal($st.pending, lit),
						split: BlockSplit.observe_literal($st.split, lit),
						pos: $st.pos + 1,
					}
				} else {
					$st = { ..$st, pos: $st.pos + 1 }
					var $cur_len = found.length
					var $cur_offset = found.offset
					var $deciding = True

					while $deciding {
						if $cur_len >= lens.nice_len {
							# Long enough that looking further is not worth the
							# search it would cost.
							$deciding = False
						} else {
							look = CompressBalanced.adjusted_lens(data_len - $st.pos)
							nxt = HcMatchfinder.longest_match($st.finder, data, $st.pos, $cur_len - 1, look.max_len, look.nice_len, CompressBalanced.max_search_depth.shr_zf_wrap(1), $st.next3, $st.next4)
							$st = { ..$st, finder: nxt.finder, next3: nxt.next3, next4: nxt.next4, pos: $st.pos + 1 }

							if CompressBalanced.worth_deferring($cur_len, $cur_offset, nxt.length, nxt.offset) {
								lit = List.get(data, $st.pos - 2) ?? 0
								$st = {
									..$st,
									pending: CompressBalanced.choose_literal($st.pending, lit),
									split: BlockSplit.observe_literal($st.split, lit),
								}
								$cur_len = nxt.length
								$cur_offset = nxt.offset
							} else {
								$deciding = False
							}
						}
					}

					$st = {
						..$st,
						pending: CompressBalanced.choose_match($st.pending, $cur_len, $cur_offset),
						split: BlockSplit.observe_match($st.split, $cur_len),
					}

					# The bytes the match covers still have to enter the tables,
					# minus the ones already entered by the searches above.
					entered = if $cur_len >= lens.nice_len { 1.U64 } else { 2 }
					skip = $cur_len - entered
					r = HcMatchfinder.skip_bytes($st.finder, data, $st.pos, skip, data_len, $st.next3, $st.next4)
					$st = { ..$st, finder: r.finder, next3: r.next3, next4: r.next4, pos: $st.pos + skip }
				}

				if $st.pos >= max_block_end or $st.pending.matches >= CompressBalanced.seq_store_length {
					$parsing = False
				} else {
					decision = BlockSplit.should_end($st.split, $block_begin, $st.pos, data_len)
					$st = { ..$st, split: decision.stats }
					if decision.end {
						$parsing = False
					} else {
					}
				}
			}

			done = CompressBalanced.finish($st.pending)
			$w = Block.flush($w, data, $block_begin, $st.pos - $block_begin, done.seqs, done.freqs, $st.pos >= data_len)
			$block_begin = $st.pos
		}

		BitWriter.finish($w)
	}
}
