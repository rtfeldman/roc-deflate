import DeflateTables
import CostModel
import Block

## The shortest-path search at the heart of near-optimal parsing, ported from
## libdeflate's `deflate_find_min_cost_path`.
##
## Greedy and lazy parsing decide each match as they reach it. This instead
## treats the block as a graph -- each position an node, each literal or match
## an edge priced by the cost model -- and finds the cheapest path from the
## start to the end. Because the cost of an edge depends only on the symbol it
## emits, the search can run backward from the end in one pass, so each position
## is solved once using answers already computed for everything after it.
##
## The result is only as good as the cost model, which is why the caller runs it
## repeatedly: each pass prices the next using the codes the previous one
## implied.
MinCostPath := [].{
	## What the parser chose at a position: a literal, or a match reaching back
	## `offset` for `length` bytes.
	Item : { length : U64, offset : U64 }

	## Matches available at one position, plus the literal byte there. This is
	## libdeflate's match cache, which records what the matchfinder found so the
	## repeated passes do not have to search again.
	Cached : { matches : List(CostModel.Match), literal : U8 }

	## Find the cheapest encoding of the block.
	##
	## Returns one item per position -- positions covered by a match hold the
	## match at its start and are skipped over when walking forward -- along
	## with what the whole path costs, in sixteenths of a bit.
	find : List(Cached), U64, CostModel.Costs -> { items : List(Item), cost : U64 }
	find = |cache, block_length, costs| {
		# cost_to_end[i] is the cost of encoding everything from position i on.
		# Positions past the end of the block are priced prohibitively rather
		# than being absent: a cached match may run past the block boundary,
		# and it has to be representable in order to be rejected.
		var $cost_to_end = List.repeat(0x80000000.U64, block_length + CostModel.max_match_len + 1)
		$cost_to_end = List.set($cost_to_end, block_length, 0) ?? $cost_to_end
		var $items = List.repeat({ length: 1, offset: 0 }, block_length + 1)

		var $node = block_length
		while $node > 0 {
			$node = $node - 1
			entry = List.get(cache, $node) ?? { matches: [], literal: 0 }

			# A literal is always available, so it is the starting candidate.
			literal = entry.literal.to_u64()
			lit_cost = (List.get(costs.literal, literal) ?? 0).to_u64()
			var $best = lit_cost + (List.get($cost_to_end, $node + 1) ?? 0)
			var $best_item = { length: 1, offset: literal }

			# Then every match, at every length it could be truncated to. A
			# shorter match is sometimes cheaper overall, because of what it
			# leaves behind.
			var $m = 0.U64
			while $m < List.len(entry.matches) {
				candidate = List.get(entry.matches, $m) ?? { length: 0, offset: 0 }
				offset_slot = DeflateTables.offset_slot(candidate.offset)
				offset_cost = (List.get(costs.offset_slot, offset_slot) ?? 0).to_u64()

				# Lengths run from the minimum up to this match's length, and
				# each match starts where the previous one left off, so no
				# length is priced twice.
				start_len = if $m == 0 {
					CostModel.min_match_len
				} else {
					(List.get(entry.matches, $m - 1) ?? { length: 0, offset: 0 }).length + 1
				}

				var $len = start_len
				while $len <= candidate.length {
					total = offset_cost
						+ (List.get(costs.length, $len) ?? 0).to_u64()
						+ (List.get($cost_to_end, $node + $len) ?? 0)
					if total < $best {
						$best = total
						$best_item = { length: $len, offset: candidate.offset }
					} else {
					}
					$len = $len + 1
				}
				$m = $m + 1
			}

			$cost_to_end = List.set($cost_to_end, $node, $best) ?? $cost_to_end
			$items = List.set($items, $node, $best_item) ?? $items
		}

		{ items: $items, cost: List.get($cost_to_end, 0) ?? 0 }
	}

	## Count the symbols the chosen path emits, which become the frequencies the
	## next pass builds its codes from. Mirrors `deflate_tally_item_list`.
	tally : List(Item), U64 -> Block.Freqs
	tally = |items, block_length| {
		var $litlen = List.repeat(0.U32, DeflateTables.num_litlen_syms)
		var $offset = List.repeat(0.U32, DeflateTables.num_offset_syms)

		var $pos = 0.U64
		while $pos < block_length {
			item = List.get(items, $pos) ?? { length: 1, offset: 0 }
			if item.length == 1 {
				$litlen = MinCostPath.bump($litlen, item.offset)
			} else {
				slot = DeflateTables.length_slot(item.length)
				$litlen = MinCostPath.bump($litlen, DeflateTables.first_len_sym + slot)
				$offset = MinCostPath.bump($offset, DeflateTables.offset_slot(item.offset))
			}
			$pos = $pos + item.length
		}

		{ litlen: MinCostPath.bump($litlen, DeflateTables.end_of_block), offset: $offset }
	}

	## Turn the chosen path into the literal runs and matches the block writer
	## consumes.
	to_sequences : List(Item), U64 -> List(Block.Sequence)
	to_sequences = |items, block_length| {
		var $seqs = List.with_capacity(64)
		var $litrun = 0.U64
		var $pos = 0.U64
		while $pos < block_length {
			item = List.get(items, $pos) ?? { length: 1, offset: 0 }
			if item.length == 1 {
				$litrun = $litrun + 1
			} else {
				$seqs = List.append($seqs, { litrunlen: $litrun, length: item.length, offset: item.offset })
				$litrun = 0
			}
			$pos = $pos + item.length
		}
		if $litrun > 0 {
			List.append($seqs, { litrunlen: $litrun, length: 0, offset: 0 })
		} else {
			$seqs
		}
	}

	bump : List(U32), U64 -> List(U32)
	bump = |freqs, idx|
		List.set(freqs, idx, (List.get(freqs, idx) ?? 0) + 1) ?? freqs
}
