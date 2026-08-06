import Matchfinder

## The binary-tree matchfinder, ported from libdeflate's `bt_matchfinder.h`.
##
## Where the other matchfinders report only the longest match, this reports
## every match worth considering at a position, in increasing length order,
## which is what the near-optimal parser needs to choose between them.
##
## Each position roots a binary search tree of the positions sharing its
## length-4 hash, ordered by the bytes that follow. Walking the tree both
## narrows the search and rebuilds it: the nodes passed on the way down are
## re-linked into the two pending subtrees, so the tree stays balanced against
## the data rather than needing a separate rebuild.
BtMatchfinder := [].{

	hash3_order : U64
	hash3_order = 16

	hash3_ways : U64
	hash3_ways = 2

	hash4_order : U64
	hash4_order = 16

	## Bytes that must be readable at the position: four for the sequence and
	## one more for the next position's hash.
	required_nbytes : U64
	required_nbytes = 5

	State : {
		hash3 : List(I16),
		hash4 : List(I16),
		child : List(I16),
		next_hash3 : U64,
		next_hash4 : U64,
	}

	## A match the tree walk found: its length and how far back it starts.
	LzMatch : { length : U64, offset : U64 }

	Advanced : {
		hash3 : List(I16),
		hash4 : List(I16),
		child : List(I16),
		next_hash3 : U64,
		next_hash4 : U64,
		matches : List(LzMatch),
	}

	## Advance one byte, appending any matches found to `matches`.
	##
	## With `record` zero the tree is still walked and rebuilt but nothing is
	## reported, which is how positions inside a chosen match are skipped
	## without losing the tree.
	advance_one_byte : List(I16), List(I16), List(I16), U64, U64, List(U8), U64, U64, U64, U64, U64, List(LzMatch), U64 -> Try(Advanced, [CompressBug])
	advance_one_byte = |tab3_0, tab4_0, child_0, nh3, nh4, input, in_base, cur_pos, max_len, nice_len, max_search_depth, matches_0, record| {
		var $tab3 = tab3_0
		var $tab4 = tab4_0
		var $child = child_0
		var $matches = matches_0
		in_next = in_base + cur_pos
		cutoff = cur_pos.to_i32_wrap() - 32768

		next_hashseq = U32.from_le_bytes(input, in_next + 1) ?? 0
		hash3 = nh3
		hash4 = nh4
		out_hash3 = Matchfinder.lz_hash(next_hashseq.bitwise_and(0xFFFFFF), BtMatchfinder.hash3_order)
		out_hash4 = Matchfinder.lz_hash(next_hashseq, BtMatchfinder.hash4_order)

		pos = cur_pos.to_i16_wrap()

		# The length-3 hash keeps two ways, so a short match survives one
		# eviction; it is reported but never entered into the tree.
		slot3 = hash3 * 2
		node3 = List.get($tab3, slot3) ?? 0
		node3_2 = List.get($tab3, slot3 + 1) ?? 0
		$tab3 = match List.set($tab3, slot3, pos) {
			Ok(next) => next
			Err(_) => return Err(CompressBug)
		}
		$tab3 = match List.set($tab3, slot3 + 1, node3) {
			Ok(next) => next
			Err(_) => return Err(CompressBug)
		}

		if record == 1 and node3.to_i32() > cutoff {
			seq3 = (U32.from_le_bytes(input, in_next) ?? 0).bitwise_and(0xFFFFFF)
			at3 = Matchfinder.match_index(in_base, node3)
			if seq3 == (U32.from_le_bytes(input, at3) ?? 0).bitwise_and(0xFFFFFF) {
				$matches = List.append($matches, { length: 3, offset: in_next - at3 })
			} else if node3_2.to_i32() > cutoff {
				at3b = Matchfinder.match_index(in_base, node3_2)
				if seq3 == (U32.from_le_bytes(input, at3b) ?? 0).bitwise_and(0xFFFFFF) {
					$matches = List.append($matches, { length: 3, offset: in_next - at3b })
				} else {
				}
			} else {
			}
		} else {
		}

		node4 = List.get($tab4, hash4) ?? 0
		$tab4 = match List.set($tab4, hash4, pos) {
			Ok(next) => next
			Err(_) => return Err(CompressBug)
		}

		# The two subtrees being rebuilt hang off this position's child slots.
		var $pending_lt = cur_pos.bitwise_and(32767) * 2
		var $pending_gt = cur_pos.bitwise_and(32767) * 2 + 1

		if node4.to_i32() <= cutoff {
			$child = match List.set($child, $pending_lt, Matchfinder.initval) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			$child = match List.set($child, $pending_gt, Matchfinder.initval) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			Ok({
				hash3: $tab3,
				hash4: $tab4,
				child: $child,
				next_hash3: out_hash3,
				next_hash4: out_hash4,
				matches: $matches,
			})
		} else {
			var $node = node4
			var $depth = max_search_depth
			var $best_lt_len = 0.U64
			var $best_gt_len = 0.U64
			var $len = 0.U64
			var $best_len = 3.U64
			var $walking = 1.U64

			while $walking == 1 {
				match_at = Matchfinder.match_index(in_base, $node)

				if (List.get(input, match_at + $len) ?? 0) == (List.get(input, in_next + $len) ?? 0) {
					$len = Matchfinder.lz_extend(input, in_next, match_at, $len + 1, max_len)
					if record == 0 or $len > $best_len {
						if record == 1 {
							$best_len = $len
							$matches = List.append($matches, { length: $len, offset: in_next - match_at })
						} else {
						}
						if $len >= nice_len {
							# Long enough to stop: hand this node's subtrees
							# to the two pending slots and leave the tree as
							# it stands.
							node_lt = List.get($child, $node.to_i32().bitwise_and(32767).to_u64_wrap() * 2) ?? 0
							node_gt = List.get($child, $node.to_i32().bitwise_and(32767).to_u64_wrap() * 2 + 1) ?? 0
							$child = match List.set($child, $pending_lt, node_lt) {
								Ok(next) => next
								Err(_) => return Err(CompressBug)
							}
							$child = match List.set($child, $pending_gt, node_gt) {
								Ok(next) => next
								Err(_) => return Err(CompressBug)
							}
							$walking = 0
						} else {
						}
					} else {
					}
				} else {
				}

				if $walking == 1 {
					node_slot = $node.to_i32().bitwise_and(32767).to_u64_wrap() * 2
					if (List.get(input, match_at + $len) ?? 0) < (List.get(input, in_next + $len) ?? 0) {
						# This node sorts before the current position, so it
						# and its left subtree belong to the lesser side.
						$child = match List.set($child, $pending_lt, $node) {
							Ok(next) => next
							Err(_) => return Err(CompressBug)
						}
						$pending_lt = node_slot + 1
						$node = List.get($child, $pending_lt) ?? 0
						$best_lt_len = $len
						if $best_gt_len < $len {
							$len = $best_gt_len
						} else {
						}
					} else {
						$child = match List.set($child, $pending_gt, $node) {
							Ok(next) => next
							Err(_) => return Err(CompressBug)
						}
						$pending_gt = node_slot
						$node = List.get($child, $pending_gt) ?? 0
						$best_gt_len = $len
						if $best_lt_len < $len {
							$len = $best_lt_len
						} else {
						}
					}

					$depth = $depth - 1
					if $node.to_i32() <= cutoff or $depth == 0 {
						$child = match List.set($child, $pending_lt, Matchfinder.initval) {
							Ok(next) => next
							Err(_) => return Err(CompressBug)
						}
						$child = match List.set($child, $pending_gt, Matchfinder.initval) {
							Ok(next) => next
							Err(_) => return Err(CompressBug)
						}
						$walking = 0
					} else {
					}
				} else {
				}
			}

			Ok({
				hash3: $tab3,
				hash4: $tab4,
				child: $child,
				next_hash3: out_hash3,
				next_hash4: out_hash4,
				matches: $matches,
			})
		}
	}
}
