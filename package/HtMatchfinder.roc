## The hash-table matchfinder libdeflate uses at level 1, ported from
## `ht_matchfinder.h`.
##
## Unlike the hash-chain finders used at higher levels, this keeps only two
## candidates per hash bucket and never walks a chain, which is what makes it
## fast and what makes level 1 level 1. Which of the two candidates wins, and
## when the search gives up, decide the symbol stream -- so the tie-breaking
## here has to match libdeflate exactly or the output differs even though the
## compression is just as good.
HtMatchfinder := [].{
	hash_order : U8
	hash_order = 15

	hash_size : U64
	hash_size = 32768

	## Two candidates per bucket.
	bucket_size : U64
	bucket_size = 2

	min_match_len : U64
	min_match_len = 4

	## Bytes that must be readable at the current position for the finder to
	## run at all; below this the caller emits literals instead.
	required_nbytes : U64
	required_nbytes = 5

	window_size : I32
	window_size = 32768

	## Entries start this far in the past so nothing matches before any data
	## has been inserted.
	initval : I32
	initval = -32768

	## Two parallel arrays rather than one array of pairs, so a bucket read is
	## two indexed loads rather than a stride-2 access.
	Finder : { slot0 : List(I32), slot1 : List(I32) }

	init : {} -> Finder
	init = |{}| {
		slot0: List.repeat(HtMatchfinder.initval, HtMatchfinder.hash_size),
		slot1: List.repeat(HtMatchfinder.initval, HtMatchfinder.hash_size),
	}

	## libdeflate's multiplicative hash over the next four bytes.
	lz_hash : U32 -> U64
	lz_hash = |seq|
		seq.times_wrap(0x1E35A7BD).shr_zf_wrap(32 - HtMatchfinder.hash_order).to_u64()

	## Four bytes at `pos`, or 0 if fewer remain. Callers only hash where at
	## least `required_nbytes` are available.
	load_u32 : List(U8), U64 -> U32
	load_u32 = |data, pos| U32.from_le_bytes(data, pos) ?? 0

	## Longest common prefix of the two positions, capped at `max_len`,
	## starting from `start_len` already-matched bytes. Mirrors `lz_extend`.
	lz_extend : List(U8), U64, U64, U64, U64 -> U64
	lz_extend = |data, strptr, matchptr, start_len, max_len| {
		var $len = start_len
		var $going = True
		while $going {
			if $len >= max_len {
				$going = False
			} else {
				a = List.get(data, strptr + $len) ?? 0
				b = List.get(data, matchptr + $len) ?? 0
				if a == b {
					$len = $len + 1
				} else {
					$going = False
				}
			}
		}
		$len
	}

	## The longest match at `pos`, or length 0 if none.
	##
	## Both bucket slots are probed, newest first, and the second is only tried
	## when the first did not already reach `nice_len`. Returns the match and
	## the finder with `pos` inserted.
	Match : { length : U64, offset : U64 }

	## The hash is pipelined one position ahead: a call uses the hash computed
	## by the previous call and leaves behind the hash for the next position.
	## `next_hash` starts at 0, so the very first lookup goes to bucket 0
	## regardless of the data there -- an artifact of that pipelining, but one
	## the output depends on, so it is reproduced rather than tidied away.
	longest_match : Finder, List(U8), U64, U64, U64, U64 -> { finder : Finder, found : Match, next_hash : U64 }
	longest_match = |finder, data, pos, max_len, nice_len, next_hash| {
		cur_pos = pos.to_i32_wrap()
		cutoff = cur_pos - HtMatchfinder.window_size
		seq = HtMatchfinder.load_u32(data, pos)
		hash = next_hash
		new_next_hash = HtMatchfinder.lz_hash(HtMatchfinder.load_u32(data, pos + 1))

		node0 = List.get(finder.slot0, hash) ?? HtMatchfinder.initval
		node1 = List.get(finder.slot1, hash) ?? HtMatchfinder.initval

		# Insert this position, pushing the previous occupant down a slot.
		f1 = { slot0: List.set(finder.slot0, hash, cur_pos) ?? finder.slot0, slot1: finder.slot1 }
		f2 = { ..f1, slot1: List.set(f1.slot1, hash, node0) ?? f1.slot1 }

		var $best_len = 0.U64
		var $best_off = 0.U64

		if node0 > cutoff {
			mp0 = node0.to_u64_wrap()
			if HtMatchfinder.load_u32(data, mp0) == seq {
				$best_len = HtMatchfinder.lz_extend(data, pos, mp0, 4, max_len)
				$best_off = pos - mp0
				# The second candidate is only worth probing if the first did
				# not already reach the "good enough" length.
				if node1 > cutoff and $best_len < nice_len {
					mp1 = node1.to_u64_wrap()
					if HtMatchfinder.load_u32(data, mp1) == seq {
						len = HtMatchfinder.lz_extend(data, pos, mp1, 4, max_len)
						if len > $best_len {
							$best_len = len
							$best_off = pos - mp1
						} else {}
					} else {}
				} else {}
			} else {
				if node1 > cutoff {
					mp1 = node1.to_u64_wrap()
					if HtMatchfinder.load_u32(data, mp1) == seq {
						$best_len = HtMatchfinder.lz_extend(data, pos, mp1, 4, max_len)
						$best_off = pos - mp1
					} else {}
				} else {}
			}
		} else {}

		{ finder: f2, found: { length: $best_len, offset: $best_off }, next_hash: new_next_hash }
	}

	## Insert positions without searching, used to catch the table up over the
	## bytes a match consumed. Mirrors `ht_matchfinder_skip_bytes`.
	skip_bytes : Finder, List(U8), U64, U64, U64, U64 -> { finder : Finder, next_hash : U64 }
	skip_bytes = |finder, data, from, count, data_len, next_hash| {
		# All or nothing: if the whole run plus the lookahead does not fit,
		# libdeflate inserts none of it rather than inserting what it can. That
		# leaves the table in a different state near the end of the input, which
		# changes later match choices.
		if count + HtMatchfinder.required_nbytes > data_len - from {
			{ finder, next_hash }
		} else {
			var $f = finder
			var $p = from
			var $n = count
			var $hash = next_hash
			while $n > 0 {
				node0 = List.get($f.slot0, $hash) ?? HtMatchfinder.initval
				s0 = List.set($f.slot0, $hash, $p.to_i32_wrap()) ?? $f.slot0
				s1 = List.set($f.slot1, $hash, node0) ?? $f.slot1
				$f = { slot0: s0, slot1: s1 }
				$p = $p + 1
				$hash = HtMatchfinder.lz_hash(HtMatchfinder.load_u32(data, $p))
				$n = $n - 1
			}
			{ finder: $f, next_hash: $hash }
		}
	}
}
