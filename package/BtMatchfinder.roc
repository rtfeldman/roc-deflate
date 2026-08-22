## The binary-tree matchfinder libdeflate uses at its highest levels, ported
## from `bt_matchfinder.h`.
##
## Where the hash-table finder keeps two candidates and takes the better one,
## this maintains a binary search tree per hash bucket, ordered by the bytes
## following each position. Walking it yields matches in increasing length,
## which is what the near-optimal parser needs: it wants every match worth
## considering, not just the longest.
##
## The walk also rebuilds the tree as it goes, splicing the current position in
## while descending. That is why the search and the insertion cannot be
## separated, and why the order of the pointer updates matters as much as the
## comparisons.
BtMatchfinder := [].{
	hash3_order : U8
	hash3_order = 16

	hash3_ways : U64
	hash3_ways = 2

	hash4_order : U8
	hash4_order = 16

	hash_size : U64
	hash_size = 65536

	required_nbytes : U64
	required_nbytes = 5

	window_size : I32
	window_size = 32768

	window_mask : U64
	window_mask = 32767

	initval : I32
	initval = -32768

	min_match_len : U64
	min_match_len = 3

	## `hash3` keeps two ways for length-3 matches; `hash4` roots the trees;
	## `child` holds the left and right links, two per window position.
	Finder : {
		hash3a : List(I32),
		hash3b : List(I32),
		hash4 : List(I32),
		child : List(I32),
	}

	init : {} -> Finder
	init = |{}| {
		hash3a: List.repeat(BtMatchfinder.initval, BtMatchfinder.hash_size),
		hash3b: List.repeat(BtMatchfinder.initval, BtMatchfinder.hash_size),
		hash4: List.repeat(BtMatchfinder.initval, BtMatchfinder.hash_size),
		child: List.repeat(BtMatchfinder.initval, 65536),
	}

	Match : { length : U64, offset : U64 }

	lz_hash : U32, U8 -> U64
	lz_hash = |seq, bits|
		seq.times_wrap(0x1E35A7BD).shr_zf_wrap(32 - bits).to_u64()

	load_u32 : List(U8), U64 -> U32
	load_u32 = |data, pos| U32.from_le_bytes(data, pos) ?? 0

	## Three bytes at `pos`, as the length-3 hash and comparison use.
	load_u24 : List(U8), U64 -> U32
	load_u24 = |data, pos| {
		b0 = (List.get(data, pos) ?? 0).to_u32()
		b1 = (List.get(data, pos + 1) ?? 0).to_u32()
		b2 = (List.get(data, pos + 2) ?? 0).to_u32()
		b0.bitwise_or(b1.shl_wrap(8)).bitwise_or(b2.shl_wrap(16))
	}

	lz_extend : List(U8), U64, U64, U64, U64 -> U64
	lz_extend = |data, strptr, matchptr, start_len, max_len| {
		var $len = start_len
		var $going = True
		while $going {
			if $len >= max_len {
				$going = False
			} else {
				if (List.get(data, strptr + $len) ?? 0) == (List.get(data, matchptr + $len) ?? 0) {
					$len = $len + 1
				} else {
					$going = False
				}
			}
		}
		$len
	}

	left_index : I32 -> U64
	left_index = |node| 2 * (node.to_u64_wrap().bitwise_and(BtMatchfinder.window_mask))

	right_index : I32 -> U64
	right_index = |node| 2 * (node.to_u64_wrap().bitwise_and(BtMatchfinder.window_mask)) + 1

	## Advance one position, optionally recording the matches found.
	##
	## `record` is false when the caller only wants the tree updated -- the
	## parser skips over bytes it has already committed to, but the tree still
	## has to see them. Mirrors `bt_matchfinder_advance_one_byte`.
	advance : Finder, List(U8), U64, U64, U64, U64, U64, U64, Bool -> { finder : Finder, matches : List(Match), next3 : U64, next4 : U64 }
	advance = |finder, data, pos, max_len, nice_len, max_search_depth, next3, next4, record| {
		cur_pos = pos.to_i32_wrap()
		cutoff = cur_pos - BtMatchfinder.window_size

		# Hashes are pipelined one position ahead, as in the other finder.
		next_hashseq = BtMatchfinder.load_u32(data, pos + 1)
		hash3 = next3
		hash4 = next4
		new_next3 = BtMatchfinder.lz_hash(next_hashseq.bitwise_and(0xFFFFFF), BtMatchfinder.hash3_order)
		new_next4 = BtMatchfinder.lz_hash(next_hashseq, BtMatchfinder.hash4_order)

		var $f = finder
		var $matches = List.with_capacity(16)

		# Length-3 candidates come from a plain two-way table, not the tree.
		node3a = List.get($f.hash3a, hash3) ?? BtMatchfinder.initval
		node3b = List.get($f.hash3b, hash3) ?? BtMatchfinder.initval
		$f = { ..$f, hash3a: List.set($f.hash3a, hash3, cur_pos) ?? $f.hash3a }
		$f = { ..$f, hash3b: List.set($f.hash3b, hash3, node3a) ?? $f.hash3b }

		if record and node3a > cutoff {
			seq3 = BtMatchfinder.load_u24(data, pos)
			if seq3 == BtMatchfinder.load_u24(data, node3a.to_u64_wrap()) {
				$matches = List.append($matches, { length: 3, offset: pos - node3a.to_u64_wrap() })
			} else if node3b > cutoff and seq3 == BtMatchfinder.load_u24(data, node3b.to_u64_wrap()) {
				$matches = List.append($matches, { length: 3, offset: pos - node3b.to_u64_wrap() })
			} else {}
		} else {}

		root = List.get($f.hash4, hash4) ?? BtMatchfinder.initval
		$f = { ..$f, hash4: List.set($f.hash4, hash4, cur_pos) ?? $f.hash4 }

		# The current position's own children, filled in as the walk descends.
		var $pending_lt = BtMatchfinder.left_index(cur_pos)
		var $pending_gt = BtMatchfinder.right_index(cur_pos)

		if root <= cutoff {
			# Nothing in range; this position becomes a leaf.
			$f = { ..$f, child: List.set($f.child, $pending_lt, BtMatchfinder.initval) ?? $f.child }
			$f = { ..$f, child: List.set($f.child, $pending_gt, BtMatchfinder.initval) ?? $f.child }
			{ finder: $f, matches: $matches, next3: new_next3, next4: new_next4 }
		} else {
			var $cur_node = root
			var $best_len = 3.U64
			var $best_lt_len = 0.U64
			var $best_gt_len = 0.U64
			var $len = 0.U64
			var $depth = max_search_depth
			var $going = True

			while $going {
				matchptr = $cur_node.to_u64_wrap()

				if (List.get(data, matchptr + $len) ?? 0) == (List.get(data, pos + $len) ?? 0) {
					$len = BtMatchfinder.lz_extend(data, pos, matchptr, $len + 1, max_len)
					if !record or $len > $best_len {
						if record {
							$best_len = $len
							$matches = List.append($matches, { length: $len, offset: pos - matchptr })
						} else {}
						if $len >= nice_len {
							# Good enough: hand this node's children to the
							# current position and stop.
							lt = List.get($f.child, BtMatchfinder.left_index($cur_node)) ?? BtMatchfinder.initval
							gt = List.get($f.child, BtMatchfinder.right_index($cur_node)) ?? BtMatchfinder.initval
							$f = { ..$f, child: List.set($f.child, $pending_lt, lt) ?? $f.child }
							$f = { ..$f, child: List.set($f.child, $pending_gt, gt) ?? $f.child }
							$going = False
						} else {}
					} else {}
				} else {}

				if $going {
					# Descend, splicing this position in on the way.
					if (List.get(data, matchptr + $len) ?? 0) < (List.get(data, pos + $len) ?? 0) {
						$f = { ..$f, child: List.set($f.child, $pending_lt, $cur_node) ?? $f.child }
						$pending_lt = BtMatchfinder.right_index($cur_node)
						$cur_node = List.get($f.child, $pending_lt) ?? BtMatchfinder.initval
						$best_lt_len = $len
						if $best_gt_len < $len {
							$len = $best_gt_len
						} else {}
					} else {
						$f = { ..$f, child: List.set($f.child, $pending_gt, $cur_node) ?? $f.child }
						$pending_gt = BtMatchfinder.left_index($cur_node)
						$cur_node = List.get($f.child, $pending_gt) ?? BtMatchfinder.initval
						$best_gt_len = $len
						if $best_lt_len < $len {
							$len = $best_lt_len
						} else {}
					}

					$depth = $depth - 1
					if $cur_node <= cutoff or $depth == 0 {
						$f = { ..$f, child: List.set($f.child, $pending_lt, BtMatchfinder.initval) ?? $f.child }
						$f = { ..$f, child: List.set($f.child, $pending_gt, BtMatchfinder.initval) ?? $f.child }
						$going = False
					} else {}
				} else {}
			}

			{ finder: $f, matches: $matches, next3: new_next3, next4: new_next4 }
		}
	}
}
