## The hash-chain matchfinder libdeflate uses at its middle levels, ported from
## `hc_matchfinder.h`.
##
## Each hash bucket heads a chain of earlier positions that hashed the same, so
## searching means walking back along that chain and keeping the longest match
## found. The chain is in most-recent-first order, which is what makes stopping
## early reasonable: nearer matches cost fewer bits, so the first good one found
## is usually the one worth taking.
##
## Two hashes are kept. The 4-byte hash roots the chains and does the real work;
## the 3-byte hash is a single slot per bucket, consulted only when nothing
## longer has turned up, since a 3-byte match is barely worth its offset.
HcMatchfinder := [].{
	hash3_order : U8
	hash3_order = 15

	hash3_size : U64
	hash3_size = 32768

	hash4_order : U8
	hash4_order = 16

	hash4_size : U64
	hash4_size = 65536

	window_size : I32
	window_size = 32768

	window_mask : U64
	window_mask = 32767

	initval : I32
	initval = -32768

	## Below this, the four bytes at `pos + 1` that the next position's hashes
	## need cannot be read.
	required_nbytes : U64
	required_nbytes = 5

	## `next_tab` chains each window position to the previous one that shared
	## its 4-byte hash.
	Finder : {
		hash3 : List(I32),
		hash4 : List(I32),
		next : List(I32),
	}

	init : {} -> Finder
	init = |{}| {
		hash3: List.repeat(HcMatchfinder.initval, HcMatchfinder.hash3_size),
		hash4: List.repeat(HcMatchfinder.initval, HcMatchfinder.hash4_size),
		next: List.repeat(HcMatchfinder.initval, 32768),
	}

	lz_hash : U32, U8 -> U64
	lz_hash = |seq, bits|
		seq.times_wrap(0x1E35A7BD).shr_zf_wrap(32 - bits).to_u64()

	load_u32 : List(U8), U64 -> U32
	load_u32 = |data, pos| U32.from_le_bytes(data, pos) ?? 0

	lz_extend : List(U8), U64, U64, U64, U64 -> U64
	lz_extend = |data, strptr, matchptr, start_len, max_len| {
		var $len = start_len
		var $going = True
		while $going {
			if $len >= max_len {
				$going = False
			} else if (List.get(data, strptr + $len) ?? 0) == (List.get(data, matchptr + $len) ?? 0) {
				$len = $len + 1
			} else {
				$going = False
			}
		}
		$len
	}

	chain_index : I32 -> U64
	chain_index = |node| node.to_u64_wrap().bitwise_and(HcMatchfinder.window_mask)

	## Find the longest match at `pos`, or return `best_len` unchanged if nothing
	## longer than it turns up.
	##
	## `best_len` comes in as what the caller already has in hand, so the search
	## can skip candidates that could not beat it. `offset` is only meaningful
	## when the returned length exceeds what was passed in.
	longest_match : Finder, List(U8), U64, U64, U64, U64, U64, U64, U64 -> { finder : Finder, length : U64, offset : U64, next3 : U64, next4 : U64 }
	longest_match = |finder, data, pos, best_len_in, max_len, nice_len, max_search_depth, next3, next4| {
		cur_pos = pos.to_i32_wrap()
		cutoff = cur_pos - HcMatchfinder.window_size

		if max_len < HcMatchfinder.required_nbytes {
			# Too close to the end to hash the next position, so this one is
			# left out of the tables entirely.
			{ finder, length: best_len_in, offset: 0, next3, next4 }
		} else {
			var $f = finder
			var $best_len = best_len_in
			var $best_pos = pos
			var $depth = max_search_depth
			var $done = False

			node3 = List.get($f.hash3, next3) ?? HcMatchfinder.initval
			node4_head = List.get($f.hash4, next4) ?? HcMatchfinder.initval
			$f = { ..$f, hash3: List.set($f.hash3, next3, cur_pos) ?? $f.hash3 }
			$f = { ..$f, hash4: List.set($f.hash4, next4, cur_pos) ?? $f.hash4 }
			$f = { ..$f, next: List.set($f.next, HcMatchfinder.chain_index(cur_pos), node4_head) ?? $f.next }

			# Hashes are pipelined one position ahead.
			next_hashseq = HcMatchfinder.load_u32(data, pos + 1)
			new_next3 = HcMatchfinder.lz_hash(next_hashseq.bitwise_and(0xFFFFFF), HcMatchfinder.hash3_order)
			new_next4 = HcMatchfinder.lz_hash(next_hashseq, HcMatchfinder.hash4_order)

			seq4 = HcMatchfinder.load_u32(data, pos)
			var $node4 = node4_head

			if $best_len < 4 {
				# Nothing of length 4 yet, so the 3-byte slot is worth a look
				# and the chain has to be entered by matching all four bytes.
				if node3 <= cutoff {
					$done = True
				} else {
					if $best_len < 3 {
						m3 = node3.to_u64_wrap()
						if HcMatchfinder.load_u32(data, m3).bitwise_and(0xFFFFFF) == seq4.bitwise_and(0xFFFFFF) {
							$best_len = 3
							$best_pos = m3
						} else {
						}
					} else {
					}

					if $node4 <= cutoff {
						$done = True
					} else {
						var $seeking = True
						while $seeking {
							matchptr = $node4.to_u64_wrap()
							if HcMatchfinder.load_u32(data, matchptr) == seq4 {
								$best_pos = matchptr
								$best_len = HcMatchfinder.lz_extend(data, pos, matchptr, 4, max_len)
								$seeking = False
								if $best_len >= nice_len {
									$done = True
								} else {
									$node4 = List.get($f.next, HcMatchfinder.chain_index($node4)) ?? HcMatchfinder.initval
									$depth = $depth - 1
									if $node4 <= cutoff or $depth == 0 {
										$done = True
									} else {
									}
								}
							} else {
								$node4 = List.get($f.next, HcMatchfinder.chain_index($node4)) ?? HcMatchfinder.initval
								$depth = $depth - 1
								if $node4 <= cutoff or $depth == 0 {
									$done = True
									$seeking = False
								} else {
								}
							}
						}
					}
				}
			} else if $node4 <= cutoff or $best_len >= nice_len {
				$done = True
			} else {
			}

			# From here every candidate has to beat the length already found, so
			# the byte one past it is checked before anything else.
			while $done == False {
				var $scanning = True
				while $scanning {
					matchptr = $node4.to_u64_wrap()
					if (List.get(data, matchptr + $best_len) ?? 0) == (List.get(data, pos + $best_len) ?? 0) {
						$scanning = False
					} else {
						$node4 = List.get($f.next, HcMatchfinder.chain_index($node4)) ?? HcMatchfinder.initval
						$depth = $depth - 1
						if $node4 <= cutoff or $depth == 0 {
							$done = True
							$scanning = False
						} else {
						}
					}
				}

				if $done == False {
					matchptr = $node4.to_u64_wrap()
					len = HcMatchfinder.lz_extend(data, pos, matchptr, 0, max_len)
					if len > $best_len {
						$best_len = len
						$best_pos = matchptr
						if $best_len >= nice_len {
							$done = True
						} else {
						}
					} else {
					}

					if $done == False {
						$node4 = List.get($f.next, HcMatchfinder.chain_index($node4)) ?? HcMatchfinder.initval
						$depth = $depth - 1
						if $node4 <= cutoff or $depth == 0 {
							$done = True
						} else {
						}
					} else {
					}
				} else {
				}
			}

			{ finder: $f, length: $best_len, offset: pos - $best_pos, next3: new_next3, next4: new_next4 }
		}
	}

	## Enter `count` positions into the tables without searching them, for the
	## bytes a chosen match already covers.
	skip_bytes : Finder, List(U8), U64, U64, U64, U64, U64 -> { finder : Finder, next3 : U64, next4 : U64 }
	skip_bytes = |finder, data, pos, count, data_len, next3, next4|
		if count + HcMatchfinder.required_nbytes > data_len - pos {
			# Not enough room left to hash the position after the last one, so
			# the whole run is left out rather than part of it.
			{ finder, next3, next4 }
		} else {
			var $f = finder
			var $h3 = next3
			var $h4 = next4
			var $p = pos
			var $remaining = count
			while $remaining > 0 {
				cur = $p.to_i32_wrap()
				head4 = List.get($f.hash4, $h4) ?? HcMatchfinder.initval
				$f = { ..$f, hash3: List.set($f.hash3, $h3, cur) ?? $f.hash3 }
				$f = { ..$f, next: List.set($f.next, HcMatchfinder.chain_index(cur), head4) ?? $f.next }
				$f = { ..$f, hash4: List.set($f.hash4, $h4, cur) ?? $f.hash4 }
				seq = HcMatchfinder.load_u32(data, $p + 1)
				$h3 = HcMatchfinder.lz_hash(seq.bitwise_and(0xFFFFFF), HcMatchfinder.hash3_order)
				$h4 = HcMatchfinder.lz_hash(seq, HcMatchfinder.hash4_order)
				$p = $p + 1
				$remaining = $remaining - 1
			}
			{ finder: $f, next3: $h3, next4: $h4 }
		}
}
