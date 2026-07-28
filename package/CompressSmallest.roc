import BtMatchfinder
import BlockSplit
import CostModel
import DefaultCosts
import MinCostPath
import Block
import BitWriter
import DeflateTables

## Level 12 compression, ported from libdeflate's
## `deflate_compress_near_optimal`.
##
## The shape is: collect every match worth considering for a block into a cache,
## then repeatedly find the cheapest path through it, each pass pricing symbols
## using the codes the previous pass implied. The first pass has no codes to
## work from and prices from a measured default model instead.
##
## Caching the matches is what makes the repetition affordable: the matchfinder
## runs once over the block, not once per pass.
CompressSmallest := [].{
	## libdeflate's settings at level 12.
	max_search_depth : U64
	max_search_depth = 300

	nice_match_length : U64
	nice_match_length = 258

	max_optim_passes : U64
	max_optim_passes = 10

	min_improvement_to_continue : U64
	min_improvement_to_continue = 1

	min_bits_to_use_nonfinal_path : U64
	min_bits_to_use_nonfinal_path = 1

	max_len_to_optimize_static_block : U64
	max_len_to_optimize_static_block = 10000

	soft_max_block_length : U64
	soft_max_block_length = 300000

	min_block_length : U64
	min_block_length = 5000

	max_match_len : U64
	max_match_len = 258

	min_match_len : U64
	min_match_len = 3

	## Inputs this small skip compression entirely: `55 - level * 4` at level 12.
	max_passthrough_size : U64
	max_passthrough_size = 7

	compress : List(U8) -> List(U8)
	compress = |data|
		if List.len(data) <= CompressSmallest.max_passthrough_size {
			CompressSmallest.compress_none(data)
		} else {
			CompressSmallest.compress_blocks(data)
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

	## Where the current block may end at the latest.
	choose_max_block_end : U64, U64 -> U64
	choose_max_block_end = |block_begin, data_len|
		if data_len - block_begin < CompressSmallest.soft_max_block_length + CompressSmallest.min_block_length {
			data_len
		} else {
			block_begin + CompressSmallest.soft_max_block_length
		}

	## The shortest match worth counting as a match rather than as literals,
	## given how many distinct literals the data uses. Data with a small
	## alphabet codes literals cheaply, so a short match has to clear a higher
	## bar to be worth its offset.
	min_lens : List(U8)
	min_lens = [
		9, 9, 9, 9, 9, 9, 8, 8, 7, 7, 6, 6, 6, 6, 6, 6,
		5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
		5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 4, 4, 4,
		4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
		4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
	]

	choose_min_match_len : U64 -> U64
	choose_min_match_len = |num_used_literals|
		# A deep search finds long matches anyway, so no clamping applies here;
		# the shallower levels lower the bar instead.
		match List.get(CompressSmallest.min_lens, num_used_literals) {
			Ok(l) => l.to_u64()
			Err(_) => CompressSmallest.min_match_len
		}

	## Estimate the alphabet size from a sample of the block, before anything
	## has been parsed.
	calculate_min_match_len : List(U8), U64, U64 -> U64
	calculate_min_match_len = |data, start, length|
		if length < 512 {
			CompressSmallest.min_match_len
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
			CompressSmallest.choose_min_match_len($count)
		}

	## Matches cannot reach past the end of the input.
	adjusted_lens : U64 -> { max_len : U64, nice_len : U64 }
	adjusted_lens = |remaining|
		if remaining < CompressSmallest.max_match_len {
			{ max_len: remaining, nice_len: CompressSmallest.nice_match_length.min(remaining) }
		} else {
			{ max_len: CompressSmallest.max_match_len, nice_len: CompressSmallest.nice_match_length }
		}

	## What the matchfinder recorded at one position, plus the running state the
	## next position needs.
	## Match lengths are staged the same way the split observations are: what
	## has been seen since the last checkpoint stays pending, because a block
	## that ends early rewinds past it and must not have counted it.
	State : {
		finder : BtMatchfinder.Finder,
		next3 : U64,
		next4 : U64,
		split : BlockSplit.Stats,
		match_len_freqs : List(U32),
		new_match_len_freqs : List(U32),
		next_observation : U64,
	}

	merge_match_len_freqs : State -> State
	merge_match_len_freqs = |st| {
		var $merged = st.match_len_freqs
		var $i = 0.U64
		while $i <= CompressSmallest.max_match_len {
			$merged = List.set($merged, $i, (List.get($merged, $i) ?? 0) + (List.get(st.new_match_len_freqs, $i) ?? 0)) ?? $merged
			$i = $i + 1
		}
		{
			..st,
			match_len_freqs: $merged,
			new_match_len_freqs: List.repeat(0.U32, CompressSmallest.max_match_len + 1),
		}
	}

	compress_blocks : List(U8) -> List(U8)
	compress_blocks = |data| {
		data_len = List.len(data)
		var $w = BitWriter.new(data_len // 2 + 64)
		var $st = {
			finder: BtMatchfinder.init({}),
			next3: 0,
			next4: 0,
			split: BlockSplit.init({}),
			match_len_freqs: List.repeat(0.U32, CompressSmallest.max_match_len + 1),
			new_match_len_freqs: List.repeat(0.U32, CompressSmallest.max_match_len + 1),
			next_observation: 0,
		}
		# Carried from the previous block, so the next block's starting prices
		# can be nudged from the ones that worked rather than reset.
		var $costs = CompressSmallest.default_costs(0, 0)
		var $prev_observations = List.repeat(0.U32, BlockSplit.num_types)
		var $prev_num_observations = 0.U64
		var $prev_only_literals = False
		var $block_begin = 0.U64
		var $pos = 0.U64
		# Survives across blocks: when a block ends early, the positions
		# already scanned past its end start the next block's cache.
		var $cache = List.with_capacity(CompressSmallest.soft_max_block_length)

		while $block_begin < data_len {
			max_block_end = CompressSmallest.choose_max_block_end($block_begin, data_len)

			# A block the previous one encoded as pure literals is unlikely to
			# hold worthwhile matches either, so nothing counts as a match.
			min_len = if $prev_only_literals {
				CompressSmallest.max_match_len + 1
			} else {
				CompressSmallest.calculate_min_match_len(data, $block_begin, max_block_end - $block_begin)
			}

			var $prev_check = 0.U64
			var $have_prev_check = False
			var $change_detected = False
			var $scanning = True

			while $scanning {
				lens = CompressSmallest.adjusted_lens(data_len - $pos)

				matches = if lens.max_len >= BtMatchfinder.required_nbytes {
					r = BtMatchfinder.advance($st.finder, data, $pos, lens.max_len, lens.nice_len, CompressSmallest.max_search_depth, $st.next3, $st.next4, True)
					$st = { ..$st, finder: r.finder, next3: r.next3, next4: r.next4 }
					r.matches
				} else {
					[]
				}

				best_len = match List.last(matches) {
					Ok(m) => m.length
					Err(_) => 0
				}

				# Statistics are sampled, not taken at every position: a match
				# covers the positions it spans, so observing each of them
				# would count the same stretch of data many times over.
				if $pos >= $st.next_observation {
					if best_len >= min_len {
						$st = {
							..$st,
							split: BlockSplit.observe_match($st.split, best_len),
							next_observation: $pos + best_len,
							new_match_len_freqs: List.set($st.new_match_len_freqs, best_len, (List.get($st.new_match_len_freqs, best_len) ?? 0) + 1) ?? $st.new_match_len_freqs,
						}
					} else {
						$st = {
							..$st,
							split: BlockSplit.observe_literal($st.split, List.get(data, $pos) ?? 0),
							next_observation: $pos + 1,
						}
					}
				} else {
				}

				$cache = List.append($cache, { matches, literal: List.get(data, $pos) ?? 0 })
				$pos = $pos + 1

				# A match this good will be taken, so the positions it covers
				# need no matches of their own -- only the tree still has to
				# see them.
				if best_len >= CompressSmallest.min_match_len and best_len >= lens.nice_len {
					var $skip = best_len - 1
					while $skip > 0 {
						skip_lens = CompressSmallest.adjusted_lens(data_len - $pos)
						if skip_lens.max_len >= BtMatchfinder.required_nbytes {
							r = BtMatchfinder.advance($st.finder, data, $pos, skip_lens.max_len, skip_lens.nice_len, CompressSmallest.max_search_depth, $st.next3, $st.next4, False)
							$st = { ..$st, finder: r.finder, next3: r.next3, next4: r.next4 }
						} else {
						}
						$cache = List.append($cache, { matches: [], literal: List.get(data, $pos) ?? 0 })
						$pos = $pos + 1
						$skip = $skip - 1
					}
				} else {
				}

				if $pos >= max_block_end {
					$scanning = False
				} else if BlockSplit.ready($st.split, $block_begin, $pos, data_len) {
					decision = BlockSplit.should_end($st.split, $block_begin, $pos, data_len)
					$st = { ..$st, split: decision.stats }
					if decision.end {
						$change_detected = True
						$scanning = False
					} else {
						# This point still matched the block, so it is where the
						# block gets cut if a change turns up later, and what
						# was seen up to here can safely be counted.
						$st = CompressSmallest.merge_match_len_freqs($st)
						$prev_check = $pos
						$have_prev_check = True
					}
				} else {
				}
			}

			# When the data changed character, end the block at the last point
			# that still looked like the block's beginning, not where the
			# change was noticed.
			block_end = if $change_detected and $have_prev_check { $prev_check } else { $pos }
			block_length = block_end - $block_begin
			is_first = $block_begin == 0
			is_final = block_end >= data_len

			# A block that ran to its natural end has nothing pending to
			# discard, so everything seen counts toward its statistics.
			if !$change_detected {
				$st = CompressSmallest.merge_match_len_freqs($st)
				$st = { ..$st, split: BlockSplit.merge($st.split) }
			} else {
			}

			starting_costs = CompressSmallest.starting_costs(
				data,
				$block_begin,
				block_length,
				$st.match_len_freqs,
				is_first,
				$costs,
				$st.split,
				$prev_observations,
				$prev_num_observations,
			)

			result = CompressSmallest.optimize(
				List.sublist($cache, { start: 0, len: block_length }),
				data,
				$block_begin,
				block_length,
				starting_costs,
			)
			$costs = result.costs
			$prev_only_literals = result.only_literals
			$w = Block.flush($w, data, $block_begin, block_length, result.seqs, result.freqs, is_final)

			$prev_observations = $st.split.observations
			$prev_num_observations = $st.split.num_observations

			# Rewound bytes go back to the next block's cache; their matches
			# are still valid there. What was pending stays pending: those
			# positions belong to the next block now.
			$cache = List.sublist($cache, { start: block_length, len: $pos - block_end })
			$st = {
				..$st,
				split: BlockSplit.clear_old($st.split),
				match_len_freqs: List.repeat(0.U32, CompressSmallest.max_match_len + 1),
				next_observation: $pos,
			}
			$block_begin = block_end
		}

		BitWriter.finish($w)
	}

	## Run the cost-refinement passes and pick the best of everything tried.
	##
	## Three encodings compete: the cheapest path under refined dynamic codes,
	## the cheapest path under the fixed codes, and every byte as a literal.
	## The last two need no header, which sometimes wins outright on short or
	## incompressible blocks.
	optimize : List(MinCostPath.Cached), List(U8), U64, U64, CostModel.Costs -> { seqs : List(Block.Sequence), freqs : Block.Freqs, only_literals : Bool, costs : CostModel.Costs }
	optimize = |cache, data, block_begin, block_length, starting_costs| {
		lit_freqs = CostModel.all_literals_freqs(data, block_begin, block_length)
		only_lits_cost = CostModel.true_cost(lit_freqs, Block.build_codes(lit_freqs))

		# Fixed codes are only worth pricing on blocks short enough that their
		# lack of a header can make up for their worse fit.
		static_result = if block_length <= CompressSmallest.max_len_to_optimize_static_block {
			path = MinCostPath.find(cache, block_length, CostModel.from_codes(Block.static_codes))
			# The path prices every symbol but the end-of-block marker, which
			# the fixed code spends 7 bits on.
			{ found: True, cost: path.cost // CostModel.bit_cost + 7, items: path.items }
		} else {
			{ found: False, cost: 0, items: [] }
		}

		var $costs = starting_costs
		var $saved_costs = $costs
		var $best_cost = 0xFFFFFFFF.U64
		var $cost = 0xFFFFFFFF.U64
		var $freqs = lit_freqs
		var $items = []
		var $passes = CompressSmallest.max_optim_passes
		var $going = True

		while $going and $passes > 0 {
			path = MinCostPath.find(cache, block_length, $costs)
			$items = path.items
			$freqs = MinCostPath.tally($items, block_length)
			codes = Block.build_codes($freqs)
			$cost = CostModel.true_cost($freqs, codes)

			if $cost + CompressSmallest.min_improvement_to_continue > $best_cost {
				$going = False
			} else {
				$best_cost = $cost
				# Price the next pass from the codes this one implied, keeping
				# the costs that produced it in case the next pass is worse.
				$saved_costs = $costs
				$costs = CostModel.from_codes(codes)
				$passes = $passes - 1
			}
		}

		alt_cost = if static_result.found { only_lits_cost.min(static_result.cost) } else { only_lits_cost }

		# Whichever encoding wins leaves its codes behind as the prices the next
		# block starts from.
		if alt_cost < $best_cost {
			if !static_result.found or only_lits_cost < static_result.cost {
				{ seqs: [{ litrunlen: block_length, length: 0, offset: 0 }], freqs: lit_freqs, only_literals: True, costs: CostModel.from_codes(Block.build_codes(lit_freqs)) }
			} else {
				{ seqs: MinCostPath.to_sequences(static_result.items, block_length), freqs: MinCostPath.tally(static_result.items, block_length), only_literals: False, costs: CostModel.from_codes(Block.static_codes) }
			}
		} else if $cost >= $best_cost + CompressSmallest.min_bits_to_use_nonfinal_path {
			# The last pass came out worse than an earlier one, so go back to
			# the costs that produced the best and take that path instead.
			back = MinCostPath.find(cache, block_length, $saved_costs).items
			back_freqs = MinCostPath.tally(back, block_length)
			{ seqs: MinCostPath.to_sequences(back, block_length), freqs: back_freqs, only_literals: False, costs: CostModel.from_codes(Block.build_codes(back_freqs)) }
		} else {
			{ seqs: MinCostPath.to_sequences($items, block_length), freqs: $freqs, only_literals: False, costs: $costs }
		}
	}

	## The prices the first pass works from.
	##
	## The very first block has nothing to go on and takes the defaults
	## outright. Later blocks start from the prices the previous block ended
	## with, pulled toward the defaults by however much the data has changed
	## character -- unchanged data keeps most of what was learned, and a sharp
	## change discards it entirely.
	starting_costs : List(U8), U64, U64, List(U32), Bool, CostModel.Costs, BlockSplit.Stats, List(U32), U64 -> CostModel.Costs
	starting_costs = |data, start, length, match_len_freqs, is_first, prev_costs, split, prev_observations, prev_num_observations| {
		chosen = CompressSmallest.choose_default_costs(data, start, length, match_len_freqs)
		if is_first {
			CompressSmallest.default_costs(chosen.lit_cost, chosen.len_sym_cost)
		} else {
			var $total_delta = 0.U64
			var $i = 0.U64
			while $i < BlockSplit.num_types {
				prev = (List.get(prev_observations, $i) ?? 0).to_u64() * split.num_observations
				cur = (List.get(split.observations, $i) ?? 0).to_u64() * prev_num_observations
				$total_delta = $total_delta + (if prev > cur { prev - cur } else { cur - prev })
				$i = $i + 1
			}
			cutoff = prev_num_observations * split.num_observations * 200 // 512

			if $total_delta > 3 * cutoff {
				CompressSmallest.default_costs(chosen.lit_cost, chosen.len_sym_cost)
			} else if 4 * $total_delta > 9 * cutoff {
				CompressSmallest.blend_costs(prev_costs, chosen.lit_cost, chosen.len_sym_cost, 3)
			} else if 2 * $total_delta > 3 * cutoff {
				CompressSmallest.blend_costs(prev_costs, chosen.lit_cost, chosen.len_sym_cost, 2)
			} else if 2 * $total_delta > cutoff {
				CompressSmallest.blend_costs(prev_costs, chosen.lit_cost, chosen.len_sym_cost, 1)
			} else {
				CompressSmallest.blend_costs(prev_costs, chosen.lit_cost, chosen.len_sym_cost, 0)
			}
		}
	}

	## Move a price toward its default by an amount that grows with how much
	## the data has changed.
	blend : U64, U64, U64 -> U64
	blend = |cost, default_cost, change_amount|
		if change_amount == 0 {
			(default_cost + 3 * cost) // 4
		} else if change_amount == 1 {
			(default_cost + cost) // 2
		} else if change_amount == 2 {
			(5 * default_cost + 3 * cost) // 8
		} else {
			(3 * default_cost + cost) // 4
		}

	blend_costs : CostModel.Costs, U64, U64, U64 -> CostModel.Costs
	blend_costs = |costs, lit_cost, len_sym_cost, change_amount| {
		var $literal = costs.literal
		var $i = 0.U64
		while $i < 256 {
			c = (List.get($literal, $i) ?? 0).to_u64()
			$literal = List.set($literal, $i, CompressSmallest.blend(c, lit_cost, change_amount).to_u32_wrap()) ?? $literal
			$i = $i + 1
		}

		var $length = costs.length
		var $l = CompressSmallest.min_match_len
		while $l <= CompressSmallest.max_match_len {
			c = (List.get($length, $l) ?? 0).to_u64()
			$length = List.set($length, $l, CompressSmallest.blend(c, DefaultCosts.length_cost($l, len_sym_cost), change_amount).to_u32_wrap()) ?? $length
			$l = $l + 1
		}

		var $offset = costs.offset_slot
		var $o = 0.U64
		while $o < 30 {
			c = (List.get($offset, $o) ?? 0).to_u64()
			$offset = List.set($offset, $o, CompressSmallest.blend(c, DefaultCosts.offset_slot_cost($o), change_amount).to_u32_wrap()) ?? $offset
			$o = $o + 1
		}

		{ literal: $literal, length: $length, offset_slot: $offset }
	}

	## Build a whole cost model from the two numbers that summarize it.
	default_costs : U64, U64 -> CostModel.Costs
	default_costs = |lit_cost, len_sym_cost| {
		var $length = List.repeat(0.U32, CompressSmallest.max_match_len + 1)
		var $l = CompressSmallest.min_match_len
		while $l <= CompressSmallest.max_match_len {
			$length = List.set($length, $l, DefaultCosts.length_cost($l, len_sym_cost).to_u32_wrap()) ?? $length
			$l = $l + 1
		}

		var $offset = List.repeat(0.U32, 30)
		var $o = 0.U64
		while $o < 30 {
			$offset = List.set($offset, $o, DefaultCosts.offset_slot_cost($o).to_u32_wrap()) ?? $offset
			$o = $o + 1
		}

		{ literal: List.repeat(lit_cost.to_u32_wrap(), 256), length: $length, offset_slot: $offset }
	}

	## Summarize the block as a literal price and a length-symbol price, chosen
	## from how match-heavy it looks and how many distinct literals it uses.
	choose_default_costs : List(U8), U64, U64, List(U32) -> { lit_cost : U64, len_sym_cost : U64 }
	choose_default_costs = |data, start, length, match_len_freqs| {
		var $freq = List.repeat(0.U32, 256)
		var $i = 0.U64
		while $i < length {
			b = (List.get(data, start + $i) ?? 0).to_u64()
			$freq = List.set($freq, b, (List.get($freq, b) ?? 0) + 1) ?? $freq
			$i = $i + 1
		}

		# Literals used very rarely do not count toward the alphabet size.
		cutoff = length.shr_zf_wrap(11).to_u32_wrap()
		var $used = 0.U64
		var $k = 0.U64
		while $k < 256 {
			if (List.get($freq, $k) ?? 0) > cutoff {
				$used = $used + 1
			} else {
			}
			$k = $k + 1
		}
		num_used_literals = if $used == 0 { 1 } else { $used }

		# Weigh how much of the block the matches found so far actually cover
		# against what is left over as literals, counting only matches long
		# enough to be worth taking.
		var $match_freq = 0.U64
		var $literal_freq = length
		var $len = CompressSmallest.choose_min_match_len(num_used_literals)
		while $len <= CompressSmallest.max_match_len {
			f = (List.get(match_len_freqs, $len) ?? 0).to_u64()
			$match_freq = $match_freq + f
			covered = $len * f
			$literal_freq = if covered > $literal_freq { 0 } else { $literal_freq - covered }
			$len = $len + 1
		}

		entry_idx = if $match_freq > $literal_freq {
			2
		} else if $match_freq * 4 > $literal_freq {
			1
		} else {
			0
		}

		entry = List.get(DefaultCosts.table, entry_idx) ?? { lit_cost: [], len_sym_cost: 0 }
		{
			lit_cost: (List.get(entry.lit_cost, num_used_literals) ?? 0).to_u64(),
			len_sym_cost: entry.len_sym_cost,
		}
	}
}
