## Deciding where one block should end and the next begin, ported from
## libdeflate's block-splitting statistics.
##
## A DEFLATE block carries its own Huffman codes, so splitting pays whenever the
## data's character changes enough that separate codes beat the shared header
## cost. Rather than trying to price that directly, libdeflate watches a coarse
## classification of what it is emitting and ends the block when the recent mix
## diverges far enough from the block's mix so far.
##
## Observations are deliberately crude -- eight buckets for literals, taken from
## a few bits of the byte, and two for matches, short or long. The point is to
## notice a change of régime cheaply, not to model the data.
BlockSplit := [].{
	num_literal_types : U64
	num_literal_types = 8

	num_types : U64
	num_types = 10

	## How many observations must accumulate before a split is considered.
	observations_per_check : U64
	observations_per_check = 512

	min_block_length : U64
	min_block_length = 5000

	Stats : {
		observations : List(U32),
		new_observations : List(U32),
		num_observations : U64,
		num_new_observations : U64,
	}

	init : {} -> Stats
	init = |{}| {
		observations: List.repeat(0.U32, BlockSplit.num_types),
		new_observations: List.repeat(0.U32, BlockSplit.num_types),
		num_observations: 0,
		num_new_observations: 0,
	}

	## Bucket a literal by two high bits and one low bit. Cheap, and enough to
	## separate text from binary from structured data.
	observe_literal : Stats, U8 -> Stats
	observe_literal = |stats, lit| {
		idx = lit.shr_zf_wrap(5).bitwise_and(6).bitwise_or(lit.bitwise_and(1)).to_u64()
		{
			..stats,
			new_observations: List.set(stats.new_observations, idx, (List.get(stats.new_observations, idx) ?? 0) + 1) ?? stats.new_observations,
			num_new_observations: stats.num_new_observations + 1,
		}
	}

	## Matches get two buckets: shorter than 9 bytes, or not.
	observe_match : Stats, U64 -> Stats
	observe_match = |stats, length| {
		idx = BlockSplit.num_literal_types + (if length >= 9 { 1 } else { 0 })
		{
			..stats,
			new_observations: List.set(stats.new_observations, idx, (List.get(stats.new_observations, idx) ?? 0) + 1) ?? stats.new_observations,
			num_new_observations: stats.num_new_observations + 1,
		}
	}

	merge : Stats -> Stats
	merge = |stats| {
		var $obs = stats.observations
		var $i = 0.U64
		while $i < BlockSplit.num_types {
			$obs = List.set($obs, $i, (List.get($obs, $i) ?? 0) + (List.get(stats.new_observations, $i) ?? 0)) ?? $obs
			$i = $i + 1
		}
		{
			observations: $obs,
			new_observations: List.repeat(0.U32, BlockSplit.num_types),
			num_observations: stats.num_observations + stats.num_new_observations,
			num_new_observations: 0,
		}
	}

	## Whether enough has accumulated, and enough input remains, to be worth
	## testing for a split at all.
	ready : Stats, U64, U64, U64 -> Bool
	ready = |stats, block_begin, pos, data_len|
		stats.num_new_observations >= BlockSplit.observations_per_check
			and pos - block_begin >= BlockSplit.min_block_length
			and data_len - pos >= BlockSplit.min_block_length

	## Compare the recent mix against the block's mix so far, and end the block
	## if they have diverged far enough. Returns the decision and the stats,
	## which absorb the recent observations when the block continues.
	should_end : Stats, U64, U64, U64 -> { end : Bool, stats : Stats }
	should_end = |stats, block_begin, pos, data_len| {
		if !BlockSplit.ready(stats, block_begin, pos, data_len) {
			{ end: False, stats }
		} else {
			block_length = pos - block_begin
			if stats.num_observations > 0 {
				# Cross-multiplied so the two mixes can be compared without
				# dividing: expected is what the recent window would hold if it
				# matched the block's distribution.
				var $total_delta = 0.U64
				var $i = 0.U64
				while $i < BlockSplit.num_types {
					expected = (List.get(stats.observations, $i) ?? 0).to_u64() * stats.num_new_observations
					actual = (List.get(stats.new_observations, $i) ?? 0).to_u64() * stats.num_observations
					delta = if actual > expected { actual - expected } else { expected - actual }
					$total_delta = $total_delta + delta
					$i = $i + 1
				}

				num_items = stats.num_observations + stats.num_new_observations
				base_cutoff = stats.num_new_observations * 200 // 512 * stats.num_observations
				# Early in a block the evidence is thin, so the bar is raised.
				cutoff = if block_length < 10000 and num_items < 8192 {
					base_cutoff + base_cutoff * (8192 - num_items) // 8192
				} else {
					base_cutoff
				}

				if $total_delta + (block_length // 4096) * stats.num_observations >= cutoff {
					{ end: True, stats }
				} else {
					{ end: False, stats: BlockSplit.merge(stats) }
				}
			} else {
				{ end: False, stats: BlockSplit.merge(stats) }
			}
		}
	}
}
