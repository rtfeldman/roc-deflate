import Matchfinder

## The hash-chains matchfinder, ported from libdeflate's `hc_matchfinder.h`.
##
## Every position is inserted into a length-3 hash bucket and onto the front of
## a length-4 hash chain. A search walks the length-4 chain newest first, so it
## can stop after `max_search_depth` candidates and still have considered the
## nearest ones, which are the cheapest to encode.
##
## Two details carry most of the speed and are kept exactly:
##
##   - the walk rejects a candidate on four bytes at a time, and once a match
##     is established it first re-checks the four bytes ending just past the
##     current best length, so a candidate that cannot beat the incumbent is
##     discarded without extending it
##   - the first search and the "already have a length-4 match" search are
##     separate loops rather than one general loop, because each is tuned for
##     what it knows
HcMatchfinder := [].{

	hash3_order : U64
	hash3_order = 15

	hash4_order : U64
	hash4_order = 16

	## Tables plus the position base they are relative to, and the hashes
	## precomputed for the coming position.
	State : {
		hash3 : List(I16),
		hash4 : List(I16),
		next_tab : List(I16),
		in_cur_base : U64,
		next_hash3 : U64,
		next_hash4 : U64,
	}

	## Slide every table back one window, so stored positions stay relative to
	## the base that just advanced.
	slide_window : State -> Try(State, [CompressBug])
	slide_window = |state| {
		hash3 = Matchfinder.rebase_table(state.hash3)?
		hash4 = Matchfinder.rebase_table(state.hash4)?
		next_tab = Matchfinder.rebase_table(state.next_tab)?
		Ok({ ..state, hash3, hash4, next_tab, in_cur_base: state.in_cur_base + Matchfinder.window_size })
	}

	Match : { state : State, length : U64, offset : U64 }

	## Find the longest match at `in_next` that beats `best_len`, considering at
	## most `max_search_depth` candidates and stopping early at `nice_len`.
	longest_match : State, List(U8), U64, U64, U64, U64, U64 -> Try(Match, [CompressBug])
	longest_match = |state0, input, in_next, best_len_in, max_len, nice_len, max_search_depth| {
		var $state = state0
		if in_next - $state.in_cur_base == Matchfinder.window_size {
			$state = HcMatchfinder.slide_window($state)?
		} else {
		}
		in_base = $state.in_cur_base
		cur_pos = in_next - in_base
		cutoff = cur_pos.to_i32_wrap() - 32768

		var $best_len = best_len_in
		var $best_match_at = in_next

		if max_len < 5 {
			# Not enough bytes left to read the next position's hash sequence.
			Ok({ state: $state, length: $best_len, offset: in_next - $best_match_at })
		} else {
			hash3 = $state.next_hash3
			hash4 = $state.next_hash4
			cur_node3 = List.get($state.hash3, hash3) ?? 0
			cur_node4 = List.get($state.hash4, hash4) ?? 0

			# Insert this position: it replaces the length-3 bucket and goes on
			# the front of the length-4 chain.
			pos = cur_pos.to_i16_wrap()
			new_hash3 = match List.set($state.hash3, hash3, pos) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			new_hash4 = match List.set($state.hash4, hash4, pos) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}
			new_next_tab = match List.set($state.next_tab, cur_pos, cur_node4) {
				Ok(next) => next
				Err(_) => return Err(CompressBug)
			}

			# Precompute the hashes for the next position.
			next_hashseq = U32.from_le_bytes(input, in_next + 1) ?? 0
			$state = {
				hash3: new_hash3,
				hash4: new_hash4,
				next_tab: new_next_tab,
				in_cur_base: in_base,
				next_hash3: Matchfinder.lz_hash(next_hashseq.bitwise_and(0xFFFFFF), HcMatchfinder.hash3_order),
				next_hash4: Matchfinder.lz_hash(next_hashseq, HcMatchfinder.hash4_order),
			}

			seq4 = U32.from_le_bytes(input, in_next) ?? 0
			var $node4 = cur_node4
			var $depth = max_search_depth
			var $done = 0.U64

			if $best_len < 4 {
				if cur_node3.to_i32() <= cutoff {
					$done = 1
				} else {
					if $best_len < 3 {
						match_at = Matchfinder.match_index(in_base, cur_node3)
						if (U32.from_le_bytes(input, match_at) ?? 0).bitwise_and(0xFFFFFF)
							== seq4.bitwise_and(0xFFFFFF) {
							$best_len = 3
							$best_match_at = match_at
						} else {
						}
					} else {
					}

					if $node4.to_i32() <= cutoff {
						$done = 1
					} else {
						# Walk the chain until four bytes agree.
						var $scanning = 1.U64
						var $found_at = 0.U64
						while $scanning == 1 {
							match_at = Matchfinder.match_index(in_base, $node4)
							if (U32.from_le_bytes(input, match_at) ?? 0) == seq4 {
								$found_at = match_at
								$scanning = 0
							} else {
								$node4 = List.get($state.next_tab, $node4.to_i32().bitwise_and(32767).to_u64_wrap()) ?? 0
								$depth = $depth - 1
								if $node4.to_i32() <= cutoff or $depth == 0 {
									$scanning = 0
									$done = 1
								} else {
								}
							}
						}

						if $done == 0 {
							$best_match_at = $found_at
							$best_len = Matchfinder.lz_extend(input, in_next, $found_at, 4, max_len)
							if $best_len >= nice_len {
								$done = 1
							} else {
								$node4 = List.get($state.next_tab, $node4.to_i32().bitwise_and(32767).to_u64_wrap()) ?? 0
								$depth = $depth - 1
								if $node4.to_i32() <= cutoff or $depth == 0 {
									$done = 1
								} else {
								}
							}
						} else {
						}
					}
				}
			} else {
				if $node4.to_i32() <= cutoff or $best_len >= nice_len {
					$done = 1
				} else {
				}
			}

			# Now look only for matches longer than the one in hand.
			while $done == 0 {
				var $scanning = 1.U64
				var $cand_at = 0.U64
				while $scanning == 1 {
					match_at = Matchfinder.match_index(in_base, $node4)
					# The four bytes ending just past the current best length
					# are what a longer match must agree on, so check them
					# before anything else.
					if (U32.from_le_bytes(input, match_at + $best_len - 3) ?? 0)
						== (U32.from_le_bytes(input, in_next + $best_len - 3) ?? 0)
						and (U32.from_le_bytes(input, match_at) ?? 0)
							== (U32.from_le_bytes(input, in_next) ?? 0) {
						$cand_at = match_at
						$scanning = 0
					} else {
						$node4 = List.get($state.next_tab, $node4.to_i32().bitwise_and(32767).to_u64_wrap()) ?? 0
						$depth = $depth - 1
						if $node4.to_i32() <= cutoff or $depth == 0 {
							$scanning = 0
							$done = 1
						} else {
						}
					}
				}

				if $done == 0 {
					len = Matchfinder.lz_extend(input, in_next, $cand_at, 4, max_len)
					if len > $best_len {
						$best_len = len
						$best_match_at = $cand_at
						if $best_len >= nice_len {
							$done = 1
						} else {
						}
					} else {
					}
					if $done == 0 {
						$node4 = List.get($state.next_tab, $node4.to_i32().bitwise_and(32767).to_u64_wrap()) ?? 0
						$depth = $depth - 1
						if $node4.to_i32() <= cutoff or $depth == 0 {
							$done = 1
						} else {
						}
					} else {
					}
				} else {
				}
			}

			Ok({ state: $state, length: $best_len, offset: in_next - $best_match_at })
		}
	}

	## Insert `count` positions into the tables without searching them.
	skip_bytes : State, List(U8), U64, U64, U64 -> Try(State, [CompressBug])
	skip_bytes = |state0, input, in_next0, in_end, count| {
		var $state = state0
		if count + 5 > in_end - in_next0 {
			Ok($state)
		} else {
			var $in_next = in_next0
			var $cur_pos = $in_next - $state.in_cur_base
			var $hash3 = $state.next_hash3
			var $hash4 = $state.next_hash4
			var $remaining = count
			while $remaining > 0 {
				if $cur_pos == Matchfinder.window_size {
					$state = HcMatchfinder.slide_window($state)?
					$cur_pos = 0
				} else {
				}
				pos = $cur_pos.to_i16_wrap()
				prev_head = List.get($state.hash4, $hash4) ?? 0
				new_hash3 = match List.set($state.hash3, $hash3, pos) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				new_next_tab = match List.set($state.next_tab, $cur_pos, prev_head) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				new_hash4 = match List.set($state.hash4, $hash4, pos) {
					Ok(next) => next
					Err(_) => return Err(CompressBug)
				}
				$state = {
					hash3: new_hash3,
					hash4: new_hash4,
					next_tab: new_next_tab,
					in_cur_base: $state.in_cur_base,
					next_hash3: $state.next_hash3,
					next_hash4: $state.next_hash4,
				}

				$in_next = $in_next + 1
				next_hashseq = U32.from_le_bytes(input, $in_next) ?? 0
				$hash3 = Matchfinder.lz_hash(next_hashseq.bitwise_and(0xFFFFFF), HcMatchfinder.hash3_order)
				$hash4 = Matchfinder.lz_hash(next_hashseq, HcMatchfinder.hash4_order)
				$cur_pos = $cur_pos + 1
				$remaining = $remaining - 1
			}
			Ok({ ..$state, next_hash3: $hash3, next_hash4: $hash4 })
		}
	}
}
